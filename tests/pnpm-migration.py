#!/usr/bin/env python3
"""Native-link migration checks; all homes, formulae and commands are isolated mocks."""
import os
import fcntl
from pathlib import Path
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
BREW = r'''#!/usr/bin/python3
import os, pathlib, signal, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
prefix = root / 'brew prefix'
args = sys.argv[1:]
with (root / 'brew-calls').open('a') as log: log.write(' '.join(args) + '\n')

def installed(name):
    return (prefix / 'opt' / name / '.installed').is_file()

if args == ['--prefix']:
    print(prefix)
elif args[:2] == ['--prefix', '--installed']:
    if not installed(args[2]): sys.exit(1)
    print(prefix / 'opt' / args[2])
elif args == ['list', '--versions']:
    for name in ('pnpm', 'pnpm@11'):
        if installed(name): print(name, '12.4.1' if name == 'pnpm' else '11.26.0')
elif args == ['list', '--pinned']:
    pass
elif args in (['install', 'pnpm@11'], ['install', '--skip-link', 'pnpm@11']):
    if os.environ.get('FAIL_INSTALL'): sys.exit(23)
    target = prefix / 'Cellar/pnpm@11/11.26.0'
    (target / 'bin').mkdir(parents=True, exist_ok=True)
    (target / '.installed').touch()
    for name in ('pnpm', 'pnpx'):
        binary = target / 'bin' / name
        binary.write_bytes((root / 'pnpm-template').read_bytes())
        binary.chmod(0o755)
    (prefix / 'opt/pnpm@11').symlink_to(target)
    if '--skip-link' not in args:
        for name in ('pnpm', 'pnpx'):
            binary = prefix / 'bin' / name
            if not binary.exists(): binary.symlink_to(target / 'bin' / name)
    if os.environ.get('ESCAPE_TARGET'):
        binary = target / 'bin/pnpm'
        binary.unlink()
        binary.symlink_to(root / 'outside-pnpm')
    if os.environ.get('PARTIAL_INSTALL'): sys.exit(24)
elif args[0] == 'unlink':
    target = (prefix / 'opt' / args[1]).resolve()
    for name in ('pnpm', 'pnpx'):
        binary = prefix / 'bin' / name
        if binary.is_symlink() and target in binary.resolve().parents: binary.unlink()
elif args[:2] == ['link', '--force']:
    if '--dry-run' in args: sys.exit(0)
    name = args[-1]
    if name == 'pnpm' and os.environ.get('FAIL_ROLLBACK'): sys.exit(33)
    for index, binary_name in enumerate(('pnpm', 'pnpx')):
        binary = prefix / 'bin' / binary_name
        target = prefix / 'opt' / name / 'bin' / binary_name
        if name == 'pnpm@11' and binary_name == 'pnpm' and os.environ.get('CROSSWIRE_LINK'):
            target = prefix / 'opt' / name / 'bin/pnpx'
        if binary.exists() or binary.is_symlink(): sys.exit(17)
        binary.symlink_to(target)
        if name == 'pnpm@11' and index == 0:
            if os.environ.get('FAIL_LINK'): sys.exit(31)
            if os.environ.get('SIGNAL_LINK'):
                os.kill(os.getppid(), getattr(signal, 'SIG' + os.environ['SIGNAL_LINK']))
    if os.environ.get('EDIT_RC') and name == 'pnpm@11':
        with pathlib.Path(os.environ['RC_TARGET']).open('a') as out: out.write('# concurrent edit\n')
else:
    sys.exit('unexpected brew call: ' + repr(args))
'''
PNPM = r'''#!/bin/zsh
print "$0 $*" >> "$TEST_ROOT/pnpm-calls"
if [[ "$1" == --version ]]; then
  [[ ! -f package.json ]] || exit 98
  print "${TARGET_VERSION:-11.26.0}"
else
  print "target:$*"
fi
'''
LEGACY = r'''# >>> shell-update pnpm >>>
# bin: $RAW_BIN
if (( ${+aliases[pnpm]} || ${+aliases[pnpx]} )) ||
   { (( ${+functions[pnpm]} )) && [[ "${functions[pnpm]}" != "${_shell_update_pnpm_function-}" ]]; } ||
   { (( ${+functions[pnpx]} )) && [[ "${functions[pnpx]}" != "${_shell_update_pnpx_function-}" ]]; }; then
  print -u2 '[shell-update] 기존 pnpm/pnpx alias 또는 함수가 있어 전환을 건너뜁니다.'
else
  export PATH=$BIN:"$PATH"
  function pnpm { PATH=$BIN:"$PATH" command $BIN/pnpm "$@"; }
  function pnpx { PATH=$BIN:"$PATH" command $BIN/pnpx "$@"; }
  typeset -g _shell_update_pnpm_function="${functions[pnpm]}"
  typeset -g _shell_update_pnpx_function="${functions[pnpx]}"
fi
# <<< shell-update pnpm <<<
'''


