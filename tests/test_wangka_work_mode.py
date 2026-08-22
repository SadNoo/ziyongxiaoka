import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "config/network/wangka-work-mode.py"
SPEC = importlib.util.spec_from_file_location("wangka_work_mode", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class WorkModeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        root = Path(self.tempdir.name)
        self.state_dir = root / "state"
        MODULE.STATE_DIR = self.state_dir
        MODULE.STATE_FILE = self.state_dir / "state.json"
        MODULE.LOCK_FILE = self.state_dir / "state.lock"
        MODULE.OPERATION_LOCK_FILE = self.state_dir / "work-mode.lock"

    def read_state(self):
        return json.loads(MODULE.STATE_FILE.read_text(encoding="utf-8"))

    def test_default_mode_is_dual(self) -> None:
        status = MODULE.public_status(MODULE.load_state())
        self.assertEqual(status["mode"], "dual")
        self.assertTrue(status["data_enabled"])
        self.assertTrue(status["sms_enabled"])

    @mock.patch.object(MODULE, "run_modem")
    def test_sms_mode_suspends_data_and_persists(self, run_modem) -> None:
        run_modem.return_value = {"status": "ok"}
        result = MODULE.switch_mode("sms")
        run_modem.assert_called_once_with("data-suspend")
        self.assertFalse(result["data_enabled"])
        self.assertTrue(result["sms_enabled"])
        self.assertEqual(self.read_state()["work_mode"], "sms")
        self.assertEqual(MODULE.STATE_FILE.stat().st_mode & 0o777, 0o600)

    @mock.patch.object(MODULE, "run_modem")
    def test_data_mode_disables_sms_and_reconnects_saved_uplink(self, run_modem) -> None:
        run_modem.return_value = {"status": "skipped", "reason": "radio-not-ready"}
        with mock.patch.object(MODULE, "restart_vohive") as restart:
            result = MODULE.switch_mode("data")
        restart.assert_called_once_with()
        run_modem.assert_called_once_with("reconnect-saved-uplink")
        self.assertTrue(result["data_enabled"])
        self.assertFalse(result["sms_enabled"])
        self.assertEqual(result["modem"]["reason"], "radio-not-ready")

    @mock.patch.object(MODULE, "run_modem")
    def test_leaving_data_mode_restarts_sms_engine(self, run_modem) -> None:
        MODULE.save_state({**MODULE.default_state(), "work_mode": "data"})
        run_modem.return_value = {"status": "ok"}
        with mock.patch.object(MODULE, "restart_vohive") as restart:
            result = MODULE.switch_mode("sms")
        restart.assert_called_once_with()
        run_modem.assert_called_once_with("data-suspend")
        self.assertTrue(result["sms_enabled"])

    @mock.patch.object(MODULE, "best_effort_restore")
    @mock.patch.object(MODULE, "restart_vohive")
    def test_failed_sms_engine_restart_rolls_back(self, restart, restore) -> None:
        restart.side_effect = MODULE.WorkModeError("restart failed")
        with self.assertRaisesRegex(MODULE.WorkModeError, "rolled back"):
            MODULE.switch_mode("data")
        self.assertEqual(self.read_state()["work_mode"], "dual")
        restore.assert_called_once_with("dual", True)

    @mock.patch.object(MODULE, "best_effort_restore")
    @mock.patch.object(MODULE, "run_modem")
    def test_failed_switch_rolls_back(self, run_modem, restore) -> None:
        MODULE.save_state({**MODULE.default_state(), "work_mode": "dual"})
        run_modem.side_effect = MODULE.WorkModeError("not ready")
        with self.assertRaisesRegex(MODULE.WorkModeError, "rolled back"):
            MODULE.switch_mode("sms")
        state = self.read_state()
        self.assertEqual(state["work_mode"], "dual")
        self.assertEqual(state["work_mode_last_result"], "rolled-back")
        restore.assert_called_once_with("dual", False)

    @mock.patch.object(MODULE, "run_modem")
    def test_reconcile_keeps_sms_mode_when_modem_is_cold(self, run_modem) -> None:
        MODULE.save_state({**MODULE.default_state(), "work_mode": "sms"})
        run_modem.side_effect = MODULE.WorkModeError("cold")
        result = MODULE.reconcile()
        self.assertEqual(result["mode"], "sms")
        self.assertEqual(result["last_result"], "pending")
        self.assertEqual(self.read_state()["work_mode"], "sms")

    @mock.patch.object(MODULE, "run_modem")
    def test_reconcile_does_not_cycle_healthy_data_mode(self, run_modem) -> None:
        MODULE.save_state({**MODULE.default_state(), "work_mode": "data"})
        result = MODULE.reconcile()
        run_modem.assert_not_called()
        self.assertEqual(result["mode"], "data")
        self.assertEqual(
            result["reconcile_skipped"],
            "uplink-manager-owns-data-recovery",
        )

    def test_reconcile_skips_instead_of_queueing_during_switch(self) -> None:
        MODULE.save_state(
            {
                **MODULE.default_state(),
                "work_mode": "data",
                "work_mode_transition": "data",
                "work_mode_last_result": "switching",
            }
        )
        with MODULE.OperationLock() as operation:
            self.assertTrue(operation.acquired)
            result = MODULE.reconcile()
        self.assertEqual(
            result["reconcile_skipped"],
            "work-mode-operation-in-progress",
        )

    def test_duplicate_switch_returns_existing_transition_without_queueing(self) -> None:
        MODULE.save_state(
            {
                **MODULE.default_state(),
                "work_mode": "data",
                "work_mode_transition": "data",
                "work_mode_last_result": "switching",
            }
        )
        with MODULE.OperationLock() as operation:
            self.assertTrue(operation.acquired)
            result = MODULE.switch_mode("data")
        self.assertEqual(result["transition"], "data")
        self.assertEqual(result["last_result"], "switching")

    def test_different_switch_is_rejected_while_operation_is_running(self) -> None:
        MODULE.save_state(
            {
                **MODULE.default_state(),
                "work_mode": "data",
                "work_mode_transition": "data",
                "work_mode_last_result": "switching",
            }
        )
        with MODULE.OperationLock() as operation:
            self.assertTrue(operation.acquired)
            with self.assertRaisesRegex(MODULE.WorkModeError, "already running"):
                MODULE.switch_mode("sms")

    def test_invalid_persisted_mode_falls_back_to_dual(self) -> None:
        self.state_dir.mkdir(mode=0o700)
        MODULE.STATE_FILE.write_text('{"work_mode":"unknown"}\n', encoding="utf-8")
        self.assertEqual(MODULE.load_state()["work_mode"], "dual")


if __name__ == "__main__":
    unittest.main()
