import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "config/led/wangka-led-controller.py"
SPEC = importlib.util.spec_from_file_location("wangka_led_controller", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class LEDControllerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        MODULE.STATE_DIR = root / "state"
        MODULE.STATE_FILE = MODULE.STATE_DIR / "state.json"
        MODULE.RUNTIME_FILE = root / "run" / "status.json"
        MODULE.THERMAL_ROOT = root / "thermal"
        MODULE.LED_ROOT = root / "leds"
        MODULE.STATE_DIR.mkdir()
        MODULE.THERMAL_ROOT.mkdir()
        MODULE.LED_ROOT.mkdir()
        for name in MODULE.LED_NAMES.values():
            path = MODULE.LED_ROOT / name
            path.mkdir()
            for file, value in (
                ("trigger", "none"),
                ("brightness", "0"),
                ("delay_on", "0"),
                ("delay_off", "0"),
            ):
                (path / file).write_text(value, encoding="ascii")

    def save(self, **fields):
        state = {"work_mode": "dual", "led_enabled": True, "led_night_mode": False}
        state.update(fields)
        MODULE.STATE_FILE.write_text(json.dumps(state), encoding="utf-8")
        return state

    def test_mode_colours_are_white_green_and_blue(self) -> None:
        for mode, color in (("dual", "white"), ("data", "green"), ("sms", "blue")):
            status = MODULE.decide_effect(self.save(work_mode=mode), 70.0, True)
            self.assertEqual(status["mode_color"], color)
            self.assertEqual(status["color"], color)
            self.assertEqual(status["pattern"], "steady")

    def test_disabled_and_night_mode_turn_off_normal_light(self) -> None:
        disabled = MODULE.decide_effect(self.save(led_enabled=False), 70.0, True)
        self.assertEqual(disabled["source"], "setting")
        self.assertEqual(disabled["color"], "off")
        night = MODULE.decide_effect(self.save(led_night_mode=True), 70.0, True)
        self.assertEqual(night["source"], "night-mode")
        self.assertEqual(night["color"], "off")
        self.assertEqual(night["mode_color"], "white")

    def test_thermal_warning_and_critical_override_night_mode(self) -> None:
        state = self.save(led_night_mode=True)
        warning = MODULE.decide_effect(state, 86.0, True)
        self.assertEqual((warning["color"], warning["pattern"]), ("yellow", "slow-blink"))
        critical = MODULE.decide_effect(state, 93.0, True)
        self.assertEqual((critical["color"], critical["pattern"]), ("red", "fast-blink"))

    def test_transition_uses_target_mode_colour(self) -> None:
        status = MODULE.decide_effect(
            self.save(work_mode="dual", work_mode_transition="sms"), 70.0, True
        )
        self.assertEqual(status["color"], "blue")
        self.assertEqual(status["pattern"], "slow-blink")
        self.assertEqual(status["mode"], "sms")

    def test_pending_cellular_state_is_yellow(self) -> None:
        status = MODULE.decide_effect(
            self.save(work_mode_last_result="pending"), 70.0, True
        )
        self.assertEqual(status["source"], "cellular-warning")
        self.assertEqual(status["color"], "yellow")

    def test_apply_steady_white_controls_all_three_channels(self) -> None:
        self.save()
        with mock.patch.object(MODULE, "thermal_maximum", return_value=70.0), mock.patch.object(
            MODULE, "backend_reachable", return_value=True
        ):
            status = MODULE.apply_once()
        self.assertEqual(status["status"], "ok")
        for name in MODULE.LED_NAMES.values():
            self.assertEqual((MODULE.LED_ROOT / name / "brightness").read_text(), "1")
        self.assertEqual(json.loads(MODULE.RUNTIME_FILE.read_text())["color"], "white")

    def test_apply_blink_uses_kernel_timer(self) -> None:
        self.save(work_mode_transition="data")
        with mock.patch.object(MODULE, "thermal_maximum", return_value=70.0), mock.patch.object(
            MODULE, "backend_reachable", return_value=True
        ):
            MODULE.apply_once()
        green = MODULE.LED_ROOT / MODULE.LED_NAMES["green"]
        self.assertEqual((green / "trigger").read_text(), "timer")
        self.assertEqual((green / "delay_on").read_text(), "900")
        self.assertEqual((green / "delay_off").read_text(), "900")
        self.assertEqual(
            (MODULE.LED_ROOT / MODULE.LED_NAMES["red"] / "brightness").read_text(), "0"
        )


if __name__ == "__main__":
    unittest.main()
