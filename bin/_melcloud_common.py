"""Shared MELCloud helpers for melcloud-ctl and melcloud-setup.

Both entry points run as `python3 -I <script>` (isolated mode — see Panel.qml),
which skips Python's automatic script-directory sys.path prepend. Each caller
works around that itself with an explicit `sys.path.insert(0, ...)` before
importing this module; see the top of either script for why that is safe to
do even under -I.

Credentials are split two ways on purpose: the MELCloud password never
touches disk as plain text — it lives in the user's login keyring via
secret-tool (libsecret/gnome-keyring), reached over the D-Bus session bus.
Everything else (the account email, the chosen device id, and a short-lived
login token) is non-secret-ish bookkeeping and lives in a plain JSON file
under ~/.config/omarchy-melcloud/, chmod 600 as a matter of course.
"""
import json
import os
import subprocess
import time
from datetime import datetime
from pathlib import Path

CONFIG_DIR = Path.home() / ".config" / "omarchy-melcloud"
CONFIG_FILE = CONFIG_DIR / "config.json"
TOKEN_FILE = CONFIG_DIR / "token.json"
DEVICES_CACHE_FILE = CONFIG_DIR / "devices_cache.json"
LOG_FILE = CONFIG_DIR / "melcloud.log"
LOG_MAX_LINES = 400

SECRET_TOOL = "/usr/bin/secret-tool"
SECRET_SERVICE = "omarchy-melcloud"

# MELCloud context keys are not documented as expiring on a fixed schedule;
# this is a conservative cap so a stale token doesn't get trusted forever. Any
# API call that actually fails with 401/403 clears the cache immediately,
# regardless of this TTL.
TOKEN_TTL_SECONDS = 12 * 3600

# How long the device list (ListDevices + GetUserDetails -- static identity
# and capabilities, not live state) is trusted before being refetched.
# Matches Home Assistant's own MELCloud integration exactly, chosen there
# ("matches upstream Throttle value") after MELCloud rate-limited accounts
# hard enough to lock people out over exactly this kind of call.
DEVICES_CACHE_TTL_SECONDS = 30 * 60


class MelCloudError(Exception):
    """A user-facing MELCloud failure, tagged with a short machine-readable code."""

    def __init__(self, code, message=""):
        super().__init__(message or code)
        self.code = code
        self.message = message


def load_config():
    try:
        return json.loads(CONFIG_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_config(config):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(config))
    CONFIG_FILE.chmod(0o600)


