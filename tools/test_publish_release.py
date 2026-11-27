"""Checks release boundaries without accessing GitHub or changing a repository."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('publish_release', Path(__file__).with_name('publish-release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
import release_notes as notes_tool  # noqa: E402


class ReleaseTest(unittest.TestCase):
    def test_only_a_successful_private_main_packages_run_can_be_promoted(self):
        good = dict(repository=dict(full_name=release.PRIVATE), head_branch='main',
                    path='.github/workflows/packages.yml', status='completed',
                    conclusion='success', head_sha='a' * 40)
        self.assertEqual(release.validate_run(good), 'a' * 40)
        for field, value in [('repository', dict(full_name=release.PUBLIC)), ('head_branch', 'codex/test'),
                             ('status', 'in_progress'), ('conclusion', 'failure'),
                             ('path', '.github/workflows/ci.yml'), ('head_sha', 'main')]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                release.validate_run(dict(good, **{field: value}))

    def test_the_run_must_match_the_exact_commit(self):
        good = dict(repository=dict(full_name=release.PRIVATE), head_branch='main',
                    path='.github/workflows/packages.yml', status='completed',
                    conclusion='success', head_sha='a' * 40)
        self.assertIs(release.find_run([dict(good, conclusion='failure'), good], 'a' * 40), good)
        with self.assertRaises(ValueError):
            release.find_run([good], 'b' * 40)

    def test_changelog_matches_the_version_and_excludes_the_previous_release(self):
        changelog = '# Cambios\n\n## Beta 2.6.1 (2.6.1) — 2026-11-24\n\n- Fixed motion.\n\n## Beta 2.6 (2.6.0) — yesterday\n\n- Previous.\n'
        version, title, notes = notes_tool.metadata('version: 2.6.1+42\n', changelog)
        self.assertEqual((version, title), ('2.6.1', 'Alero Beta 2.6.1'))
        self.assertNotIn('Previous', notes)
        for pubspec in ['version: 2.6.2+43', 'version: 2.6.1', 'version: invalid']:
            with self.subTest(pubspec=pubspec), self.assertRaises(ValueError):
                notes_tool.metadata(pubspec, changelog)

    def test_a_stable_release_stops_calling_the_public_readme_a_beta(self):
        readme = ('<img src="https://img.shields.io/badge/Estado-Beta-F59E0B" alt="Versión Beta" />\n'
                  'Versión 2.6.3.\nAlero sigue en fase Beta. Descarga siempre el APK y el instalador de la misma versión.\n')
        beta = release.spanish_readme(readme, '2.6.3', '2.6.4', 'Alero Beta 2.6.4')
        self.assertIn('Estado-Beta', beta)
        self.assertIn('2.6.4', beta)
        stable = release.spanish_readme(readme, '2.6.3', '3.0.0', 'Alero 3.0')
        self.assertNotIn('Beta', stable)
        self.assertIn('Estado-Estable', stable)
        self.assertIn('Versión 3.0.0.\nDescarga siempre', stable)

    def test_all_six_matching_packages_and_hashes_are_required(self):
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            suffixes = ['android-arm64.apk', 'windows-x64-setup.exe', 'linux-amd64.deb',
                        'linux-x86_64.rpm', 'linux-x86_64.AppImage', 'linux-x86_64.tar.gz']
            for suffix in suffixes:
                package = folder / ('Alero-2.6.1-' + suffix)
                package.write_bytes(b'verified package')
                digest = hashlib.sha256(package.read_bytes()).hexdigest()
                package.with_name(package.name + '.sha256').write_text(digest + '  ' + package.name)
            self.assertEqual(len(notes_tool.verify_packages(folder, '2.6.1')), 6)
            package.write_bytes(b'changed package')
            with self.assertRaises(ValueError):
                notes_tool.verify_packages(folder, '2.6.1')
            package.unlink()
            with self.assertRaises(ValueError):
                notes_tool.verify_packages(folder, '2.6.1')

    def test_notes_list_every_hash_and_the_checksums_file(self):
        hashes = {'Alero-1-a': 'a' * 64, 'Alero-1-b': 'b' * 64}
        self.assertEqual(notes_tool.checksums(hashes), 'a' * 64 + '  Alero-1-a\n' + 'b' * 64 + '  Alero-1-b\n')
        text = notes_tool.release_notes('- Fixed.', hashes, 'c' * 40)
        self.assertIn('| `Alero-1-b` | `' + 'b' * 64 + '` |', text)
        self.assertTrue(text.endswith('Source snapshot: `' + 'c' * 40 + '`.\n'))

    def test_workflows_reach_the_public_snapshot_but_private_files_and_unsafe_paths_do_not(self):
        for name in ['daemon/src/island/ui.rs', '.github/workflows/packages.yml', 'tools/publish-release.py']:
            self.assertTrue(release.exportable(name))
        for name in ['docs/DEVELOPMENT.md', 'AGENTS.md', '.claude/settings.json']:
            self.assertFalse(release.exportable(name))
        for name in ['../secret', '/absolute', '.git/config', '.GiT/config', 'dir\\..\\secret',
                     'app/android/key.properties', '.env.production', 'signing.keystore']:
            with self.assertRaises(ValueError):
                release.exportable(name)


if __name__ == '__main__':
    unittest.main()