def setup(root):
    repo = root / 'repo with spaces'
    repo.mkdir()
    (repo / 'package.json').write_text('{"packageManager":"pnpm@12.0.0"}')
    for name in ('migrate-pnpm.zsh', 'pnpm-policy.zsh'):
        shutil.copy2(REPO / name, repo / name)
    home = root / 'home'
    zdir = root / 'zsh config'
    fake = root / 'bin'
    prefix = root / 'brew prefix'
    for directory in (home, zdir, fake, prefix / 'bin', prefix / 'opt'):
        directory.mkdir(parents=True, exist_ok=True)
    for version in ('v24.18.0', 'v24.21.0'):
        directory = home / '.nvm/versions/node' / version / 'bin'
        directory.mkdir(parents=True)
        (directory / 'node').write_text('#!/bin/zsh\nprint v24.21.0\n')
        (directory / 'node').chmod(0o755)
    old = prefix / 'Cellar/pnpm/12.4.1'
    (old / 'bin').mkdir(parents=True)
    (old / '.installed').touch()
    (prefix / 'opt/pnpm').symlink_to(old)
    for name in ('pnpm', 'pnpx'):
        (old / 'bin' / name).write_text('#!/bin/zsh\nprint OLD_EXECUTED >> "$TEST_ROOT/old-executed"\nprint 12.4.1\n')
        (old / 'bin' / name).chmod(0o755)
        (prefix / 'bin' / name).symlink_to(old / 'bin' / name)
    (fake / 'brew').write_text(BREW)
    (fake / 'brew').chmod(0o755)
    (root / 'pnpm-template').write_text(PNPM)
    env = os.environ | {'HOME': str(home), 'ZDOTDIR': str(zdir), 'NVM_DIR': str(home / '.nvm'),
                        'PATH': f'{fake}:{home}/.nvm/versions/node/v24.21.0/bin:{prefix}/bin:/usr/bin:/bin',
                        'TEST_ROOT': str(root), 'HOMEBREW_NO_AUTO_UPDATE': '1'}
    return repo, zdir / '.zshrc', env


def run(repo, env, *args):
    return subprocess.run(['/bin/zsh', str(repo / 'migrate-pnpm.zsh'), *args], env=env, cwd=repo,
                          text=True, capture_output=True, timeout=10)


def legacy(root):
    raw = str(root / 'brew prefix/opt/pnpm@11/bin')
    return LEGACY.replace('$RAW_BIN', raw).replace('$BIN', raw.replace(' ', r'\ '))


def owner(root):
    return (root / 'brew prefix/bin/pnpm').resolve()


