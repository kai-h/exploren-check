#!/usr/bin/env python3
"""
exploren_check.py — poll Exploren charger status from the terminal.

Reads EXPLOREN_TOKEN from a .env beside this script, or from the
environment (which wins, so you can override for a one-off run).

    .env:
        EXPLOREN_TOKEN=eyJ0eXAi...

    python3 exploren_check.py --location 2151          # one poll, print, exit
    python3 exploren_check.py --location 2151 --watch  # poll until Ctrl-C
    python3 exploren_check.py --location 2151 --watch --notify

    --location 2151       location id (required)
    --evses 6451,6452     identifiers to show (default: all at the location)
    --interval 60         seconds between polls
    --json                dump the raw response and exit
    --env PATH            use a different .env

Stdlib only.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_ENV = Path(__file__).resolve().parent / ".env"

HOST = "exploren.au.charge.ampeco.tech"
URL = f"https://{HOST}/api/v1/app/locations?operatorCountry=AU"

HEADERS = {
    "Host": HOST,
    "Accept": "application/json, text/plain, */*",
    "Content-Type": "application/json",
    "Accept-Language": "en",
    "x-operator-country": "AU",
    "x-platform": "ios",
    "x-mobile-app-bundle-id": "au.com.exploren.cp.app",
    "x-internal-app-version": "3.242.1",
    "User-Agent": "ChargeMobile/1789389616 CFNetwork/3896.100.1.2.1 Darwin/27.0.0",
}

FREE = "available"

# ANSI, only when stdout is a terminal
GREEN, YELLOW, RED, DIM, RESET = (
    ("\033[32m", "\033[33m", "\033[31m", "\033[2m", "\033[0m")
    if sys.stdout.isatty() else ("", "", "", "", "")
)

COLOUR = {
    "available": GREEN,
    "charging": YELLOW,
    "preparing": YELLOW,
    "finishing": YELLOW,
    "faulted": RED,
    "out of order": RED,
}


def load_env(path):
    """Minimal KEY=VALUE parser. Returns {} if the file isn't there.

    Handles: blank lines, # comments, 'export ' prefixes, and single or
    double quoted values. Deliberately does not do interpolation — a JWT
    contains no shell metacharacters worth expanding, and silent
    substitution in a credential is a bad surprise.
    """
    out = {}
    try:
        text = Path(path).read_text()
    except OSError:
        return out

    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = key.strip()
        value = value.strip()
        if value[:1] in ('"', "'"):
            # Quoted: take up to the closing quote, ignore any trailing
            # comment. An unterminated quote falls through to raw.
            quote = value[0]
            end = value.find(quote, 1)
            value = value[1:end] if end > 0 else value
        else:
            # Bare: ' #' starts a comment, a lone '#' does not, since a
            # token could legitimately contain one.
            value = value.split(" #", 1)[0].rstrip()
        if key:
            out[key] = value
    return out


def fetch(token, location):
    body = json.dumps({"locations": {str(location): ""}}).encode()
    req = urllib.request.Request(
        URL, data=body,
        headers=dict(HEADERS, Authorization=f"Bearer {token}"),
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())


def extract(data, wanted):
    """-> (location_name, [(identifier, evse_id, status, max_power_w), ...])"""
    name, rows = None, []
    for loc in data.get("locations", []):
        name = loc.get("name")
        for zone in loc.get("zones", []):
            for e in zone.get("evses", []):
                ident = e.get("identifier")
                if wanted and ident not in wanted:
                    continue
                rows.append((
                    ident,
                    e.get("id"),
                    (e.get("status") or "unknown").lower(),
                    e.get("maxPower"),
                ))
    return name, sorted(rows)


def notify(title, message):
    """macOS Notification Centre. Silently does nothing elsewhere."""
    script = (
        f'display notification {json.dumps(message)} '
        f'with title {json.dumps(title)} sound name "Glass"'
    )
    try:
        subprocess.run(["osascript", "-e", script], check=False,
                       capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--location", required=True,
                    help="location id, e.g. 2151")
    ap.add_argument("--evses", default="all",
                    help="comma-separated identifiers, or 'all'")
    ap.add_argument("--interval", type=int, default=60)
    ap.add_argument("--watch", action="store_true")
    ap.add_argument("--notify", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--env", default=str(DEFAULT_ENV),
                    help="path to .env (default: beside this script)")
    args = ap.parse_args()

    # Environment wins over .env, so a one-off override works without
    # editing the file.
    env = load_env(args.env)
    token = (os.environ.get("EXPLOREN_TOKEN") or env.get("EXPLOREN_TOKEN", "")).strip()
    if not token:
        sys.exit(f"No EXPLOREN_TOKEN found.\n"
                 f"  Create {args.env} containing:\n"
                 f"    EXPLOREN_TOKEN=eyJ0eXAi...\n"
                 f"  or export EXPLOREN_TOKEN in your shell.")

    # Optional defaults from .env, overridden by anything given on the
    # command line.
    if ap.get_default("location") == args.location and env.get("EXPLOREN_LOCATION"):
        args.location = env["EXPLOREN_LOCATION"]
    if ap.get_default("evses") == args.evses and env.get("EXPLOREN_EVSES"):
        args.evses = env["EXPLOREN_EVSES"]

    wanted = None if args.evses.lower() == "all" else {
        e.strip() for e in args.evses.split(",") if e.strip()
    }

    previous = {}
    first = True

    while True:
        try:
            data = fetch(token, args.location)

            if args.json:
                print(json.dumps(data, indent=2))
                return 0

            name, rows = extract(data, wanted)

            if not rows:
                print(f"No matching EVSEs at location {args.location}. "
                      f"Try --evses all to see what's there.")
                return 1

            stamp = time.strftime("%H:%M:%S")
            header = f"{stamp}  {name or 'location ' + str(args.location)}"
            print(f"{DIM}{header}{RESET}")

            for ident, evse_id, status, power in rows:
                col = COLOUR.get(status, "")
                kw = f"{power / 1000:g} kW" if power else "?"
                was = previous.get(ident)
                arrow = f"  {DIM}(was {was}){RESET}" if was and was != status else ""
                print(f"   {ident}  {DIM}evse {evse_id}{RESET}  "
                      f"{col}{status:<12}{RESET} {DIM}{kw}{RESET}{arrow}")

                # Edge into available, suppressed on the first pass
                if (args.notify and not first
                        and status == FREE and was and was != FREE):
                    notify(f"Charger {ident} is free",
                           f"{name or args.location}: {was} -> available")

            previous = {r[0]: r[2] for r in rows}
            first = False

        except urllib.error.HTTPError as exc:
            detail = ""
            try:
                detail = " " + exc.read().decode()[:200]
            except Exception:
                pass
            print(f"HTTP {exc.code}{detail}", file=sys.stderr)
            if exc.code in (401, 403):
                print("Token rejected or expired — capture a fresh one.",
                      file=sys.stderr)
                return 1
        except Exception as exc:
            print(f"{type(exc).__name__}: {exc}", file=sys.stderr)

        if not args.watch:
            return 0

        try:
            time.sleep(args.interval)
        except KeyboardInterrupt:
            print()
            return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print()
        sys.exit(0)
