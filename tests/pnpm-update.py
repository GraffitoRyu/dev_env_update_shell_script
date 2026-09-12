#!/usr/bin/env python3
"""Run with python3 tests/pnpm-update.py; all package commands are mocked."""
import json
import os
from pathlib import Path
import pty
import shutil
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
MOCK = r'''
import json, os, pathlib, shutil, sys
root = pathlib.Path(os.environ['TEST_DIR'])
mode = os.environ['MODE']
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'calls').open('a') as stream:
    stream.write(json.dumps([name, args]) + '\n')
if name == 'brew':
    if args[:2] == ['--prefix', '--installed']:
        if mode == 'missing': sys.exit(1)
        print(root / 'pnpm')
    elif args == ['--prefix', 'nvm']:
        print(root / 'nvm')
    elif args == ['outdated', '--formula', '--quiet']:
        if mode == 'outdated-failure': sys.exit(29)
        if mode != 'empty':
            print('pnpm\npnpm@10\npnpm@11\nlocal/tools/pnpm\nlocal/tools/pnpm@9')
        if mode == 'mixed': print('wget\nlocal/tools/tool')
    elif args == ['list', '--formula', '--pinned']:
        if mode == 'pinned': print('pnpm@11')
    elif args == ['upgrade', 'pnpm@11'] and mode == 'upgrade-failure':
        sys.exit(23)
    elif args not in (['update'], ['upgrade', 'pnpm@11'], ['upgrade', '--cask'], ['upgrade', '--formula', 'wget', 'local/tools/tool']):
        sys.exit('unexpected brew call: ' + repr(args))
elif name == 'node': print('v24.21.0')
elif name == 'npm':
    if args == ['-v']: print('11.19.0')
elif name == 'pnpm':
    (root / 'pnpm-context').write_text(json.dumps([os.getcwd(), shutil.which('node')]))
    print('12.4.1' if mode == 'wrong-major' else '11.26.0')
    if mode == 'version-failure': sys.exit(17)
'''


def check(mode, manual=False):
    with tempfile.TemporaryDirectory(prefix='pnpm-update-test-') as directory:
        root = Path(directory)
        managed_bin = root / 'home/.nvm/versions/node/v24.21.0/bin'
        for folder in (root / 'bin', root / 'nvm', root / 'pnpm/bin', managed_bin, root / 'project'):
            folder.mkdir(parents=True, exist_ok=True)
        for name in ('update.sh', 'pnpm-policy.zsh'):
            shutil.copy(REPO / name, root / name)
        (root / 'project/package.json').write_text('{"packageManager":"pnpm@12.4.1"}')
        for command, folder in [('brew', root / 'bin'), ('node', managed_bin), ('npm', managed_bin), ('pnpm', root / 'pnpm/bin')]:
            executable = folder / command
            executable.write_text(f'#!{sys.executable}\n' + MOCK)
            executable.chmod(0o755)
        if mode == 'external-path':
            shutil.move(root / 'pnpm/bin/pnpm', root / 'bin/pnpm')
            (root / 'pnpm/bin/pnpm').symlink_to(root / 'bin/pnpm')
        (root / 'nvm/nvm.sh').write_text('''nvm() {
  case "$1" in
    ls-remote) print v24.21.0 ;;
    which) print "$HOME/.nvm/versions/node/v24.21.0/bin/node" ;;
    use) export PATH="$HOME/.nvm/versions/node/v24.21.0/bin:$PATH" ;;
  esac
}
''')
        env = dict(os.environ, TEST_DIR=str(root), HOME=str(root / 'home'),
                   MODE=mode, SHELL_UPDATE_AUTO='0', PATH=f'{root / "bin"}:/usr/bin:/bin')
        master, slave = pty.openpty()
        try:
            command = ['zsh', '-c', 'source "$TEST_DIR/update.sh" manual'] if manual else ['zsh', str(root / 'update.sh'), '--auto']
            result = subprocess.run(command, env=env, cwd=root / 'project',
                                    stdin=slave if manual else subprocess.DEVNULL,
                                    text=True, capture_output=True, timeout=15)
        finally:
            os.close(slave)
            os.close(master)
        calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()]
        brew_calls = [args for name, args in calls if name == 'brew']
        assert ['upgrade'] not in brew_calls and ['upgrade', '--formula'] not in brew_calls, brew_calls
        assert not any(args[:1] == ['upgrade'] and any(a.startswith('pnpm') and a != 'pnpm@11' for a in args) for args in brew_calls), brew_calls
        failures = {'missing': 1, 'pinned': 1, 'upgrade-failure': 23, 'wrong-major': 1,
                    'external-path': 1, 'version-failure': 17, 'outdated-failure': 29}
        assert result.returncode == failures.get(mode, 0), (mode, result.returncode, result.stdout, result.stderr)
        if mode not in failures:
            assert brew_calls.count(['upgrade', 'pnpm@11']) == 1, brew_calls
            cwd, node_path = json.loads((root / 'pnpm-context').read_text())
            assert Path(cwd) != root / 'project' and not Path(cwd).exists(), cwd
            assert node_path == str(managed_bin / 'node'), node_path
            assert any(name == 'npm' and args == ['i', '-g', 'vite@latest'] for name, args in calls)
        else:
            assert not any(name == 'npm' and args[:1] == ['i'] for name, args in calls), calls
        if mode in ('missing', 'pinned'):
            assert ['upgrade', 'pnpm@11'] not in brew_calls
        if manual and mode != 'outdated-failure':
            assert ['upgrade', '--cask'] in brew_calls
            assert (['upgrade', '--formula', 'wget', 'local/tools/tool'] in brew_calls) == (mode == 'mixed')
        elif not manual:
            assert not any(args[:1] == ['outdated'] or args == ['upgrade', '--cask'] for args in brew_calls)
        print(f'PASS: {"manual" if manual else "auto"} {mode}')


if __name__ == '__main__':
    for scenario in ('success', 'missing', 'pinned', 'upgrade-failure', 'wrong-major', 'external-path', 'version-failure'):
        check(scenario)
    for scenario in ('mixed', 'only-pnpm', 'empty', 'outdated-failure'):
        check(scenario, manual=True)
