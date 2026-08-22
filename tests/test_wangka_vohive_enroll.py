from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "config"
    / "vohive"
    / "wangka-vohive-enroll.py"
)


class VoHiveEnrollTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        spec = importlib.util.spec_from_file_location("wangka_vohive_enroll", MODULE_PATH)
        assert spec and spec.loader
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_credentials_support_template_block_style(self) -> None:
        text = 'web:\n  username: "user"\n  password: "secret-value"\n'
        self.assertEqual(self.module.config_scalar(text, "username"), "user")
        self.assertEqual(self.module.config_scalar(text, "password"), "secret-value")

    def test_credentials_support_vohive_flow_style(self) -> None:
        text = "web: {username: user, password: 'secret,value:2'}\ndevices: []\n"
        self.assertEqual(self.module.config_scalar(text, "username"), "user")
        self.assertEqual(
            self.module.config_scalar(text, "password"), "secret,value:2"
        )


if __name__ == "__main__":
    unittest.main()
