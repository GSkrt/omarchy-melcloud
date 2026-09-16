# OmaMELCloud

An [Omarchy](https://omarchy.org) bar plugin that controls your Mitsubishi
Electric air conditioners (each an "ATA" / split-system device) through
[MELCloud](https://app.melcloud.com), using the
[pymelcloud](https://pypi.org/project/pymelcloud/) library. Built for
controlling the AC in a room from the bar: power, mode, fan speed, vane
(blade) direction, and target temperature, alongside the current room
temperature -- and switching between units from one panel if your account
has more than one.

Not affiliated with, endorsed by, or supported by Mitsubishi Electric.
"MELCloud" is used here only to name the third-party service this plugin
talks to.

## Install

```
git clone https://github.com/GSkrt/omarchy-melcloud.git ~/.config/omarchy/plugins/io.github.gskrt.melcloud
~/.config/omarchy/plugins/io.github.gskrt.melcloud/install.sh
```

`install.sh` creates a private Python virtual environment at
`~/.local/share/omarchy-melcloud/venv` (pymelcloud and its dependency
aiohttp are not part of Omarchy's system Python) and adds the widget to the
bar. It needs no `sudo`.

## Set up your MELCloud account

Click the new "AC" bar icon and choose **Sign in**. That opens a floating
terminal running `melcloud-setup`, which asks for your MELCloud email and
password, verifies them against MELCloud, and asks which air conditioner to
start with if your account has more than one -- the rest stay reachable from
the panel afterward (see below), so this pick is just a starting point.

The password is saved to your login keyring via `secret-tool`
(libsecret/gnome-keyring) — never written to a plain file. The account email
and the device list are saved, non-secret, in
`~/.config/omarchy-melcloud/config.json`. You can re-run setup at any time
from the panel's **Reconfigure** button to switch accounts.

## Using it

- The bar shows the currently-selected unit's room temperature (falling back
  to its target temperature, or "AC", if no reading is available yet),
  dimmed while that unit is off.
- Click it to open the panel. If your account has more than one air
  conditioner, a row of pills at the top lets you switch which one the rest
  of the panel controls -- it's hidden entirely when there's only one.
- Below that: toggle power; see current room temperature and target
  temperature together (current dimmer, target full color -- both tinted
  orange while heating, blue while cooling, teal while drying, and plain
  otherwise), with target adjustable via +/-; pick a mode
  (Heat/Dry/Cool/Fan/Auto — whichever your unit actually supports); pick a
  fan speed; and aim the vanes, horizontally and vertically. Fan speed and
  vane rows only appear for the axes your unit actually reports support for.
- The panel polls MELCloud every 60 seconds by default. That interval is
  configurable in the plugin's settings (30–600s isn't offered — MELCloud
  asks integrations not to poll a device's state more than about once a
  minute, and the floor here respects that).

## How it works

Everything that talks to MELCloud lives in `bin/`, as small Python scripts
run inside the private venv:

- `melcloud-ctl status` / `set ...` / `select --device-id ...` — the panel's
  backend. Prints one JSON object and always exits 0, even on failure, so
  the QML side has something well-formed to parse either way. Every call
  reports the full list of ATA devices on the account (free -- it comes back
  from MELCloud alongside everything else `status`/`set` already fetch), not
  just the selected one; that's what the panel's device picker is built from.
  `select` just changes which device id is "current" in config.json.
- `melcloud-setup` — the interactive sign-in/reconfigure flow, run in a
  floating terminal.

Panel.qml only ever shells out to these two scripts and parses their JSON —
it never calls MELCloud directly.

Every `melcloud-ctl` invocation appends a couple of lines to
`~/.config/omarchy-melcloud/melcloud.log` (auto-trimmed to the last 400
lines): when it started, what it read from MELCloud, what it wrote (if
anything), and what it returned, each tagged with its process id. Two
overlapping invocations -- a background poll racing a click, say -- show up
as interleaved lines with different pids, which is what makes that kind of
bug possible to actually diagnose instead of guessed at.

The panel itself also refuses to run a background status poll and a
user-triggered action at the same time (see the `preemptStatusPoll`/`refresh`
comments in Panel.qml): they're two independent processes each doing their
own MELCloud round-trip, and MELCloud gives no ordering guarantee between
two concurrent requests, so letting both run at once could show a value
reverting right after you set it.

## Uninstall

```
~/.config/omarchy/plugins/io.github.gskrt.melcloud/uninstall.sh
rm -rf ~/.config/omarchy/plugins/io.github.gskrt.melcloud
```

`uninstall.sh` removes the bar widget and the venv, but leaves your saved
MELCloud sign-in in place. It prints the two commands to remove that too
(`rm -rf ~/.config/omarchy-melcloud` and `secret-tool clear service
omarchy-melcloud`) if you want a clean slate.

## Acknowledgements

This plugin is a thin QML/bar wrapper around
[pymelcloud](https://github.com/vilppuvuorinen/pymelcloud) by Vilppu
Vuorinen and contributors — all the actual MELCloud protocol work (auth,
device discovery, state, and the ATA/ATW/ERV write logic) is theirs. Thanks
for maintaining it.

## License

MIT
