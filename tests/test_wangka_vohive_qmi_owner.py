from __future__ import annotations

import importlib.util
import os
import stat
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "config"
    / "vohive"
    / "wangka-vohive-qmi-owner.py"
)


class VoHiveQMIOwnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        spec = importlib.util.spec_from_file_location("wangka_vohive_qmi_owner", MODULE_PATH)
        assert spec and spec.loader
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_repairs_intermediate_at_mode_without_touching_secrets(self) -> None:
        original = """web:\n  password: secret-value\ndevices:\n- id: onboard-qmi\n  modem_imei: 'synthetic-imei'\n  device_backend: at\n  qmi_use_proxy: false\n"""
        updated, changed = self.module.migrate_text(original)
        self.assertTrue(changed)
        self.assertIn("password: secret-value", updated)
        self.assertIn("modem_imei: 'synthetic-imei'", updated)
        self.assertIn("device_backend: qmi", updated)
        self.assertIn("qmi_use_proxy: true", updated)

    def test_qmi_flow_style_is_idempotent(self) -> None:
        original = "devices: [{id: onboard-qmi, device_backend: qmi, qmi_use_proxy: true}]\n"
        updated, changed = self.module.migrate_text(original)
        self.assertFalse(changed)
        self.assertEqual(updated, original)

    def test_atomic_file_migration_preserves_private_mode(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.yaml"
            path.write_text("devices: [{device_backend: at}]\n", encoding="utf-8")
            path.chmod(0o600)
            self.assertTrue(self.module.migrate_file(path))
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(path.read_text(encoding="utf-8"), "devices: [{device_backend: qmi}]\n")
            self.assertTrue(
                all(
                    not name.startswith(".config.yaml.qmi-owner")
                    for name in os.listdir(directory)
                )
            )

    def test_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target.yaml"
            target.write_text("devices: []\n", encoding="utf-8")
            link = root / "config.yaml"
            link.symlink_to(target)
            with self.assertRaises(RuntimeError):
                self.module.migrate_file(link)


if __name__ == "__main__":
    unittest.main()