def load_cached_token():
    try:
        data = json.loads(TOKEN_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    token = data.get("token")
    obtained_at = data.get("obtainedAt")
    if not token or not isinstance(obtained_at, (int, float)):
        return None
    if time.time() - obtained_at > TOKEN_TTL_SECONDS:
        return None
    return token


def save_token(token):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    TOKEN_FILE.write_text(json.dumps({"token": token, "obtainedAt": time.time()}))
    TOKEN_FILE.chmod(0o600)


def clear_token():
    try:
        TOKEN_FILE.unlink()
    except FileNotFoundError:
        pass


def load_cached_device_confs():
    try:
        data = json.loads(DEVICES_CACHE_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    cached_at = data.get("cachedAt")
    confs = data.get("confs")
    if not isinstance(cached_at, (int, float)) or not isinstance(confs, list):
        return None
    if time.time() - cached_at > DEVICES_CACHE_TTL_SECONDS:
        return None
    return confs


def save_device_confs_cache(confs):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    DEVICES_CACHE_FILE.write_text(json.dumps({"cachedAt": time.time(), "confs": confs}))
    DEVICES_CACHE_FILE.chmod(0o600)


def get_password(email):
    """Look up the MELCloud password for `email` in the login keyring."""
    try:
        result = subprocess.run(
            [SECRET_TOOL, "lookup", "service", SECRET_SERVICE, "account", email],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0 or not result.stdout:
        return None
    return result.stdout


def set_password(email, password):
    """Store `password` for `email` in the login keyring, replacing any prior entry."""
    subprocess.run(
        [SECRET_TOOL, "store", "--label", "MELCloud (%s)" % email,
         "service", SECRET_SERVICE, "account", email],
        input=password, capture_output=True, text=True, timeout=10, check=True,
    )


async def obtain_token(session, email, password):
    """Log in to MELCloud and cache the resulting token. Raises on failure.

    A bad email/password comes back from MELCloud as HTTP 200 with an empty
    LoginData, which pymelcloud.login() turns into an AttributeError/TypeError
    while reaching for .token on nothing useful — callers should catch those
    alongside aiohttp.ClientError.
    """
    import pymelcloud
    token = await pymelcloud.login(email, password, session)
    save_token(token)
    return token


async def fetch_devices(session, token, use_cache=True):
    """Return the ATA (air-to-air, i.e. split system) devices on this account.

    device_set_debounce is zeroed out: pymelcloud's default exists to let a
    long-lived client coalesce rapid writes, but every invocation here is a
    fresh, one-shot process, so there is nothing to coalesce and no reason
    to make a `set` wait out an artificial debounce (the panel does its own
    debouncing before ever calling this -- see Panel.qml's applySet).

    Device *state* (power, temperature, mode, ...) always comes from a live
    Device/Get via device.update(), called separately by every caller of
    this function -- that is unaffected by use_cache. What use_cache
    controls is the *device list and its static capabilities* (which units
    exist, their supported modes/fan speeds/temperature range), fetched via
    MELCloud's ListDevices + GetUserDetails. Home Assistant's own MELCloud
    integration caches exactly this for 30 minutes ("matches upstream
    Throttle value", per its source) after MELCloud rate-limited accounts
    hard enough to lock people out (HTTP 429, "excessive traffic"). Without
    this cache, every single invocation of this CLI -- every status poll
    *and* every set/select action -- re-ran both of those calls from
    scratch, which is the single biggest source of avoidable MELCloud
    traffic in this plugin.
    """
    cached_confs = load_cached_device_confs() if use_cache else None
    if cached_confs is not None:
        from pymelcloud.ata_device import AtaDevice
        from pymelcloud.client import Client as _Client
        client = _Client(token, session)
        return [
            AtaDevice(conf, client)
            for conf in cached_confs
            if conf.get("Device", {}).get("DeviceType") == 0
        ]

    from datetime import timedelta
    import pymelcloud
    groups = await pymelcloud.get_devices(
        token, session,
        conf_update_interval=timedelta(seconds=0),
        device_set_debounce=timedelta(seconds=0),
    )
    devices = groups.get("ata", [])
    save_device_confs_cache([d._device_conf for d in devices])  # noqa: SLF001
    return devices


async def get_ata_devices(session, email, use_cache=True):
    """Return (token, [AtaDevice, ...]), reusing a cached token when possible.

    On a 401/403 from a cached token, the cache is dropped and this retries
    exactly once with a fresh login.
    """
    import aiohttp

    token = load_cached_token() if use_cache else None
    if token is None:
        password = get_password(email)
        if not password:
            raise MelCloudError("no_password", "No MELCloud password saved for %s" % email)
        try:
            token = await obtain_token(session, email, password)
        except aiohttp.ClientError as exc:
            raise MelCloudError("network_error", str(exc)) from exc
        except (AttributeError, KeyError, TypeError) as exc:
            raise MelCloudError("auth_failed", "MELCloud rejected the saved email/password") from exc

    try:
        devices = await fetch_devices(session, token)
    except aiohttp.ClientResponseError as exc:
        if exc.status in (401, 403) and use_cache:
            clear_token()
            return await get_ata_devices(session, email, use_cache=False)
        raise MelCloudError("network_error", str(exc)) from exc
    except aiohttp.ClientError as exc:
        raise MelCloudError("network_error", str(exc)) from exc

    return token, devices


def device_to_json(device):
    return {
        "id": device.device_id,
        "buildingId": device.building_id,
        "name": device.name,
        "power": device.power,
        "mode": device.operation_mode,
        "modes": device.operation_modes,
        "target": device.target_temperature,
        "targetMin": device.target_temperature_min,
        "targetMax": device.target_temperature_max,
        "targetStep": device.target_temperature_step,
        "room": device.room_temperature,
        "fan": device.fan_speed,
        "fans": device.fan_speeds,
        "vaneH": device.vane_horizontal,
        "vaneHPositions": device.vane_horizontal_positions,
        "vaneV": device.vane_vertical,
        "vaneVPositions": device.vane_vertical_positions,
        "hasError": device.has_error,
    }


def log(message):
    """Append one line to the debug log, trimmed to the last LOG_MAX_LINES.

    Keyed by pid and wall-clock time so two overlapping invocations (a
    background status poll racing a user's click, say) show up as
    interleaved lines that are easy to tell apart -- that overlap is
    exactly the kind of bug this log exists to make visible. Never raises:
    a logging failure should not take down the actual MELCloud call.
    """
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        line = "%s pid=%d %s\n" % (datetime.now().isoformat(timespec="milliseconds"), os.getpid(), message)
        lines = []
        if LOG_FILE.exists():
            lines = LOG_FILE.read_text().splitlines(keepends=True)
        lines.append(line)
        if len(lines) > LOG_MAX_LINES:
            lines = lines[-LOG_MAX_LINES:]
        LOG_FILE.write_text("".join(lines))
    except OSError:
        pass


def emit(payload):
    log("emit " + json.dumps(payload)[:400])
    print(json.dumps(payload))


def emit_error(code, message="", **extra):
    payload = {"ok": False, "error": code, "message": message}
    payload.update(extra)
    emit(payload)
