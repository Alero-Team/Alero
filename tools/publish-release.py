#!/usr/bin/env python3
"""Push a source snapshot and version tag to the public repo, which builds, signs and drafts the release."""
import argparse
import io
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from release_notes import metadata  # noqa: E402

PRIVATE = 'k0op4/Alero-Private'
PUBLIC = 'k0op4/Alero'


def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, encoding='utf-8').stdout.strip()


def validate_run(data):
    if (data['repository']['full_name'] != PRIVATE or data['head_branch'] != 'main'
            or data['path'] != '.github/workflows/packages.yml'
            or data['status'] != 'completed' or data['conclusion'] != 'success'
            or not re.fullmatch(r'[0-9a-f]{40}', data['head_sha'])):
        raise ValueError('A successful, completed Packages run on private main is required.')
    return data['head_sha']


def find_run(runs, sha):
    for data in runs:
        try:
            if validate_run(data) == sha:
                return data
        except (KeyError, ValueError):
            pass
    raise ValueError('No successful, completed Packages run on private main for ' + sha)


def exportable(name):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or any(p.lower() == '.git' for p in path.parts) or '\\' in name:
        raise ValueError('Unsafe archive path: ' + name)
    if path.suffix.lower() in {'.jks', '.keystore', '.pem', '.key'} or path.name.startswith('.env') or path.name == 'key.properties':
        raise ValueError('Signing material or environment secrets must not be tracked: ' + name)
    return not (name.startswith(('.claude/', '.codex/')) or name in {'AGENTS.md', 'docs/DEVELOPMENT.md'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--commit', default='origin/main', help='Private commit to publish (default: origin/main)')
    parser.add_argument('--work-directory', required=True, type=Path)
    parser.add_argument('--publish', action='store_true', help='Push the public snapshot and the version tag')
    args = parser.parse_args()
    gh = shutil.which('gh')
    if not gh:
        raise ValueError('GitHub CLI (gh) must be installed and authenticated for both repositories.')
    root = Path(__file__).resolve().parents[1]
    run('git', 'fetch', '--no-tags', 'origin', 'main', cwd=root)
    sha = run('git', 'rev-parse', '--verify', args.commit + '^{commit}', cwd=root)
    runs = json.loads(run(gh, 'api', f'repos/{PRIVATE}/actions/runs?head_sha={sha}&branch=main&status=completed&per_page=100'))
    packages_run = find_run(runs['workflow_runs'], sha)
    pubspec = run('git', 'show', f'{sha}:app/pubspec.yaml', cwd=root)
    changelog = run('git', 'show', f'{sha}:CHANGELOG.md', cwd=root)
    version, title, _ = metadata(pubspec, changelog)
    existing = subprocess.run([gh, 'api', f'repos/{PUBLIC}/git/ref/tags/v{version}'],
                              capture_output=True, encoding='utf-8')
    if existing.returncode == 0:
        raise ValueError('This public tag already exists; it will not be replaced.')
    if '404' not in existing.stderr:
        raise ValueError('Could not check the public tag: ' + existing.stderr)

    work = args.work_directory.resolve()
    work.mkdir(parents=True, exist_ok=False)
    public = work / 'public'
    run('git', 'clone', '--no-checkout', '--single-branch', '--branch', 'main',
        f'https://github.com/{PUBLIC}.git', str(public))
    public_base = run('git', 'rev-parse', 'HEAD', cwd=public)
    spanish = run('git', 'show', 'HEAD:README.md', cwd=public)
    previous = run('git', 'show', 'HEAD:app/pubspec.yaml', cwd=public)
    previous_version = re.search(r'^version: ([^+\s]+)', previous, re.M)[1]
    archive = subprocess.run(['git', 'archive', '--format=zip', sha], cwd=root,
                             check=True, stdout=subprocess.PIPE).stdout
    with zipfile.ZipFile(io.BytesIO(archive)) as source:
        for info in source.infolist():
            if exportable(info.filename):
                source.extract(info, public)
    # Preserve the public-facing Spanish introduction and provide the current English guide.
    spanish = re.sub(r'Beta ' + re.escape(previous_version.removesuffix('.0')) + r'(?![\d.])',
                     'Beta ' + version, spanish).replace(previous_version, version)
    (public / 'README.md').write_text(spanish, encoding='utf-8', newline='\n')
    english = run('git', 'show', f'{sha}:README.md', cwd=root)
    english = re.sub(r'Development, checks and builds run.*?(?=\n## Signing)',
                     'Development and tests take place in a private repository. Packages are built and signed '
                     "by this repository's release workflow when a version tag is pushed, and are published "
                     'as a draft release that is tested before it is made public.\n', english, flags=re.S)
    (public / 'README.en.md').write_text(english + '\n', encoding='utf-8', newline='\n')
    run('git', 'add', '--all', cwd=public)
    # ZIP extraction on Windows does not preserve Git executable bits.
    for line in run('git', 'ls-tree', '-r', sha, cwd=root).splitlines():
        mode, _, path = line.partition('\t')
        if mode.startswith('100755 ') and exportable(path):
            run('git', 'update-index', '--chmod=+x', '--', path, cwd=public)
    run('git', 'diff', '--cached', '--check', cwd=public)
    identity = json.loads(run(gh, 'api', 'user'))
    run('git', 'config', 'user.name', identity['login'], cwd=public)
    run('git', 'config', 'user.email', f"{identity['id']}+{identity['login']}@users.noreply.github.com", cwd=public)
    run('git', 'commit', '-m', title + ': final source snapshot', cwd=public)
    public_sha = run('git', 'rev-parse', 'HEAD', cwd=public)
    plan = dict(version=version, private_run=packages_run['id'], source_sha=sha,
                public_base=public_base, public_sha=public_sha)
    (work / 'release-plan.json').write_text(json.dumps(plan, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(plan, indent=2), flush=True)
    if not args.publish:
        print('Prepared only. No push performed.')
        return
    run('git', 'push', '--atomic', 'origin', 'HEAD:refs/heads/main',
        f'HEAD:refs/tags/v{version}', cwd=public)
    print(f'Pushed. Watch the build: https://github.com/{PUBLIC}/actions\n'
          f'Then test the draft and publish it: gh release edit v{version} --repo {PUBLIC} --draft=false --latest')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        # git diff --check reports on stdout: without it the script would stop without saying why.
        detail = (exc.stderr or exc.stdout) if isinstance(exc, subprocess.CalledProcessError) else str(exc)
        raise SystemExit(detail)
