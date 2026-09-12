#!/usr/bin/env python3
"""Run with python3 tests/pnpm-migration.py. All package commands and homes are mocked."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
BREW = r'''#!/usr/bin/python3
import os, pathlib, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
with (root / 'brew-calls').open('a') as log:
    log.write(' '.join(sys.argv[1:]) + '\n')
args = sys.argv[1:]
prefix = root / 'brew prefix'
if args == ['--prefix']:
    print(prefix)
elif args == ['--prefix', '--installed', 'pnpm@11']:
    if not (root / 'installed').exists(): sys.exit(1)
    print(prefix / 'opt/pnpm@11')
elif args == ['list', '--versions']:
    print('pnpm 12.0.0')
    if (prefix / 'opt/pnpm@11/bin/pnpm').exists(): print('pnpm@11 11.26.0')
elif args == ['list', '--pinned']:
    print('pnpm')
elif args == ['install', 'pnpm@11']:
    if os.environ.get('FAIL_INSTALL'): sys.exit(23)
    target = prefix / 'opt/pnpm@11/bin'
    target.mkdir(parents=True, exist_ok=True)
    for name in ('pnpm', 'pnpx'):
        shutil_source = root / 'pnpm-template'
        out = target / name
        out.write_bytes(shutil_source.read_bytes())
        out.chmod(0o755)
    (root / 'installed').touch()
else:
    sys.exit('unexpected brew call: ' + repr(args))
'''
PNPM = r'''#!/bin/zsh
print "$0 $*" >> "$TEST_ROOT/pnpm-calls"
if [[ "$1" == --version ]]; then
  [[ ! -f package.json ]] || exit 98
  print "${TARGET_VERSION:-11.26.0}"
elif [[ "$1" == child ]]; then
  /bin/zsh -fc 'command -v pnpm'
else
  print "target:$*"
fi
'''


def setup(root):
    repo = root / 'repo with spaces'
    repo.mkdir()
    (repo / 'package.json').write_text('{"packageManager":"pnpm@12.0.0"}')
    for name in ('migrate-pnpm.zsh', 'pnpm-policy.zsh'):
        shutil.copy2(REPO / name, repo / name)
    home = root / 'home'
    home.mkdir()
    zdir = root / 'zsh config'
    zdir.mkdir()
    fake = root / 'bin'
    fake.mkdir()
    (fake / 'brew').write_text(BREW)
    (fake / 'node').write_text('#!/bin/zsh\nprint v24.21.0\n')
    (fake / 'pnpm').write_text('#!/bin/zsh\nprint OLD_PNPM_EXECUTED >> "$TEST_ROOT/old-executed"\n')
    for file in fake.iterdir(): file.chmod(0o755)
    (root / 'pnpm-template').write_text(PNPM)
    env = os.environ | {'HOME': str(home), 'ZDOTDIR': str(zdir), 'PATH': f'{fake}:/usr/bin:/bin',
                        'TEST_ROOT': str(root), 'HOMEBREW_NO_AUTO_UPDATE': '1'}
    return repo, zdir / '.zshrc', env


def run(repo, env, *args):
    return subprocess.run(['/bin/zsh', str(repo / 'migrate-pnpm.zsh'), *args], env=env, cwd=repo,
                          text=True, capture_output=True, timeout=10)


def main():
    with tempfile.TemporaryDirectory(prefix='pnpm-migration-test-') as directory:
        root = Path(directory)
        repo, rc, env = setup(root)
        original = '# keep user settings\nexport USER_SETTING=kept\n'
        rc.write_text(original)
        result = run(repo, env)
        assert result.returncode == 0, result.stderr
        assert rc.read_text() == original
        assert not list(rc.parent.glob('.zshrc.shell-update-pnpm.*'))
        assert not (root / 'old-executed').exists()
        assert 'install ' not in (root / 'brew-calls').read_text()

        result = run(repo, env | {'FAIL_INSTALL': '1'}, '--apply')
        assert result.returncode == 23, (result.stdout, result.stderr)
        assert rc.read_text() == original
        assert not list(rc.parent.glob('.zshrc.shell-update-pnpm.*'))

        result = run(repo, env, '--apply')
        assert result.returncode == 0, (result.stdout, result.stderr)
        backups = list(rc.parent.glob('.zshrc.shell-update-pnpm.*'))
        assert len(backups) == 1 and backups[0].read_text() == original
        applied = rc.read_text()
        assert applied.startswith(original)
        assert applied.count('# >>> shell-update pnpm >>>') == 1
        calls_before = (root / 'brew-calls').read_text().count('install pnpm@11')
        result = run(repo, env, '--apply')
        assert result.returncode == 0, result.stderr
        assert rc.read_text() == applied
        assert list(rc.parent.glob('.zshrc.shell-update-pnpm.*')) == backups
        assert (root / 'brew-calls').read_text().count('install pnpm@11') == calls_before
        assert not (root / 'old-executed').exists()

        # Only the isolated mock rc is sourced. nvm-style PATH changes must not replace pnpm.
        code = '''source "$ZDOTDIR/.zshrc"
source "$ZDOTDIR/.zshrc"
function nvm { export PATH="$TEST_ROOT/bin:$PATH"; }
nvm use 24
pnpm --version
pnpm child
pnpx hello
[[ "$USER_SETTING" == kept ]]
'''
        shell = subprocess.run(['/bin/zsh', '-fc', code], env=env, capture_output=True, text=True, timeout=10)
        assert shell.returncode == 0, shell.stderr
        assert '건너뜁니다' not in shell.stderr, shell.stderr
        assert '11.26.0' in shell.stdout and 'target:hello' in shell.stdout
        assert str(root / 'brew prefix/opt/pnpm@11/bin/pnpm') in shell.stdout
        assert not (root / 'old-executed').exists()

        # Runtime aliases loaded indirectly must be preserved without parser errors.
        alias_file = root / 'plugin.zsh'
        alias_file.write_text("alias pnpm='print USER_ALIAS'\n")
        rc.write_text(f'source "{alias_file}"\n' + applied)
        result = run(repo, env, '--apply')
        assert result.returncode == 0, result.stderr
        shell = subprocess.run(['/bin/zsh', '-fc', 'source "$ZDOTDIR/.zshrc"; alias pnpm'],
                               env=env, capture_output=True, text=True, timeout=10)
        assert shell.returncode == 0, shell.stderr
        assert '건너뜁니다' in shell.stderr and 'USER_ALIAS' in shell.stdout

        # Explicit definitions, edited blocks, and wrong-major installs are not overwritten.
        for content in ("alias pnpm='corepack pnpm'\n", 'function pnpx { print custom; }\n',
                        applied.replace('else\n', 'else # user edit\n', 1)):
            rc.write_text(content)
            result = run(repo, env, '--apply')
            assert result.returncode != 0
            assert rc.read_text() == content
        rc.write_text(original)
        result = run(repo, env | {'TARGET_VERSION': '12.0.0'}, '--apply')
        assert result.returncode != 0 and rc.read_text() == original

        # Never execute pnpm or pnpx links escaping the installed formula root.
        for name in ('pnpm', 'pnpx'):
            binary = root / 'brew prefix/opt/pnpm@11/bin' / name
            binary.unlink()
            binary.symlink_to(root / 'bin/pnpm')
            result = run(repo, env, '--apply')
            assert result.returncode != 0 and rc.read_text() == original
            assert not (root / 'old-executed').exists()
            binary.unlink()
            shutil.copy2(root / 'pnpm-template', binary)
            binary.chmod(0o755)

        # Stale files without Homebrew installation metadata are not treated as installed.
        (root / 'installed').unlink()
        calls_before = (root / 'brew-calls').read_text().count('install pnpm@11')
        result = run(repo, env, '--apply')
        assert result.returncode == 0, result.stderr
        assert (root / 'brew-calls').read_text().count('install pnpm@11') == calls_before + 1

        # An unchanged tool-owned block from an earlier policy can be replaced safely.
        rc.write_text(applied.replace('pnpm@11', 'pnpm@10'))
        result = run(repo, env, '--apply')
        assert result.returncode == 0, result.stderr
        assert rc.read_text().count('# >>> shell-update pnpm >>>') == 1
        assert 'pnpm@10' not in rc.read_text()

        # A manually approved major change replaces one managed block and preserves both sides.
        suffix = '\n# settings after the managed block\nexport AFTER_SETTING=kept\n'
        rc.write_text(applied + suffix)
        (repo / 'pnpm-policy.zsh').write_text('PNPM_MAJOR=12\n')
        (root / 'bin/brew').write_text(BREW.replace('pnpm@11', 'pnpm@12'))
        (root / 'installed').unlink()
        result = run(repo, env | {'TARGET_VERSION': '12.0.0'}, '--apply')
        assert result.returncode == 0, (result.stdout, result.stderr)
        changed = rc.read_text()
        assert changed.startswith(original) and changed.endswith(suffix)
        assert changed.count('# >>> shell-update pnpm >>>') == 1
        assert 'pnpm@12' in changed and 'pnpm@11' not in changed
        print('PASS: diagnosis, failure preservation, repeat apply, nvm PATH, aliases, and conflicts')

    with tempfile.TemporaryDirectory(prefix='pnpm-migration-test-') as directory:
        root = Path(directory)
        repo, rc, env = setup(root)
        target = root / 'dotfiles' / 'zshrc'
        target.parent.mkdir()
        target.write_text('# original symlink target\n')
        rc.symlink_to(target)
        result = run(repo, env, '--apply')
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert rc.is_symlink() and rc.resolve() == target.resolve()
        assert '# >>> shell-update pnpm >>>' in target.read_text()
        backups = list(target.parent.glob('zshrc.shell-update-pnpm.*'))
        assert len(backups) == 1 and backups[0].read_text() == '# original symlink target\n'
        print('PASS: symlink target backup, symlink preservation, and paths with spaces')

    with tempfile.TemporaryDirectory(prefix='pnpm-migration-test-') as directory:
        root = Path(directory)
        repo, rc, env = setup(root)
        result = run(repo, env)
        assert result.returncode == 0 and not rc.exists()
        result = run(repo, env, '--apply')
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert rc.read_text().count('# >>> shell-update pnpm >>>') == 1
        assert not list(rc.parent.glob('.zshrc.shell-update-pnpm.*'))
        print('PASS: missing shell config diagnosis and first apply')


if __name__ == '__main__':
    main()