def main():
    with tempfile.TemporaryDirectory(prefix='pnpm-native-test-') as directory:
        root = Path(directory)
        repo, rc, env = setup(root)
        original = '# before\n' + legacy(root) + '# after\n'
        target = root / 'dotfiles/zshrc'
        target.parent.mkdir()
        target.write_text(original)
        rc.symlink_to(target)
        result = run(repo, env)
        assert result.returncode == 0, result.stderr
        assert target.read_text() == original and not (root / 'old-executed').exists()
        assert not list(target.parent.glob('*.shell-update-pnpm.*'))
        assert not (repo / 'logs').exists()
        assert 'install ' not in (root / 'brew-calls').read_text()
        result = run(repo, env, '--apply')
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert '/pnpm@11/' in str(owner(root))
        assert rc.is_symlink() and target.read_text() == '# before\n# after\n'
        backups = list(target.parent.glob('*.shell-update-pnpm.*'))
        assert len(backups) == 1 and backups[0].read_text() == original
        assert (root / 'brew prefix/Cellar/pnpm/12.4.1/bin/pnpm').exists()
        before = (root / 'brew-calls').read_text()
        result = run(repo, env, '--apply')
        assert result.returncode == 0, result.stderr
        extra = (root / 'brew-calls').read_text()[len(before):]
        assert not any(command in extra for command in ('install ', 'link ', 'unlink '))
        assert list(target.parent.glob('*.shell-update-pnpm.*')) == backups
        for version in ('v24.18.0', 'v24.21.0'):
            shell = subprocess.run(['/bin/zsh', '-fc', '''export PATH="$NVM_DIR/versions/node/$1/bin:$PATH"
command pnpm --version
/bin/zsh -fc 'command pnpm --version'
command pnpx hello
''', 'zsh', version], env=env, cwd=root, capture_output=True, text=True, timeout=10)
            assert shell.returncode == 0 and shell.stdout.count('11.26.0') == 2, shell.stderr
        assert not (root / 'old-executed').exists()
        print('PASS: native links, legacy removal, symlink backup, old PATH, two nvm versions, repeat apply')

    for failure, code in [('FAIL_INSTALL', 23), ('FAIL_LINK', 31), ('SIGNAL_LINK', 143), ('EDIT_RC', 1), ('CROSSWIRE_LINK', 1)]:
        with tempfile.TemporaryDirectory(prefix='pnpm-native-test-') as directory:
            root = Path(directory)
            repo, rc, env = setup(root)
            original = '# before\n' + legacy(root) + '# after\n'
            rc.write_text(original)
            value = 'TERM' if failure == 'SIGNAL_LINK' else '1'
            result = run(repo, env | {failure: value, 'RC_TARGET': str(rc)}, '--apply')
            assert result.returncode == code, (failure, result.returncode, result.stdout, result.stderr)
            for name in ('pnpm', 'pnpx'):
                assert '/pnpm/12.4.1/' in str((root / 'brew prefix/bin' / name).resolve())
            assert rc.read_text() == original + ('# concurrent edit\n' if failure == 'EDIT_RC' else '')
        print('PASS:', failure, 'preserves original links and config')

    for conflict in ('nvm', 'path', 'unknown-native', 'crosswired', 'edited-block', 'alias', 'missing-path'):
        with tempfile.TemporaryDirectory(prefix='pnpm-native-test-') as directory:
            root = Path(directory)
            repo, rc, env = setup(root)
            rc.write_text('# user config\n')
            if conflict == 'nvm':
                (root / 'home/.nvm/versions/node/v24.18.0/bin/pnpm').symlink_to(root / 'brew prefix/bin/pnpm')
            elif conflict == 'path':
                env['PATH'] = str(root / 'brew prefix/opt/pnpm/bin') + ':' + env['PATH']
            elif conflict == 'unknown-native':
                binary = root / 'brew prefix/bin/pnpm'
                binary.unlink()
                binary.write_text('unowned file')
            elif conflict == 'crosswired':
                binary = root / 'brew prefix/bin/pnpm'
                binary.unlink()
                binary.symlink_to(root / 'brew prefix/opt/pnpm/bin/pnpx')
            elif conflict == 'edited-block':
                rc.write_text(legacy(root).replace('else\n', 'else # edited\n'))
            elif conflict == 'alias':
                rc.write_text("alias pnpm='corepack pnpm'\n")
            else:
                env['PATH'] = env['PATH'].replace(str(root / 'brew prefix/bin') + ':', '')
            original = rc.read_text()
            result = run(repo, env, '--apply')
            assert result.returncode != 0, conflict
            assert rc.read_text() == original
            calls = (root / 'brew-calls').read_text()
            assert not any(command in calls for command in ('install ', 'link ', 'unlink ')), calls
        print('PASS: preflight blocks', conflict)

    with tempfile.TemporaryDirectory(prefix='pnpm-native-test-') as directory:
        root = Path(directory)
        repo, rc, env = setup(root)
        result = run(repo, env | {'FAIL_LINK': '1', 'FAIL_ROLLBACK': '1'}, '--apply')
        assert result.returncode != 0 and '부분 적용' in result.stderr
        assert not rc.exists()
        print('PASS: rollback failure is reported as partial application')

    with tempfile.TemporaryDirectory(prefix='pnpm-native-test-') as directory:
        root = Path(directory)
        repo, rc, env = setup(root)
        result = run(repo, env, '--apply')
        assert result.returncode == 0 and not rc.exists(), result.stderr
        env['PATH'] = str(root / 'brew prefix/opt/pnpm@11/bin') + ':' + env['PATH']
        result = run(repo, env, '--apply')
        assert result.returncode == 0, result.stderr
        print('PASS: no new rc and approved opt path remains valid')

    with tempfile.TemporaryDirectory(prefix='pnpm-native-test-') as directory:
        root = Path(directory)
        repo, rc, env = setup(root)
        log_dir = repo / 'logs'
        log_dir.mkdir()
        with (log_dir / '.update.flock').open('w') as lock:
            fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            assert run(repo, env).returncode == 0
            result = run(repo, env, '--apply')
            assert result.returncode == 75, (result.returncode, result.stderr)
            assert '/pnpm/12.4.1/' in str(owner(root))
        legacy_lock = log_dir / '.update.lock'
        legacy_lock.mkdir()
        (legacy_lock / 'pid').write_text(str(os.getpid()))
        result = run(repo, env, '--apply')
        assert result.returncode == 75, result.stderr
        (legacy_lock / 'pid').unlink()
        result = run(repo, env, '--apply')
        assert result.returncode == 0, result.stderr
        assert not rc.exists()
        print('PASS: shared updater lock, legacy PID protection, and release')

    for failure, value in (('TARGET_VERSION', '12.0.0'), ('ESCAPE_TARGET', '1'), ('PARTIAL_INSTALL', '1')):
        with tempfile.TemporaryDirectory(prefix='pnpm-native-test-') as directory:
            root = Path(directory)
            repo, rc, env = setup(root)
            prefix = root / 'brew prefix'
            for name in ('pnpm', 'pnpx'):
                (prefix / 'bin' / name).unlink()
            (prefix / 'opt/pnpm').unlink()
            shutil.rmtree(prefix / 'Cellar/pnpm')
            (root / 'outside-pnpm').write_text(PNPM)
            (root / 'outside-pnpm').chmod(0o755)
            rc.write_text('# untouched fresh-Mac config\n')
            result = run(repo, env | {failure: value}, '--apply')
            assert result.returncode != 0, (failure, result.stdout, result.stderr)
            for name in ('pnpm', 'pnpx'):
                assert not (prefix / 'bin' / name).exists()
                assert not (prefix / 'bin' / name).is_symlink()
            assert rc.read_text() == '# untouched fresh-Mac config\n'
            assert not list(rc.parent.glob('*.shell-update-pnpm.*'))
            assert 'install --skip-link pnpm@11' in (root / 'brew-calls').read_text()
            if failure != 'TARGET_VERSION':
                assert not (root / 'pnpm-calls').exists()
        print('PASS: fresh Mac', failure, 'leaves no native links or config changes')


if __name__ == '__main__':
    main()
