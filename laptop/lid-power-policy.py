#!/usr/bin/env python3
"""Suspend a closed Linux laptop after a continuous battery-only delay.

Run under systemd-inhibit --what=handle-lid-switch. Installation and desktop
power-manager settings belong to distributed-dotfiles, not this helper.
"""

import argparse
import json
import logging
from pathlib import Path
import subprocess
import time


LOG = logging.getLogger("lid-power-policy")


def read_text(path):
    try:
        return path.read_text().strip()
    except OSError:
        return None


def lid_closed(root=Path("/proc/acpi/button/lid")):
    states = [read_text(path) for path in root.glob("*/state")]
    if any(state and state.split()[-1] == "open" for state in states):
        return False
    if states and all(state and state.split()[-1] == "closed" for state in states):
        return True
    return None


def on_battery(root=Path("/sys/class/power_supply")):
    batteries = []
    for supply in root.glob("*"):
        if read_text(supply / "scope") == "Device":
            continue
        if read_text(supply / "type") == "Battery":
            if read_text(supply / "present") != "0":
                batteries.append(read_text(supply / "status"))
        elif read_text(supply / "online") == "1":
            return False
    if "Discharging" in batteries:
        return True
    # Unknown, stale, or absent sensor data must never cause suspension.
    return None


class LidPolicy:
    def __init__(self, delay):
        self.delay = delay
        self.started = None

    def due(self, closed, battery, now):
        if closed is not True or battery is not True:
            if self.started is not None:
                LOG.info("Cancelled battery lid-close timer")
            self.started = None
            return False
        if self.started is None:
            self.started = now
            LOG.info("Lid closed on battery; suspend delay is %s seconds", self.delay)
        return now - self.started >= self.delay

    def reset(self):
        self.started = None


def positive_int(value):
    result = int(value)
    if result <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--delay", type=positive_int, default=300, help="battery delay in seconds, default 300")
    parser.add_argument("--interval", type=positive_int, default=10, help="sensor polling interval in seconds, default 10")
    parser.add_argument("--check", action="store_true", help="report sensor support without suspending")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    if args.check:
        state = {"lid_closed": lid_closed(), "on_battery": on_battery()}
        print(json.dumps(state))
        return 0 if all(value is not None for value in state.values()) else 1

    policy = LidPolicy(args.delay)
    while True:
        try:
            if policy.due(lid_closed(), on_battery(), time.monotonic()):
                # Recheck both inputs immediately before requesting suspension.
                if lid_closed() is True and on_battery() is True:
                    LOG.info("Battery lid-close delay elapsed; requesting suspend")
                    result = subprocess.run(["systemctl", "suspend"], check=False, timeout=60)
                    if result.returncode:
                        LOG.error("Suspend request failed with status %s", result.returncode)
                # Resume or a failed request starts a new full delay, not a retry loop.
                policy.reset()
        except (OSError, subprocess.TimeoutExpired) as error:
            LOG.error("Lid policy check failed: %s", error)
            policy.reset()
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
