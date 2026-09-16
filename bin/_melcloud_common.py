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
import subprocess
import time
from pathlib import Path

CONFIG_DIR = Path.home() / ".config" / "omarchy-melcloud"
CONFIG_FILE = CONFIG_DIR / "config.json"
TOKEN_FILE = CONFIG_DIR / "token.json"

SECRET_TOOL = "/usr/bin/secret-tool"
SECRET_SERVICE = "omarchy-melcloud"

# MELCloud context keys are not documented as expiring on a fixed schedule;
# this is a conservative cap so a stale token doesn't get trusted forever. Any
# API call that actually fails with 401/403 clears the cache immediately,
# regardless of this TTL.
TOKEN_TTL_SECONDS = 12 * 3600


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


async def fetch_devices(session, token):
    """Return the ATA (air-to-air, i.e. split system) devices on this account.

    conf_update_interval/device_set_debounce are zeroed out: pymelcloud's
    defaults exist to let a long-lived client amortize calls and debounce
    writes across repeated use, but every invocation here is a fresh,
    one-shot process, so there is nothing to amortize and no reason to make
    a `set` wait out an artificial debounce.
    """
    from datetime import timedelta
    import pymelcloud
    groups = await pymelcloud.get_devices(
        token, session,
        conf_update_interval=timedelta(seconds=0),
        device_set_debounce=timedelta(seconds=0),
    )
    return groups.get("ata", [])


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


def emit(payload):
    print(json.dumps(payload))


def emit_error(code, message="", **extra):
    payload = {"ok": False, "error": code, "message": message}
    payload.update(extra)
    emit(payload)
