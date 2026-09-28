"""Unit tests for the Linux lid/power policy, without suspend or system access."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "lid_power_policy", Path(__file__).resolve().parents[1] / "laptop/lid-power-policy.py"
)
policy_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy_module)


class LidPolicyTests(unittest.TestCase):
    def test_ac_never_starts_a_timer(self):
        policy = policy_module.LidPolicy(300)
        for now in [0, 300, 3600]:
            self.assertFalse(policy.due(True, False, now))
        self.assertIsNone(policy.started)

    def test_battery_requires_a_full_delay(self):
        policy = policy_module.LidPolicy(300)
        self.assertFalse(policy.due(True, True, 50))
        self.assertFalse(policy.due(True, True, 349))
        self.assertTrue(policy.due(True, True, 350))

    def test_open_lid_or_ac_or_unknown_cancels_timer(self):
        for closed, battery in [(False, True), (True, False), (None, True), (True, None)]:
            with self.subTest(closed=closed, battery=battery):
                policy = policy_module.LidPolicy(300)
                self.assertFalse(policy.due(True, True, 0))
                self.assertFalse(policy.due(closed, battery, 299))
                self.assertFalse(policy.due(True, True, 301))
                self.assertFalse(policy.due(True, True, 600))
                self.assertTrue(policy.due(True, True, 601))

    def test_resume_or_failed_suspend_gets_a_new_delay(self):
        policy = policy_module.LidPolicy(300)
        policy.due(True, True, 0)
        self.assertTrue(policy.due(True, True, 300))
        policy.reset()
        self.assertFalse(policy.due(True, True, 500))
        self.assertTrue(policy.due(True, True, 800))


class SensorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def test_lid_unknown_open_and_closed(self):
        self.assertIsNone(policy_module.lid_closed(self.root))
        self.write("LID/state", "state:      closed\n")
        self.assertTrue(policy_module.lid_closed(self.root))
        self.write("LID/state", "state:      open\n")
        self.assertFalse(policy_module.lid_closed(self.root))
        self.write("LID/state", "unexpected\n")
        self.assertIsNone(policy_module.lid_closed(self.root))

    def test_ac_takes_priority_over_battery_status(self):
        self.write("BAT0/type", "Battery")
        self.write("BAT0/status", "Discharging")
        self.assertTrue(policy_module.on_battery(self.root))
        self.write("AC/type", "Mains")
        self.write("AC/online", "1")
        self.assertFalse(policy_module.on_battery(self.root))
        self.write("AC/online", "0")
        self.assertTrue(policy_module.on_battery(self.root))

    def test_usb_c_power_is_external_power(self):
        self.write("USB/type", "USB")
        self.write("USB/online", "1")
        self.assertFalse(policy_module.on_battery(self.root))

    def test_peripheral_battery_is_not_laptop_battery(self):
        self.write("mouse/type", "Battery")
        self.write("mouse/scope", "Device")
        self.write("mouse/status", "Discharging")
        self.assertIsNone(policy_module.on_battery(self.root))

    def test_missing_or_unknown_sensors_do_not_allow_suspend(self):
        self.assertIsNone(policy_module.on_battery(self.root))
        self.write("BAT0/type", "Battery")
        self.write("BAT0/status", "Unknown")
        self.assertIsNone(policy_module.on_battery(self.root))


if __name__ == "__main__":
    unittest.main()
