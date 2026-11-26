#!/usr/bin/env python3
"""Release metadata, package verification and notes; used by publish-release.py and the release workflow."""
import argparse
import hashlib
from pathlib import Path
import re

SUFFIXES = ['android-arm64.apk', 'windows-x64-setup.exe', 'linux-amd64.deb',
            'linux-x86_64.rpm', 'linux-x86_64.AppImage', 'linux-x86_64.tar.gz']


def metadata(pubspec, changelog):
    match = re.search(r'^version: (\d+\.\d+\.\d+)\+\d+\s*$', pubspec, re.M)
    if not match:
        raise ValueError('Expected a three-part release version and build number.')
    version = match[1]
    heading = re.search(r'^## (.+?) \(' + re.escape(version) + r'\) — [^\n]+\n', changelog, re.M)
    if not heading:
        raise ValueError('Missing changelog section for this version.')
    notes = re.split(r'^## ', changelog[heading.end():], maxsplit=1, flags=re.M)[0].strip()
    if not notes or not re.search(r'^- ', notes, re.M):
        raise ValueError('The release needs nonempty changelog entries.')
    return version, 'Alero ' + heading[1], notes


def verify_packages(folder, version):
    expected = {f'Alero-{version}-{suffix}' for suffix in SUFFIXES}
    actual = {p.name for p in folder.iterdir() if not p.name.endswith('.sha256') and p.name != 'SHA256SUMS.txt'}
    if actual != expected:
        raise ValueError(f'Unexpected/missing packages: {sorted(actual ^ expected)}')
    hashes = {}
    for name in sorted(expected):
        content = (folder / (name + '.sha256')).read_text(encoding='utf-8').strip()
        match = re.fullmatch(r'([0-9a-fA-F]{64})\s+\*?(.+)', content)
        with (folder / name).open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if not match or match[2] != name or match[1].lower() != digest:
            raise ValueError('Invalid or mismatched SHA-256: ' + name)
        hashes[name] = digest
    return hashes


def checksums(hashes):
    return ''.join(f'{digest}  {name}\n' for name, digest in hashes.items())


def release_notes(notes, hashes, source):
    notes += '\n\n### SHA-256\n\n| Archivo | SHA-256 |\n| --- | --- |\n'
    notes += ''.join(f'| `{name}` | `{digest}` |\n' for name, digest in hashes.items())
    return notes + f'\nSource snapshot: `{source}`.\n'


def main():
    parser = argparse.ArgumentParser(description='Verify downloaded packages, write SHA256SUMS.txt and the notes file; prints the release title.')
    parser.add_argument('--tag', required=True)
    parser.add_argument('--packages', required=True, type=Path)
    parser.add_argument('--notes-file', required=True, type=Path)
    parser.add_argument('--source', required=True, help='Commit SHA of the source snapshot')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    version, title, notes = metadata((args.root / 'app/pubspec.yaml').read_text(encoding='utf-8'),
                                     (args.root / 'CHANGELOG.md').read_text(encoding='utf-8'))
    if args.tag != 'v' + version:
        raise SystemExit(f'Tag {args.tag} does not match app/pubspec.yaml version v{version}.')
    try:
        hashes = verify_packages(args.packages, version)
    except (ValueError, OSError) as exc:
        raise SystemExit(str(exc))
    (args.packages / 'SHA256SUMS.txt').write_text(checksums(hashes), encoding='utf-8', newline='\n')
    args.notes_file.write_text(release_notes(notes, hashes, args.source), encoding='utf-8', newline='\n')
    print(title)


if __name__ == '__main__':
    try:
        main()
    except ValueError as exc:
        raise SystemExit(str(exc))
