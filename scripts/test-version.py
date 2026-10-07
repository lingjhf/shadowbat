#!/usr/bin/env python3
"""Check release metadata without modifying the repository or creating tags."""
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('check_version', pathlib.Path(__file__).with_name('check-version.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class VersionChecks(unittest.TestCase):
    def test_stable_and_prerelease(self):
        for version in ('1.3.8+16', '2.0.0-beta.1+17', '2.0.0-0+18', '2.0.0-01a+19'):
            with self.subTest(version=version):
                self.assertEqual(module.validate_version(f'version: {version}\n', 'v' + version, f'# Changelog\n\n## {version}\n'), version)

    def test_malformed_versions(self):
        for version in ('1.3.8', '01.3.8+16', '1.3.8+0', '1.3.8+016', '1.3.8-beta..1+16', '1.3.8-beta.01+16', '1.3.8-+16', '1.3.8+1６'):
            with self.subTest(version=version), self.assertRaises(ValueError):
                module.validate_version(f'version: {version}\n')

    def test_missing_or_duplicate_version(self):
        for pubspec in ('name: shadowbat\n', 'version: 1.3.8+16\nversion: 1.3.8+16\n'):
            with self.subTest(pubspec=pubspec), self.assertRaises(ValueError):
                module.validate_version(pubspec)

    def test_tag_must_include_exact_build_number(self):
        for tag in ('v1.3.8', 'v1.3.8+15', '1.3.8+16'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                module.validate_version('version: 1.3.8+16\n', tag)

    def test_changelog_must_have_exact_release_heading(self):
        for changelog in ('## 1.3.8+15\n', 'Mention 1.3.8+16\n', '## 1.3.8+16-extra\n'):
            with self.subTest(changelog=changelog), self.assertRaises(ValueError):
                module.validate_version('version: 1.3.8+16\n', changelog=changelog)


if __name__ == '__main__':
    unittest.main()
