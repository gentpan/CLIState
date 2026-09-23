import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


version = load("local_version")
cleaner = load("clean_local_copies")


class LocalDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.project = self.root / "project.yml"
        self.project.write_text('    MARKETING_VERSION: "0.2.0"\n    CURRENT_PROJECT_VERSION: "0007"\n')

    def tearDown(self):
        self.temp.cleanup()

    def app(self, path, identifier="com.clistate.app"):
        contents = path / "Contents"
        contents.mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as target:
            plistlib.dump({"CFBundleIdentifier": identifier}, target)
        return path

    def test_local_builds_keep_marketing_version_and_increment_decimal(self):
        for expected in [8, 9, 10]:
            self.assertEqual(version.bump(self.project), ("0.2.0", expected))
            self.assertIn(f'"{expected:04d}"', self.project.read_text())

    def test_only_explicit_release_changes_marketing_version(self):
        self.assertEqual(version.bump(self.project, "0.2.1"), ("0.2.1", 8))
        for invalid in ["1.0.0", "0.2", "0.2.1.0", "0.1.9", "0.2.1"]:
            with self.assertRaises(ValueError):
                version.bump(self.project, invalid)

    def test_four_digit_build_cannot_overflow(self):
        self.project.write_text(self.project.read_text().replace("0007", "9999"))
        with self.assertRaises(ValueError):
            version.bump(self.project)
        self.assertEqual(version.read_version(self.project), ("0.2.0", 9999))

    def test_changelog_prepends_new_build_and_rejects_duplicate(self):
        changelog = self.root / "CHANGELOG.md"
        version.record(self.project, changelog, ["修复扫描状态"])
        version.bump(self.project)
        version.record(self.project, changelog, ["清理旧 App 副本"])
        text = changelog.read_text()
        self.assertLess(text.index("(0008)"), text.index("(0007)"))
        self.assertIn("修复扫描状态", text)
        with self.assertRaises(ValueError):
            version.record(self.project, changelog, ["重复"])

    def test_cleanup_keeps_installed_app_unrelated_apps_and_user_data(self):
        installed = self.app(self.root / "Applications/CLIState.app")
        old = self.app(self.root / "build/CLIState.app")
        renamed = self.app(self.root / "Applications/CLI State old.app")
        unrelated = self.app(self.root / "build/Other.app", "com.other.app")
        settings = self.root / "settings.json"
        settings.write_text("keep")
        copies = cleaner.find_copies([self.root], installed)
        self.assertEqual(set(copies), {old.resolve(), renamed.resolve()})
        cleaner.remove_copies(copies + [installed, unrelated], installed)
        self.assertTrue(installed.exists())
        self.assertTrue(unrelated.exists())
        self.assertEqual(settings.read_text(), "keep")
        self.assertFalse(old.exists())
        self.assertFalse(renamed.exists())

    def test_cleanup_revalidates_identity_and_requires_installation(self):
        old = self.app(self.root / "Old.app")
        with self.assertRaises(ValueError):
            cleaner.remove_copies([old], self.root / "Missing.app")
        installed = self.app(self.root / "Installed.app")
        copies = cleaner.find_copies([self.root], installed)
        with (old / "Contents/Info.plist").open("wb") as target:
            plistlib.dump({"CFBundleIdentifier": "com.other.app"}, target)
        cleaner.remove_copies(copies, installed)
        self.assertTrue(old.exists())

    def test_failed_build_does_not_install_a_stale_product(self):
        scripts = self.root / "scripts"
        (scripts / "tests").mkdir(parents=True)
        (scripts / "tests/test_stub.py").write_text("import unittest\nclass Stub(unittest.TestCase):\n    def test_ready(self): pass\n")
        for name in ["install-local.sh", "bump-version.sh", "local_version.py"]:
            shutil.copy2(SCRIPTS / name, scripts / name)
        stale = self.app(self.root / "build-local/Build/Products/Release/CLIState.app")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name, body in {"swift": "exit 0", "xcodegen": "exit 0", "xcodebuild": "echo simulated-build-failure >&2; exit 7", "pkill": "touch stopped-app; exit 1", "open": "touch opened-app"}.items():
            command = bin_dir / name
            command.write_text("#!/bin/bash\n" + body + "\n")
            command.chmod(0o755)
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])
        result = subprocess.run(["/bin/bash", str(scripts / "install-local.sh"), "测试构建失败"], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("simulated-build-failure", result.stderr)
        self.assertTrue(stale.exists())
        self.assertFalse((self.root / "stopped-app").exists())
        self.assertFalse((self.root / "opened-app").exists())
        self.assertFalse((self.root / "CHANGELOG.md").exists())
        self.assertFalse((self.root / "build-local/.install-lock").exists())


if __name__ == "__main__":
    unittest.main()
