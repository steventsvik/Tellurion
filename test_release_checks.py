#!/usr/bin/env python3
"""Tries release-checks.sh on files made to pass and made to fail."""
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "release-checks.sh"
SWITCHES = [f"TELLURION_TEST_SWITCH_{letter}" for letter in "ABCDEFGHIJKLMNOPQRSTUVWXY"]


def run(*arguments):
    return subprocess.run([str(SCRIPT), *map(str, arguments)], capture_output=True, text=True)


class Folder(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)


class GhosttyVersion(Folder):
    def version(self, text):
        path = self.folder / "build.zig.zon"
        path.write_text(text)
        return run("ghostty-version", path)

    def test_reads_the_package_version(self):
        result = self.version('.{\n    .name = .ghostty,\n    .version = "1.4.0",\n}\n')
        self.assertEqual((result.returncode, result.stdout), (0, "1.4.0\n"))

    def test_keeps_a_prerelease_suffix(self):
        self.assertEqual(self.version('    .version = "1.5.0-dev",\n').stdout, "1.5.0-dev\n")

    def test_ignores_a_dependency_version(self):
        text = '.{\n    .dependencies = .{\n        .x = .{\n            .version = "9.9.9",\n        },\n    },\n    .version = "1.4.0",\n}\n'
        self.assertEqual(self.version(text).stdout, "1.4.0\n")

    def test_only_a_dependency_version_is_a_failure(self):
        self.assertEqual(self.version('        .version = "9.9.9",\n').returncode, 2)

    def test_a_commented_out_version_doesnt_count(self):
        self.assertEqual(self.version('    // .version = "1.0.0",\n').returncode, 2)

    def test_a_version_that_isnt_one_is_a_failure(self):
        self.assertEqual(self.version('    .version = "latest",\n').returncode, 2)

    def test_empty_and_missing_files_fail(self):
        self.assertEqual(self.version("").returncode, 2)
        self.assertEqual(run("ghostty-version", self.folder / "absent").returncode, 2)
        self.assertEqual(run("ghostty-version", self.folder).returncode, 2)

    def test_the_real_file_has_a_version(self):
        result = run("ghostty-version", HERE / "build.zig.zon")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"^\d+\.\d+\.\d+")


class TestSwitches(Folder):
    def setUp(self):
        super().setUp()
        self.sources = self.folder / "Sources"
        self.sources.mkdir()
        self.write_sources(SWITCHES)
        self.binary = self.folder / "binary"

    def write_sources(self, names):
        lines = [f'let a = TestHooks.value("{name}")' for name in names[:-1]]
        lines.append(f'let b = TestHooks.flag("{names[-1]}")')
        (self.sources / "Hooks.swift").write_text("\n".join(lines) + "\n")

    def check(self, content):
        self.binary.write_bytes(content)
        return run("test-switches", self.binary, self.sources)

    def test_a_binary_without_them_passes(self):
        result = self.check(b"\x00\xff code \x00TELLURION_TEST_HOME\x00TELLURION_VENICE_TOKEN\x00")
        self.assertEqual((result.returncode, result.stdout), (0, ""), result.stderr)

    def test_one_switch_is_enough_to_fail_and_is_named(self):
        result = self.check(b"\x00\xcf\xfa" + SWITCHES[7].encode() + b"\x00\xff")
        self.assertEqual((result.returncode, result.stdout), (1, SWITCHES[7] + "\n"))

    def test_a_flag_counts_as_much_as_a_value(self):
        self.assertEqual(self.check(SWITCHES[-1].encode()).returncode, 1)

    def test_found_at_the_very_start_and_end_of_the_file(self):
        self.assertEqual(self.check(SWITCHES[0].encode() + b"\x00rest").returncode, 1)
        self.assertEqual(self.check(b"rest\x00" + SWITCHES[0].encode()).returncode, 1)

    def test_every_one_is_listed_once(self):
        result = self.check(b"\x00".join(s.encode() for s in SWITCHES * 2))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.split(), sorted(SWITCHES))

    def test_the_old_name_is_not_what_it_looks_for(self):
        result = self.check(b"GHOSTTY_EXTREME_TEST_TABS\x00")
        self.assertEqual(result.returncode, 0)

    def test_a_rename_is_followed(self):
        renamed = [name.replace("TELLURION_", "NEWNAME_") + "_X" for name in SWITCHES]
        self.write_sources(renamed)
        self.assertEqual(self.check(SWITCHES[0].encode()).returncode, 0)
        self.assertEqual(self.check(renamed[0].encode()).returncode, 1)

    def test_a_name_swift_hides_is_not_searched(self):
        self.write_sources(SWITCHES + ["TELLURION_DEMO"])
        self.assertEqual(self.check(b"\x00TELLURION_DEMO\x00").returncode, 0)

    def test_too_few_names_is_a_failure_not_a_pass(self):
        self.write_sources(SWITCHES[:19])
        result = self.check(b"nothing")
        self.assertEqual(result.returncode, 2)
        self.assertIn("too few", result.stderr)

    def test_names_only_count_once_toward_the_minimum(self):
        self.write_sources(SWITCHES[:19] * 3)
        self.assertEqual(self.check(b"nothing").returncode, 2)

    def test_no_names_at_all_is_a_failure(self):
        (self.sources / "Hooks.swift").write_text("let a = 1\n")
        self.assertEqual(self.check(b"nothing").returncode, 2)

    def test_only_swift_files_count(self):
        (self.sources / "Hooks.swift").unlink()
        (self.sources / "notes.md").write_text("\n".join(f'value("{n}")' for n in SWITCHES))
        self.assertEqual(self.check(b"nothing").returncode, 2)

    def test_sources_in_subfolders_are_found(self):
        moved = self.sources / "Features" / "Test Hooks"
        moved.mkdir(parents=True)
        (self.sources / "Hooks.swift").rename(moved / "Hooks.swift")
        self.assertEqual(self.check(SWITCHES[0].encode()).returncode, 1)

    def test_a_binary_that_cant_be_read_is_a_failure_not_a_pass(self):
        self.assertEqual(run("test-switches", self.folder / "absent", self.sources).returncode, 2)
        self.assertEqual(run("test-switches", self.folder, self.sources).returncode, 2)
        self.assertEqual(self.check(b"").returncode, 2)

    def test_an_absent_source_folder_is_a_failure(self):
        self.binary.write_bytes(b"x")
        self.assertEqual(run("test-switches", self.binary, self.folder / "absent").returncode, 2)

    def test_the_wrong_arguments_are_a_failure(self):
        self.assertEqual(run().returncode, 2)
        self.assertEqual(run("test-switches", self.binary).returncode, 2)
        self.assertEqual(run("other", "a", "b").returncode, 2)

    def test_the_real_sources_list_only_test_switches(self):
        self.binary.write_bytes(b"nothing")
        result = run("test-switches", self.binary, HERE / "macos" / "Sources")
        self.assertEqual(result.returncode, 0, result.stderr)
        names = subprocess.run(
            ["grep", "-rhoE", r'(value|flag)\("[A-Z][A-Z0-9_]*"\)', "--include=*.swift", str(HERE / "macos" / "Sources")],
            capture_output=True, text=True).stdout.split()
        for name in {line.split('"')[1] for line in names}:
            self.assertRegex(name, r"^TELLURION_(TEST|DEMO)")
            self.assertNotEqual(name, "TELLURION_TEST_HOME", "the release keeps this one")


if __name__ == "__main__":
    unittest.main()
