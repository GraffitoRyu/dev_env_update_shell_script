#!/usr/bin/env python3
"""Optional offline contract check using explicitly supplied, existing pnpm distributions.

python3 tests/pnpm-resolution.py --entry /path/to/pnpm/dist/pnpm.mjs \
  --target-gvs /path/to/store/v11/links/@/pnpm/VERSION/HASH \
  --env-lockfile /path/to/pnpm-lock.yaml \
  --metadata-dir /path/to/cached/registry.npmjs.org
No inputs: SKIP. Existing packages are copied; only temporary caches/config are written.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile

NETWORK_GUARD = r'''
const fs = require('node:fs');
const blocked = () => {
  fs.appendFileSync(process.env.PNPM_TEST_NETWORK_LOG, 'network attempted\n');
  throw new Error('Network is disabled by pnpm-resolution.py');
};
require('node:net').Socket.prototype.connect = blocked;
require('node:dgram').Socket.prototype.send = blocked;
for (const name of ['node:http', 'node:https']) {
  const module = require(name);
  module.request = blocked;
  module.get = blocked;
}
require('node:dns').lookup = blocked;
globalThis.fetch = blocked;
require('node:module').syncBuiltinESMExports();
'''


def package_root(entry):
    for parent in entry.parents:
        manifest = parent / 'package.json'
        if manifest.is_file():
            data = json.loads(manifest.read_text())
            if data.get('name') == 'pnpm':
                return parent, data
    raise ValueError(f'No pnpm package.json above {entry}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--entry', default=os.environ.get('REAL_PNPM_ENTRY'))
    parser.add_argument('--target-gvs', default=os.environ.get('REAL_PNPM_TARGET_GVS'))
    parser.add_argument('--env-lockfile', default=os.environ.get('REAL_PNPM_ENV_LOCKFILE'))
    parser.add_argument('--metadata-dir', default=os.environ.get('REAL_PNPM_METADATA_DIR'),
                        help='Optional existing registry.npmjs.org metadata directory for legacy exact switching.')
    args = parser.parse_args()
    if not args.entry:
        print('SKIP: provide --entry or REAL_PNPM_ENTRY; no real pnpm engine was tested.')
        return
    entry = Path(args.entry).expanduser().resolve(strict=True)
    source, manifest = package_root(entry)
    version = manifest['version']
    if version.split('.')[0] != '11':
        parser.error('This contract check requires a real pnpm 11 entry.')
    if bool(args.target_gvs) != bool(args.env_lockfile):
        parser.error('--target-gvs and --env-lockfile must be supplied together.')
    node = shutil.which('node')
    if not node:
        parser.error('An existing compatible Node.js executable is required.')
    node = str(Path(node).resolve())
    with tempfile.TemporaryDirectory(prefix='pnpm-resolution-') as directory:
        root = Path(directory).resolve()
        copied = root / 'engine'
        shutil.copytree(source, copied)
        copied_entry = copied / entry.relative_to(source)
        guard = root / 'block-network.cjs'
        guard.write_text(NETWORK_GUARD)
        env = {'PATH': f'{Path(node).parent}:/usr/bin:/bin', 'CI': '1',
               'NODE_OPTIONS': f'--require {json.dumps(str(guard))}',
               'PNPM_TEST_NETWORK_LOG': str(root / 'network.log'),
               'npm_config_offline': 'true', 'PNPM_CONFIG_OFFLINE': 'true',
               'npm_config_update_notifier': 'false', 'PNPM_CONFIG_UPDATE_NOTIFIER': 'false'}
        for variable, name in [('HOME', 'home'), ('XDG_CONFIG_HOME', 'config'),
                               ('XDG_CACHE_HOME', 'cache'), ('XDG_DATA_HOME', 'data'),
                               ('XDG_STATE_HOME', 'state'), ('PNPM_HOME', 'pnpm-home'),
                               ('TMPDIR', 'tmp')]:
            folder = root / name
            folder.mkdir()
            env[variable] = str(folder)
        store = root / 'store'
        env['PNPM_CONFIG_STORE_DIR'] = env['npm_config_store_dir'] = str(store)
        env['PNPM_CONFIG_CACHE_DIR'] = env['npm_config_cache_dir'] = str(root / 'cache/pnpm')

        def check(name, package, expected, env_lock=None, nested=False):
            project = root / name
            project.mkdir()
            if package is not None:
                (project / 'package.json').write_text(json.dumps(package))
            if env_lock:
                (project / 'pnpm-lock.yaml').write_text(env_lock)
            before = {p.name: p.read_bytes() for p in project.iterdir() if p.is_file()}
            cwd = project
            if nested:
                cwd = project / 'src/deep'
                cwd.mkdir(parents=True)
            result = subprocess.run([node, str(copied_entry), '--version'], cwd=cwd, env=env,
                                    text=True, capture_output=True, timeout=30)
            assert result.returncode == 0, (name, result.returncode, result.stdout, result.stderr)
            assert expected in result.stdout.splitlines(), (name, expected, result.stdout, result.stderr)
            assert not (root / 'network.log').exists(), name
            for filename, content in before.items():
                assert (project / filename).read_bytes() == content, (name, 'fixture was rewritten', filename)
            print(f'PASS: real pnpm {version}: {name} -> {expected}')

        check('no-project-fallback', None, version)
        check('legacy-exact-current', {'packageManager': f'pnpm@{version}'}, version)
        check('legacy-exact-current-subdirectory', {'packageManager': f'pnpm@{version}'}, version, nested=True)
        if not args.target_gvs:
            print('SKIP: cross-version selection needs --target-gvs and --env-lockfile; fallback/exact-current only.')
            return
        target = Path(args.target_gvs).expanduser().resolve(strict=True)
        target_manifest = json.loads((target / 'node_modules/pnpm/package.json').read_text())
        target_version = target_manifest['version']
        assert target_manifest['name'] == 'pnpm' and target_version != version
        destination = store / 'v11/links/@/pnpm' / target_version / target.name
        shutil.copytree(target, destination)
        # Recreate the launcher: copied GVS bin scripts may contain source-cache paths.
        bin_dir = destination / 'bin'
        if bin_dir.exists():
            shutil.rmtree(bin_dir)
        bin_dir.mkdir()
        target_bin = target_manifest['bin']['pnpm']
        launcher = bin_dir / 'pnpm'
        launcher.write_text('#!/bin/sh\nexec ' + shlex.quote(node) + ' ' +
                            shlex.quote(str(destination / 'node_modules/pnpm' / target_bin)) + ' "$@"\n')
        launcher.chmod(0o755)
        lock = Path(args.env_lockfile).expanduser().read_text().split('\n---\n')[0] + "\n---\nlockfileVersion: '9.0'\nimporters:\n  .: {}\n"
        declaration = {'devEngines': {'packageManager': {'name': 'pnpm', 'version': target_version}}}
        check('devengines-cached-target', declaration, target_version, lock)
        check('devengines-precedence', dict(declaration, packageManager=f'pnpm@{version}'), target_version, lock)
        check('devengines-subdirectory', declaration, target_version, lock, nested=True)
        if args.metadata_dir:
            metadata = Path(args.metadata_dir).expanduser().resolve(strict=True)
            metadata_copy = root / 'cache/pnpm/v11/metadata/registry.npmjs.org'
            metadata_copy.mkdir(parents=True, exist_ok=True)
            metadata_files = [metadata / 'pnpm.jsonl', *metadata.glob('@pnpm/*.jsonl')]
            for metadata_file in metadata_files:
                output = metadata_copy / metadata_file.relative_to(metadata)
                output.parent.mkdir(parents=True, exist_ok=True)
                raw = metadata_file.read_bytes()
                # pnpm 12's indexed mirror needs conversion for this pnpm 11 fixture.
                if raw.startswith(b'pacquet-meta-v1 '):
                    header, body = raw.split(b'\n', 1)
                    header_size, index_size = map(int, header.split()[1:])
                    headers = json.loads(body[:header_size])
                    index = json.loads(body[header_size:header_size + index_size])
                    records = body[header_size + index_size:]
                    index['versions'] = {v: json.loads(records[start:start + size])
                                         for v, start, size in index['versions']}
                    index['dist-tags'] = index.pop('distTags')
                    output.write_text(json.dumps(headers) + '\n' + json.dumps(index))
                else:
                    output.write_bytes(raw)
            check('legacy-exact-cross-version', {'packageManager': f'pnpm@{target_version}'}, target_version)
            check('legacy-exact-cross-version-subdirectory',
                  {'packageManager': f'pnpm@{target_version}'}, target_version, nested=True)
        else:
            print('SKIP: legacy exact cross-version requires --metadata-dir; devEngines switching was tested.')
        check('fallback-after-project-selection', None, version)
        print('SCOPE: real copied distributions and temporary caches; no downloads or original-cache writes.')


if __name__ == '__main__':
    main()
