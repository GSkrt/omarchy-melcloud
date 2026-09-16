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

Every package installed into that venv — pip itself, pymelcloud, and every
one of pymelcloud's transitive dependencies — is pinned to an exact version
and verified against a sha256 hash from
[`requirements.txt`](requirements.txt), via `pip install --require-hashes`.
Nothing is pulled from whatever the package index happens to be currently
serving. See that file's own header for how to regenerate it after bumping
a version.

## Set up your MELCloud account

Click the new "AC" bar icon and choose **Sign in**. That opens a floating
terminal running `melcloud-setup`, which asks for your MELCloud email and
password, verifies them against MELCloud, and asks which air conditioner to
start with if your account has more than one -- the rest stay reachable from
the panel afterward (see below), so this pick is just a starting point.

The password is saved to your login keyring via `secret-tool`
(libsecret/gnome-keyring) — never written to a plain file. The account
email and a lightweight id/name list of your devices (for the panel's
device picker) are saved, non-secret, in
`~/.config/omarchy-melcloud/config.json` — a separate file,
`devices_cache.json`, caches the full API response for up to 30 minutes to
avoid re-fetching it on every call (see "Protecting the compressor and the
account" below). You can re-run setup at any time
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
  fan speed on a slider with a small dial readout, and aim the vanes the
  same way, horizontally and vertically. Fan speed and vane rows only appear
  for the axes your unit actually reports support for, and everything
  interactive (sliders, +/- buttons, the Auto/Split/Swing pills) has a hover
  tooltip explaining what it does.
- Opening the panel always refreshes; in the background, it polls MELCloud
  every 15 minutes by default. See "Protecting the compressor and the
  account" below for why both of those numbers are what they are.

## Protecting the compressor and the account

Two separate things this plugin deliberately holds back from doing
instantly, both learned by testing against a real unit (see the commit
history and `melcloud.log` for the evidence):

**The power button waits out compressor protection, in both directions.**
Turning off locks *turning back on* for up to 3 minutes — documented
specifically for [Mitsubishi Electric hardware as compressor short-cycle
protection](https://blossomaircon.com/mitsubishi-aircon-protect-stop/).
Turning on locks *turning back off* for up to 3 minutes too — not documented
specifically for Mitsubishi, but standard anti-short-cycle practice
generally ([Trane's own published spec](https://www.trane.com/residential/en/resources/glossary/hvac-short-cycling/):
3 min minimum run, 5 min minimum off). The button shows a live countdown
and a short explanation while locked; stopping/starting itself is never
restricted, only re-doing
the *opposite* action too soon after. `pymelcloud` has no knowledge of any
of this — checked its source directly, it only has a 1s local write-debounce
and a "don't poll more than once a minute" note, neither about compressor
hardware.

**Rapid clicks on temperature/mode/fan/vane are batched, not sent one at a
time.** Five quick clicks on the target-temperature `+` button used to
become five separate API writes within about six seconds. Every one of them
individually succeeded — but the very next independent status read
afterward showed the temperature back at its value from *before the whole
burst*, not one step behind. The physical unit can't keep up with writes
arriving that fast. `pymelcloud` actually has a built-in debounce for
exactly this (`device_set_debounce`), but it only works within one
long-lived client session — this plugin runs each action as a fresh
one-shot process (see "How it works" below), so that debounce never gets a
chance to run. Panel.qml now does its own: rapid clicks update the display
immediately but only send one write, 2 seconds after the last click
(matching Home Assistant's own `device_set_debounce` for the same purpose),
with a thin progress line across the top of the panel showing the countdown
and then turning solid while the write is actually in flight. Power is exempt —
it already has its own lock above, which only allows one command through at
a time regardless.

**Both of the above are about the *unit*; this is about the *MELCloud
account*.** Fetching the device list (which units exist, their supported
modes/fan speeds/temperature range — not their live state) used to happen
on every single call: every status poll and every set/select action, not
just the periodic background poll. [Home Assistant's own MELCloud
integration](https://github.com/home-assistant/core/blob/dev/homeassistant/components/melcloud/coordinator.py)
caches exactly this for 30 minutes and polls live device state no more than
every 15 minutes — both numbers pulled directly from its current source,
chosen there after MELCloud [rate-limited accounts hard enough to return
HTTP 429 and temporarily lock people
out](https://github.com/home-assistant/core/issues/109728). This plugin now
matches both: the device list is cached to
`~/.config/omarchy-melcloud/devices_cache.json` for 30 minutes, and the
background poll interval (configurable, still respected in the panel's
settings) defaults to 15 minutes, floored at 3 minutes. Opening the panel still
always fetches live state for the one thing you actually came to look at —
only the passive background polling backed off.

## How it works

Everything that talks to MELCloud lives in `bin/`, as small Python scripts
run inside the private venv:

- `melcloud-ctl status` / `set ...` / `select --device-id ...` — the panel's
  backend. Prints one JSON object and always exits 0, even on failure, so
  the QML side has something well-formed to parse either way. Every call
  reports the full list of ATA devices on the account (free -- it comes back
  from MELCloud alongside everything else `status`/`set` already fetch), not
  just the selected one; that's what the panel's device picker is built from.
  `select` just changes which device id is "current" in config.json. The
  underlying API response this is built from is itself cached (see
  "Protecting the compressor and the account" above) in
  `~/.config/omarchy-melcloud/devices_cache.json` for up to 30 minutes;
  `melcloud-setup` always bypasses that cache, so re-running setup always
  sees your account's current devices.
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
