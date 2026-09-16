import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// MELCloud: the bar button and the panel behind it, for one
// Mitsubishi Electric air conditioner (ATA device) on one MELCloud account.
//
// State lives entirely in files this plugin owns
// (~/.config/omarchy-melcloud/), not in Omarchy's own settings — there is
// only one thing to configure (which account/device), and melcloud-setup
// (an interactive terminal flow, see bin/) is a better fit for entering a
// password than a settings form would be. The `refreshIntervalSec` schema
// field in manifest.json is the one exception, since it is plain, cosmetic,
// and safe to default.
//
// All MELCloud access happens out-of-process in bin/melcloud-ctl, a Python
// CLI running inside this plugin's own venv (see install.sh) because
// pymelcloud/aiohttp are not stdlib. Every invocation prints one JSON object;
// Panel.qml only ever parses that, never talks to MELCloud directly.
Panel {
  id: root

  moduleName: "io.github.gskrt.melcloud"
  ipcTarget: "io.github.gskrt.melcloud"

  // ---------------------------------------------------------------- settings

  readonly property int refreshIntervalSec: Math.max(180, Number(setting("refreshIntervalSec", 900)))

  // ------------------------------------------------------------------- paths

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string venvPython: (Quickshell.env("HOME") || "") + "/.local/share/omarchy-melcloud/venv/bin/python3"
  readonly property string ctlScript: root.pluginDir + "bin/melcloud-ctl"
  readonly property string setupScript: root.pluginDir + "bin/melcloud-setup"

  // Background/status calls: no desktop needed, but secret-tool (invoked by
  // the Python side) needs the D-Bus session bus and XDG_RUNTIME_DIR to
  // reach the keyring, and network access needs nothing beyond the
  // interpreter itself -- so PATH is pinned to just /usr/bin.
  readonly property var minimalEnvironment: ({
    PATH: "/usr/bin",
    HOME: null,
    XDG_RUNTIME_DIR: null,
    DBUS_SESSION_BUS_ADDRESS: null
  })

  // The floating terminal launch is a real GUI hand-off, so it gets the
  // wider allowlist a desktop app actually needs, same rationale as the
  // sibling Google Drive plugin's desktopEnvironment.
  readonly property var desktopEnvironment: Object.assign({}, root.minimalEnvironment, {
    PATH: "/usr/bin:/usr/share/omarchy/bin",
    WAYLAND_DISPLAY: null,
    XDG_CURRENT_DESKTOP: null,
    XDG_DATA_DIRS: null,
    XDG_CONFIG_DIRS: null
  })

  // ------------------------------------------------------------------- state

  property var device: null
  property var devices: []
  property string errorCode: ""
  property string errorMessage: ""
  property double lastUpdatedAt: 0
  readonly property bool busy: actionProcess.running

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Warm while heating, cool while cooling, teal while drying, plain
  // foreground otherwise (fan-only doesn't heat or cool anything, and there
  // is no "off" hue that means anything) -- and always plain foreground
  // while the unit itself is off, so the color never claims a state that
  // isn't actually active.
  function modeColor(mode) {
    if (mode === "heat") return "#ff8a4c"
    if (mode === "cool") return "#4da8ff"
    if (mode === "dry") return "#5ecbc2"
    return root.foreground
  }

  readonly property color activeModeColor: (root.device && root.device.power) ? root.modeColor(root.effectiveMode) : root.foreground
  readonly property color targetTempColor: root.activeModeColor
  readonly property color currentTempColor: Qt.rgba(root.activeModeColor.r, root.activeModeColor.g, root.activeModeColor.b, 0.6)

  readonly property var modeLabels: ({
    heat: "Heat",
    dry: "Dry",
    cool: "Cool",
    fan_only: "Fan",
    heat_cool: "Auto",
    undefined: "—"
  })

  readonly property var vaneHLabels: ({
    auto: "Auto",
    "1_left": "Left",
    "2": "2",
    "3": "3",
    "4": "4",
    "5_right": "Right",
    split: "Split",
    swing: "Swing",
    undefined: "—"
  })

  readonly property var vaneVLabels: ({
    auto: "Auto",
    "1_up": "Up",
    "2": "2",
    "3": "3",
    "4": "4",
    "5_down": "Down",
    swing: "Swing",
    undefined: "—"
  })

  readonly property bool notConfigured: root.errorCode === "not_configured"
  readonly property bool hasError: root.errorCode !== "" && !root.notConfigured

  readonly property string barText: {
    if (root.notConfigured || root.hasError || !root.device) return "AC"
    var reading = root.device.room
    if (reading === null || reading === undefined) reading = root.effectiveTarget
    if (reading === null || reading === undefined) return "AC"
    return reading.toFixed(1) + "°"
  }

  readonly property string barTooltip: {
    if (root.notConfigured) return "MELCloud · Not signed in"
    if (root.hasError) return "MELCloud · " + (root.errorMessage || root.errorCode)
    if (!root.device) return "MELCloud · Loading…"
    var mode = root.modeLabels[root.effectiveMode] || root.effectiveMode
    var state = root.device.power ? mode : "Off"
    var line = root.device.name + " · " + state
    if (root.device.room !== null && root.device.room !== undefined)
      line += " · room " + root.device.room.toFixed(1) + "°C"
    return line
  }

  // ----------------------------------------------------------------- polling

  function refresh() {
    // Also skip while an action is in flight, not just another status poll:
    // statusProcess and actionProcess are separate OS processes that each do
    // their own independent MELCloud round-trip, so if both ran at once
    // there would be no guarantee the status read reflects the action's
    // write yet -- MELCloud itself gives no such ordering guarantee between
    // two concurrent requests, only "each request is internally consistent".
    // The fix is not reordering responses after the fact (see
    // handleProcessResult) but never letting the two race to begin with.
    // Skipping here is enough on its own; see applySet for the other half.
    if (statusProcess.running || actionProcess.running) return
    statusProcess.killed = false
    statusProcess.superseded = false
    statusProcess.requestedAt = Date.now()
    statusProcess.command = [root.venvPython, "-I", root.ctlScript, "status"]
    statusProcess.running = true
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedRefresh
    interval: 1500
    repeat: false
    onTriggered: root.refresh()
  }

  onOpenedChanged: {
    if (opened && Date.now() - root.lastUpdatedAt > 15000) root.refresh()
  }

  // Guards against a stale response clobbering a fresher one: statusProcess
  // (the 60s/on-open background poll) and actionProcess (a user click) run
  // as two independent Processes with no ordering between them, so a slow
  // status call issued before a quick set-target click can still finish
  // *after* it, carrying the pre-click temperature. Every completion -
  // success, script error, or timeout - funnels through here, stamped with
  // when its request was sent, and anything older than the last-applied
  // request is silently dropped rather than allowed to overwrite the UI.
  property double lastAppliedRequestAt: 0

  function handleProcessResult(requestedAt, killed, exitCode, stdoutText, stderrText) {
    if (requestedAt < root.lastAppliedRequestAt) return
    root.lastAppliedRequestAt = requestedAt
    if (killed) {
      root.setError("timeout", "MELCloud took too long to answer")
      return
    }
    if (exitCode !== 0) {
      root.setError("script_error", String(stderrText || "melcloud-ctl exited with code " + exitCode))
      return
    }
    root.applyResult(stdoutText)
  }

  function applyResult(rawText) {
    var parsed = null
    try {
      parsed = JSON.parse(rawText)
    } catch (e) {
      root.setError("bad_output", "melcloud-ctl produced unreadable output")
      return
    }
    if (parsed && Array.isArray(parsed.devices)) root.devices = parsed.devices
    if (!parsed || parsed.ok !== true) {
      root.setError(parsed && parsed.error ? parsed.error : "unknown_error", parsed ? parsed.message : "")
      return
    }
    root.device = parsed.device
    root.errorCode = ""
    root.errorMessage = ""
    root.lastUpdatedAt = Date.now()
  }

  function setError(code, message) {
    root.errorCode = code
    root.errorMessage = message || ""
    if (code === "not_configured" || code === "device_not_found") root.device = null
  }

  // ----------------------------------------------------------------- actions

  // The other half of never letting statusProcess and actionProcess race
  // (see refresh()): a status poll can already be in flight the moment the
  // user clicks something, since it wasn't rejected at dispatch time. Killed
  // outright rather than just awaited -- the user's action should not sit
  // behind an up-to-60s-old background poll that's about to be superseded
  // anyway. statusProcess's onExited checks `superseded` before calling
  // handleProcessResult at all, so this never flashes a stray error.
  function preemptStatusPoll() {
    if (!statusProcess.running) return
    statusProcess.superseded = true
    statusProcess.signal(9)
  }

  function buildSetCommand(props) {
    var cmd = [root.venvPython, "-I", root.ctlScript, "set"]
    if (props.power !== undefined) { cmd.push("--power"); cmd.push(props.power ? "on" : "off") }
    if (props.mode !== undefined) { cmd.push("--mode"); cmd.push(props.mode) }
    if (props.target !== undefined) { cmd.push("--target"); cmd.push(String(props.target)) }
    if (props.fan !== undefined) { cmd.push("--fan"); cmd.push(props.fan) }
    if (props.vaneH !== undefined) { cmd.push("--vane-h"); cmd.push(props.vaneH) }
    if (props.vaneV !== undefined) { cmd.push("--vane-v"); cmd.push(props.vaneV) }
    return cmd
  }

  function dispatchAction(cmd) {
    root.preemptStatusPoll()
    actionProcess.killed = false
    actionProcess.requestedAt = Date.now()
    actionProcess.command = cmd
    actionProcess.running = true
  }

  // Debounced write path for everything except power (target temperature,
  // mode, fan speed, either vane axis): merges rapid successive calls into
  // one write after a short pause, instead of one API round-trip per click.
  // Real-world evidence for why this matters, from melcloud.log: five rapid
  // target-temperature clicks each individually succeeded (every "wrote"
  // line confirmed exactly what was sent), and the very next independent
  // status read afterward showed the temperature back at its value from
  // *before* the whole burst -- not one step behind, the pre-burst value.
  // The physical unit can't keep up with writes arriving that rapidly.
  // pymelcloud actually has a built-in debounce for exactly this
  // (device_set_debounce), but it only helps within one long-lived client
  // session -- our one-shot-process-per-action architecture (see
  // melcloud-ctl) means every call is a fresh process, so that debounce
  // never gets a chance to do anything. This is that debounce, moved to
  // where it can actually work.
  //
  // Power is deliberately excluded: it already has its own compressor-
  // protection lock (see powerLocked) that only allows one command through
  // at a time in the first place, so there is nothing here for a debounce
  // to coalesce.
  readonly property int pendingFlushDelayMs: 2000
  property var pendingProps: ({})
  readonly property bool hasPendingProps: Object.keys(root.pendingProps).length > 0
  // Drives the top-of-panel progress line (see KeyboardPanel): animates
  // 1 -> 0 over pendingFlushDelayMs, restarted on every call, so the line
  // always shows time remaining until the *last* click, not the first.
  property real pendingFillFraction: 0

  // What the UI should actually display: a queued-but-unsent value if
  // there is one, otherwise whatever the device last confirmed. Lets
  // clicking +, say, keep incrementing the number shown immediately, even
  // though nothing is sent to MELCloud until the debounce settles.
  readonly property var effectiveTarget: root.pendingProps.target !== undefined
    ? root.pendingProps.target : (root.device ? root.device.target : undefined)
  readonly property string effectiveMode: root.pendingProps.mode !== undefined
    ? root.pendingProps.mode : (root.device ? root.device.mode : "")
  readonly property string effectiveFan: root.pendingProps.fan !== undefined
    ? root.pendingProps.fan : (root.device ? root.device.fan : "")
  readonly property string effectiveVaneH: root.pendingProps.vaneH !== undefined
    ? root.pendingProps.vaneH : (root.device ? root.device.vaneH : "")
  readonly property string effectiveVaneV: root.pendingProps.vaneV !== undefined
    ? root.pendingProps.vaneV : (root.device ? root.device.vaneV : "")

  NumberAnimation {
    id: pendingDrainAnim
    target: root
    property: "pendingFillFraction"
    to: 0
    duration: root.pendingFlushDelayMs
    easing.type: Easing.Linear
  }

  Timer {
    id: pendingFlushTimer
    interval: root.pendingFlushDelayMs
    repeat: false
    onTriggered: root.flushPendingProps()
  }

  function applySet(props) {
    if (!root.device) return
    root.pendingProps = Object.assign({}, root.pendingProps, props)
    root.pendingFillFraction = 1
    pendingDrainAnim.restart()
    pendingFlushTimer.restart()
  }

  function flushPendingProps() {
    if (!root.hasPendingProps) return
    if (root.busy) {
      // An action (or a preempted-poll cleanup) is still finishing up;
      // try again shortly rather than dropping this write.
      pendingFlushTimer.restart()
      return
    }
    var props = root.pendingProps
    root.pendingProps = {}
    root.dispatchAction(root.buildSetCommand(props))
  }

  // Anti-short-cycle protection, symmetric in both directions -- pymelcloud
  // has no knowledge of any of this at all (checked its source: it only has
  // a 1s local write-debounce and a "don't poll more than once a minute"
  // note, neither related to compressor hardware):
  //
  // - restartLockSeconds: Mitsubishi Electric's own indoor-unit firmware
  //   locks the compressor out for up to ~3 minutes after a *stop*, before
  //   it will *restart*. Documented specifically for Mitsubishi Electric
  //   split systems (see the plugin's commit history for sources).
  // - runLockSeconds: a minimum *run* time before a *stop* is honored.
  //   Not something documented specifically for Mitsubishi the way the
  //   restart figure is -- this is general anti-short-cycle practice
  //   (Trane's own published spec is 3 min minimum run / 5 min minimum
  //   off), applied here on the assumption that symmetric protection is
  //   safer to assume than none.
  //
  // This is a plain fixed countdown, not a "check reality and unlock early"
  // scheme like handleProcessResult's staleness guard elsewhere: there is
  // no API field exposing how much longer the compressor's own internal
  // protection timer has left, so there is nothing to poll that would tell
  // us it's actually safe sooner. The countdown starts at click time, not
  // on confirmation, since the physical lockout begins the moment the
  // command reaches the unit, whether or not our own request round-trips
  // cleanly.
  readonly property int restartLockSeconds: 180
  readonly property int runLockSeconds: 180
  property double powerLockUntil: 0
  property int powerLockRemaining: 0
  readonly property bool powerLocked: root.powerLockUntil > 0

  Timer {
    interval: 1000
    repeat: true
    running: root.powerLockUntil > 0
    onTriggered: {
      var remainingMs = root.powerLockUntil - Date.now()
      if (remainingMs <= 0) {
        root.powerLockUntil = 0
        root.powerLockRemaining = 0
      } else {
        root.powerLockRemaining = Math.ceil(remainingMs / 1000)
      }
    }
  }

  function setPower(on) {
    if (root.busy || !root.device || root.powerLocked) return
    root.dispatchAction(root.buildSetCommand({ power: on }))
    var lockSeconds = on ? root.runLockSeconds : root.restartLockSeconds
    root.powerLockUntil = Date.now() + lockSeconds * 1000
    root.powerLockRemaining = lockSeconds
  }
  function setMode(mode) { root.applySet({ mode: mode }) }
  function setFan(fan) { root.applySet({ fan: fan }) }
  function setVaneH(pos) { root.applySet({ vaneH: pos }) }
  function setVaneV(pos) { root.applySet({ vaneV: pos }) }

  // Not applySet: "select" is a config change, not a device write, and needs
  // to work even while root.device is null (e.g. the configured device
  // vanished -- device_not_found still reports the account's full device
  // list, precisely so this stays usable as the way out of that state).
  function selectDevice(id) {
    if (root.busy || (root.device && root.device.id === id)) return
    root.preemptStatusPoll()
    actionProcess.killed = false
    actionProcess.requestedAt = Date.now()
    actionProcess.command = [root.venvPython, "-I", root.ctlScript, "select", "--device-id", String(id)]
    actionProcess.running = true
  }

  function adjustTarget(sign) {
    if (!root.device || root.effectiveTarget === undefined) return
    var step = root.device.targetStep || 0.5
    var min = (root.device.targetMin !== null && root.device.targetMin !== undefined) ? root.device.targetMin : 16
    var max = (root.device.targetMax !== null && root.device.targetMax !== undefined) ? root.device.targetMax : 31
    var next = Math.round((root.effectiveTarget + sign * step) * 10) / 10
    next = Math.max(min, Math.min(max, next))
    if (next === root.effectiveTarget) return
    root.applySet({ target: next })
  }

  function openSetup() {
    root.close()
    Quickshell.execDetached({
      command: [
        "/usr/share/omarchy/bin/omarchy-launch-floating-terminal-with-presentation",
        root.venvPython, "-I", root.setupScript
      ],
      clearEnvironment: true,
      environment: root.desktopEnvironment
    })
    delayedRefresh.restart()
  }

  // --------------------------------------------------------------- processes

  Process {
    id: statusProcess
    running: false
    command: []
    clearEnvironment: true
    environment: root.minimalEnvironment
    property bool killed: false
    // Set only by preemptStatusPoll(), never by the timeout backstop below --
    // distinguishes "the user's action superseded this poll, drop it
    // quietly" from "this genuinely hung," which should still surface as an
    // error. Reset at dispatch time in refresh(), same as killed.
    property bool superseded: false
    property double requestedAt: 0
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(code) {
      if (statusProcess.superseded) return
      root.handleProcessResult(statusProcess.requestedAt, statusProcess.killed, code, statusOut.text, statusErr.text)
    }
  }

  Timer {
    // Backstop for a hung status call: a fresh process does a login plus up
    // to three MELCloud API calls, so this is generous rather than tight.
    interval: 25000
    running: statusProcess.running
    repeat: false
    onTriggered: { statusProcess.killed = true; statusProcess.signal(9) }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    clearEnvironment: true
    environment: root.minimalEnvironment
    property bool killed: false
    property double requestedAt: 0
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(code) {
      root.handleProcessResult(actionProcess.requestedAt, actionProcess.killed, code, actionOut.text, actionErr.text)
    }
  }

  Timer {
    interval: 25000
    running: actionProcess.running
    repeat: false
    onTriggered: { actionProcess.killed = true; actionProcess.signal(9) }
  }

  // -------------------------------------------------------------- bar button

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    dimmed: root.notConfigured || root.hasError || !(root.device && root.device.power)
    active: !!(root.device && root.device.power)
    useActiveColor: true
    activeColor: Color.accent
    tooltipText: root.barTooltip

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // ------------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    // Decorative watermark, painted first so everything else draws over it.
    // Tinted from the theme's own foreground rather than shipped as a black
    // image file: a literal black PNG/SVG would vanish against a dark theme,
    // where root.foreground is closer to white -- this way it stays a plain,
    // colorless (genuinely "black and white") silhouette in either theme.
    AcGlyph {
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.spacing.md
      tint: root.foreground
      opacity: 0.07
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.spacing.panelGap

        // ---------- plugin name ----------

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "MELCloud"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        // ---------- device picker ----------

        Flow {
          visible: root.devices.length > 1
          width: parent.width
          spacing: Style.spacing.sm

          Repeater {
            model: root.devices

            Pill {
              required property var modelData
              label: modelData.name
              selected: !!(root.device && root.device.id === modelData.id)
              enabled: !root.busy
              onClicked: root.selectDevice(modelData.id)
            }
          }
        }

        PanelSeparator { visible: root.devices.length > 1; foreground: root.foreground }

        PanelHero {
          title: root.device ? root.device.name : "MELCloud"
          meta: {
            if (root.notConfigured) return "Not signed in"
            if (root.hasError) return root.errorMessage || root.errorCode
            if (!root.device) return "Loading…"
            var mode = root.modeLabels[root.effectiveMode] || root.effectiveMode
            return root.device.power ? mode : "Off"
          }
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.device && root.device.power ? 1.0 : 0.5

          iconComponent: Text {
            text: root.barText
            color: root.targetTempColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          trailingControl: PanelActionButton {
            iconText: String.fromCodePoint(0xF0450)
            tooltipText: "Refresh"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.refresh()

            RotationAnimation on rotation {
              running: statusProcess.running
              from: 0
              to: 360
              duration: 900
              loops: Animation.Infinite
              onRunningChanged: if (!running) rotation = 0
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---------- not configured / error ----------

        Column {
          visible: root.notConfigured || root.hasError
          width: parent.width
          spacing: Style.spacing.lg
          topPadding: Style.spacing.md
          bottomPadding: Style.spacing.md

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.notConfigured
              ? "Sign in to MELCloud to control an air conditioner from here."
              : ("Could not reach the configured device: " + (root.errorMessage || root.errorCode))
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Pill {
            label: root.notConfigured ? "Sign in" : "Reconfigure"
            selected: true
            onClicked: root.openSetup()
          }
        }

        // ---------- controls ----------

        Column {
          visible: !root.notConfigured && !root.hasError && !!root.device
          width: parent.width
          spacing: Style.spacing.xxl

          Item {
            width: parent.width
            height: powerPill.implicitHeight

            Text {
              id: powerLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Power"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Pill {
              id: powerPill
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              // Labeled by what clicking it *does*, not the current state --
              // "Off" read as a static label was ambiguous about which way
              // a click would go. The highlight color still shows current
              // state at a glance; the text now always names the action.
              label: root.powerLocked
                ? ("Wait " + root.powerLockRemaining + "s")
                : (root.device && root.device.power ? "Turn Off" : "Turn On")
              selected: !!(root.device && root.device.power)
              enabled: !root.busy && !root.powerLocked
              onClicked: root.setPower(!(root.device && root.device.power))
            }
          }

          Text {
            visible: root.powerLocked
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: (root.device && root.device.power)
              ? "Minimum run time before it can be stopped again, to protect the compressor from short-cycling."
              : "Compressor restart lockout after a stop — standard on Mitsubishi hardware, protects the compressor."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            width: parent.width
            spacing: Style.spacing.lg

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "−"
              tooltipText: "Lower target temperature"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.busy && !!root.device
              onClicked: root.adjustTarget(-1)
            }

            Item {
              width: parent.width - Style.space(22) * 2 - Style.spacing.lg * 2
              height: tempRow.implicitHeight
              anchors.verticalCenter: parent.verticalCenter

              Row {
                id: tempRow
                anchors.centerIn: parent
                spacing: Style.spacing.xs

                Text {
                  textFormat: Text.PlainText
                  text: (root.device && root.device.room !== null && root.device.room !== undefined)
                    ? root.device.room.toFixed(1) + "°C" : "—"
                  color: root.currentTempColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: " → "
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: (root.device && root.effectiveTarget !== null && root.effectiveTarget !== undefined)
                    ? root.effectiveTarget.toFixed(1) + "°C" : "—"
                  color: root.targetTempColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }
              }
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "+"
              tooltipText: "Raise target temperature"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.busy && !!root.device
              onClicked: root.adjustTarget(1)
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "room → target"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Flow {
            width: parent.width
            spacing: Style.spacing.sm

            Repeater {
              model: root.device ? root.device.modes : []

              Pill {
                required property string modelData
                label: root.modeLabels[modelData] || modelData
                selected: root.device && root.effectiveMode === modelData
                enabled: !root.busy
                onClicked: root.setMode(modelData)
              }
            }
          }

          LinearControl {
            caption: "Fan speed"
            positions: root.device ? root.device.fans : []
            linearOrder: ["1", "2", "3", "4", "5"]
            specialOrder: ["auto"]
            currentValue: root.device ? root.effectiveFan : ""
            labelFor: function(v) { return v === "auto" ? "Auto" : v }
            sliderTooltip: "Fan speed — drag to set how fast the fan blows, low to high"
            decreaseTooltip: "Lower fan speed"
            increaseTooltip: "Raise fan speed"
            tooltipFor: function(v) { return v === "auto" ? "Let the unit choose fan speed automatically" : "" }
            onPicked: function(value) { root.setFan(value) }
          }

          LinearControl {
            caption: "Blades — left/right"
            positions: root.device ? root.device.vaneHPositions : []
            linearOrder: ["1_left", "2", "3", "4", "5_right"]
            specialOrder: ["auto", "split", "swing"]
            currentValue: root.device ? root.effectiveVaneH : ""
            labelFor: function(v) { return root.vaneHLabels[v] || v }
            sliderTooltip: "Horizontal vane angle — drag to aim the airflow left to right"
            decreaseTooltip: "Aim blades further left"
            increaseTooltip: "Aim blades further right"
            tooltipFor: function(v) {
              if (v === "auto") return "Let the unit choose the horizontal angle automatically"
              if (v === "split") return "Split airflow both left and right at once"
              if (v === "swing") return "Continuously sweep the blades left and right"
              return ""
            }
            onPicked: function(value) { root.setVaneH(value) }
          }

          LinearControl {
            caption: "Blades — up/down"
            positions: root.device ? root.device.vaneVPositions : []
            linearOrder: ["1_up", "2", "3", "4", "5_down"]
            specialOrder: ["auto", "swing"]
            currentValue: root.device ? root.effectiveVaneV : ""
            labelFor: function(v) { return root.vaneVLabels[v] || v }
            sliderTooltip: "Vertical vane angle — drag to aim the airflow up to down"
            decreaseTooltip: "Aim blades further up"
            increaseTooltip: "Aim blades further down"
            tooltipFor: function(v) {
              if (v === "auto") return "Let the unit choose the vertical angle automatically"
              if (v === "swing") return "Continuously sweep the blades up and down"
              return ""
            }
            onPicked: function(value) { root.setVaneV(value) }
          }
        }

        // ---------- loading ----------

        Text {
          visible: !root.notConfigured && !root.hasError && !root.device
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "Loading…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          topPadding: Style.spacing.lg
          bottomPadding: Style.spacing.lg
        }
      }
    }

    // Thin progress line across the very top of the panel: drains while a
    // debounced change (temperature/mode/fan/vane -- see applySet) is
    // waiting to be sent, then turns solid while it's actually in flight.
    // Declared last so it paints over everything else.
    Item {
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.space(2)
      opacity: (root.hasPendingProps || root.busy) ? 1 : 0
      visible: opacity > 0

      Behavior on opacity { NumberAnimation { duration: 150 } }

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
      }

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        color: root.busy ? root.foreground : Color.accent
        width: root.busy ? parent.width : parent.width * root.pendingFillFraction
      }
    }
  }

  // Stylized wall-mounted split-unit AC, drawn as flat vector shapes rather
  // than a shipped image file: `tint` is meant to be bound to a live theme
  // color (root.foreground), and only a shape drawn in QML can actually
  // follow that when the theme changes -- a rasterized asset would need a
  // separate recolor pass to do the same.
  component AcGlyph: Item {
    id: glyph

    property color tint: "black"

    implicitWidth: 180
    implicitHeight: 114

    Rectangle {
      id: body
      x: 6
      y: 4
      width: 168
      height: 50
      radius: 20
      color: "transparent"
      border.color: glyph.tint
      border.width: 5
    }

    Rectangle {
      x: body.x + 22
      y: body.y + body.height - 15
      width: body.width - 44
      height: 3
      radius: 1.5
      color: glyph.tint
    }

    Rectangle {
      x: body.x + body.width - 26
      y: body.y + 13
      width: 8
      height: 8
      radius: 4
      color: glyph.tint
    }

    Shape {
      anchors.fill: parent
      antialiasing: true

      ShapePath {
        strokeColor: glyph.tint
        strokeWidth: 5
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathSvg { path: "M40,64 C24,80 24,96 8,110" }
      }

      ShapePath {
        strokeColor: glyph.tint
        strokeWidth: 5
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathSvg { path: "M92,68 C86,84 86,96 80,110" }
      }

      ShapePath {
        strokeColor: glyph.tint
        strokeWidth: 5
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathSvg { path: "M140,64 C156,80 156,96 172,110" }
      }
    }
  }

  // Small round gauge with a rotating needle -- a generic "how far along a
  // range" indicator, shared by fan speed (range = slow..fast) and both vane
  // axes (range = one end of the blade's travel to the other). Not meant to
  // literally depict a blade or a fan; it's a dial, the same way a
  // speedometer works for both a car and a boat.
  component DialGlyph: Item {
    id: dg

    property real angle: 0
    property color tint: "white"

    Rectangle {
      anchors.centerIn: parent
      width: parent.width * 0.92
      height: parent.height * 0.92
      radius: width / 2
      color: "transparent"
      border.color: dg.tint
      border.width: 2
      opacity: 0.45
    }

    Rectangle {
      anchors.centerIn: parent
      width: parent.width * 0.62
      height: 3
      radius: 1.5
      color: dg.tint
      transformOrigin: Item.Center
      rotation: dg.angle

      Behavior on rotation { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
    }

    Rectangle {
      anchors.centerIn: parent
      width: 5
      height: 5
      radius: 2.5
      color: dg.tint
    }
  }

  // A device property with a fixed set of positions, split into the ones
  // that fall along a line (fan speed 1..N, a vane's numbered stops) and the
  // ones that don't (auto, split, swing) -- the former become a draggable
  // PanelSlider with a DialGlyph reading it out and +/- steppers bracketing
  // it, exactly like the target-temperature row above; the latter become a
  // row of Pills, since "auto" has no position on that line to sit at.
  // `positions` is the full list the device actually reports support for
  // (order doesn't matter -- it's only tested for membership); `linearOrder`
  // and `specialOrder` say how to split and order it. Collapses to nothing
  // (no gap left behind -- Column/Flow skip invisible children) when the
  // device reports no options at all, e.g. a unit with vane control hidden
  // by HideVaneControls.
  component LinearControl: Column {
    id: lc

    property string caption: ""
    property var positions: []
    property var linearOrder: []
    property var specialOrder: []
    property string currentValue: ""
    property var labelFor: function(v) { return v }
    // Hover text. sliderTooltip describes what dragging the slider does;
    // decrease/increaseTooltip describe the step buttons; tooltipFor(v)
    // describes one of the special (non-linear) pills, e.g. "auto"/"swing".
    property string sliderTooltip: ""
    property string decreaseTooltip: ""
    property string increaseTooltip: ""
    property var tooltipFor: function(v) { return "" }
    signal picked(string value)

    readonly property var linear: lc.linearOrder.filter(function(p) { return lc.positions.indexOf(p) !== -1 })
    readonly property var special: lc.specialOrder.filter(function(p) { return lc.positions.indexOf(p) !== -1 })
    readonly property int count: lc.linear.length
    readonly property int currentIndex: {
      var i = lc.linear.indexOf(lc.currentValue)
      return i >= 0 ? i + 1 : Math.max(1, Math.ceil(lc.count / 2))
    }
    // -55..55 degrees rather than a full ±90: a needle pointing straight up
    // or down reads as ambiguous (which side is it leaning?), so the range
    // stays short of vertical at both ends.
    readonly property real dialAngle: lc.count > 1
      ? (-55 + (lc.currentIndex - 1) / (lc.count - 1) * 110)
      : 0

    function step(delta) {
      if (lc.count === 0) return
      var next = Math.max(1, Math.min(lc.count, lc.currentIndex + delta))
      lc.picked(lc.linear[next - 1])
    }

    width: parent ? parent.width : implicitWidth
    spacing: Style.spacing.sm
    visible: lc.positions.length > 0

    Text {
      textFormat: Text.PlainText
      text: lc.caption
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    // Above the slider, per request: auto/split/swing aren't points on the
    // line the slider represents, so they get their own row instead of
    // fighting for a spot on it.
    Flow {
      visible: lc.special.length > 0
      width: lc.width
      spacing: Style.spacing.sm

      Repeater {
        model: lc.special

        Pill {
          required property string modelData
          label: lc.labelFor(modelData)
          tooltipText: lc.tooltipFor(modelData)
          selected: lc.currentValue === modelData
          enabled: !root.busy
          onClicked: lc.picked(modelData)
        }
      }
    }

    Row {
      visible: lc.count > 1
      width: lc.width
      spacing: Style.spacing.lg

      PanelActionButton {
        id: minusBtn
        anchors.verticalCenter: parent.verticalCenter
        iconText: "−"
        tooltipText: lc.decreaseTooltip
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !root.busy
        onClicked: lc.step(-1)
      }

      PanelSlider {
        id: slider
        anchors.verticalCenter: parent.verticalCenter
        bar: root.bar
        enabled: !root.busy
        width: Math.max(Style.space(40), lc.width - minusBtn.width - plusBtn.width - dial.width - Style.spacing.lg * 3)
        minimum: 1
        maximum: Math.max(1, lc.count)
        step: 1
        integer: true
        tickCount: lc.count
        value: lc.currentIndex
        trackColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
        fillColor: root.foreground
        knobColor: root.foreground
        onReleased: function(v) { lc.picked(lc.linear[Math.round(v) - 1]) }

        // Passive hover detection layered over the slider's own MouseArea
        // (which handles the actual drag/click): HoverHandler never accepts
        // or consumes pointer events, so it can watch for hover here without
        // taking anything away from dragging.
        HoverHandler { id: sliderHover }

        PanelToolTip {
          visible: lc.sliderTooltip !== "" && sliderHover.hovered
          text: lc.sliderTooltip
          fontFamily: root.fontFamily
        }
      }

      DialGlyph {
        id: dial
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(30)
        height: Style.space(30)
        angle: lc.dialAngle
        tint: root.foreground
      }

      PanelActionButton {
        id: plusBtn
        anchors.verticalCenter: parent.verticalCenter
        iconText: "+"
        tooltipText: lc.increaseTooltip
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !root.busy
        onClicked: lc.step(1)
      }
    }
  }

  // Small labeled toggle/choice control, used for power, mode, fan speed, and
  // vane position. Not PanelActionButton: that component is a fixed square
  // sized for one icon glyph, and these need to fit a variable-width word
  // like "heat_cool" -> "Auto".
  component Pill: BorderSurface {
    id: pill

    property string label: ""
    property string tooltipText: ""
    property bool selected: false
    property bool enabled: true
    signal clicked()

    readonly property bool hot: mouseArea.containsMouse && pill.enabled

    implicitWidth: pillText.implicitWidth + Style.spacing.xxl * 2
    implicitHeight: Style.spacing.controlHeight
    radius: Style.cornerRadius
    color: pill.selected
      ? Style.selectedFillFor(root.foreground, Color.accent)
      : (pill.hot ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")
    borderSpec: Border.controlSpec(
      pill.selected ? "selected" : (pill.hot ? "hover-cursor" : "normal"),
      root.foreground, Color.accent)

    Text {
      id: pillText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: pill.label
      color: !pill.enabled ? Qt.darker(root.foreground, 2.0) : (pill.selected ? Color.accent : root.foreground)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: pill.selected
    }

    MouseArea {
      id: mouseArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: pill.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: pill.clicked()
    }

    PanelToolTip {
      visible: pill.tooltipText !== "" && mouseArea.containsMouse
      text: pill.tooltipText
      fontFamily: root.fontFamily
    }
  }
}
