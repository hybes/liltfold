import unittest
from pathlib import Path
from unittest.mock import patch

from tools.build import minimum_macos


class BundleTargetTests(unittest.TestCase):
    @patch("tools.build.subprocess.check_output")
    def test_newest_bundled_target_wins_without_mistaking_linker_version(self, output):
        output.side_effect = [
            "Load command 1\n cmd LC_BUILD_VERSION\n minos 14.0\n ntools 1\n version 27037.1\n",
            "Load command 2\n cmd LC_BUILD_VERSION\n minos 27.0\n",
            "Load command 3\n cmd LC_VERSION_MIN_MACOSX\n cmdsize 16\n version 12.3\n",
        ]
        self.assertEqual(minimum_macos(map(Path, ["app", "ffmpeg", "library"])), "27.0.0")

    @patch("tools.build.subprocess.check_output", return_value="")
    def test_native_ui_minimum_is_the_floor(self, _output):
        self.assertEqual(minimum_macos([Path("app")]), "14.0.0")

    @patch("tools.build.subprocess.check_output")
    def test_static_archive_uses_the_newest_member(self, output):
        output.return_value = (
            "Archive: lib.a\nLoad command 1\n cmd LC_BUILD_VERSION\n minos 11.0\n"
            "lib.a(std.o):\nLoad command 2\n cmd LC_BUILD_VERSION\n minos 27.0\n sdk 28.0\n"
        )
        self.assertEqual(minimum_macos([Path("lib.a")]), "27.0.0")


if __name__ == "__main__":
    unittest.main()
