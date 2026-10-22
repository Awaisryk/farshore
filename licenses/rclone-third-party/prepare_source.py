#!/usr/bin/env python3
"""Prepare the offline corresponding-source/relink release asset for rclone."""
import concurrent.futures
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import zipfile
import tarfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
spec = importlib.util.spec_from_file_location('rclone_notices', HERE / 'collect.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)
STAGE = ROOT / '.build/rclone-corresponding-source'
NAME = 'Farshore-0.2.0-rclone-corresponding-source.zip'
URL = 'https://github.com/Awaisryk/farshore/releases/download/v0.2.0-beta.1/' + NAME
COMMIT = 'be8d6044eacb843b74d335db0c5fbe09222031fe'


def write_metadata(pair):
    module, version, checksum = pair
    base = f'https://proxy.golang.org/{collector.escaped(module)}/@v/{collector.escaped(version)}'
    target = STAGE / 'module-proxy' / collector.escaped(module) / '@v'
    target.mkdir(parents=True, exist_ok=True)
    mod = collector.fetch(base + '.mod', collector.sha((base + '.mod').encode()) + '.mod')
    content = mod.read_bytes()
    if checksum:
        summary = f'{collector.sha(content)}  go.mod\n'.encode()
        actual = 'h1:' + collector.base64.b64encode(hashlib.sha256(summary).digest()).decode()
        if actual != checksum:
            raise ValueError(f'go.mod checksum mismatch: {module}@{version}')
    shutil.copyfile(mod, target / (collector.escaped(version) + '.mod'))
    return module, version


def copy_module(item):
    module, version = item['module'], item['version']
    target = STAGE / 'module-proxy' / collector.escaped(module) / '@v'
    target.mkdir(parents=True, exist_ok=True)
    original = collector.CACHE / (collector.sha(item['sourceUrl'].encode()) + '.zip')
    if collector.sha(original.read_bytes()) != item['zipSha256']:
        raise ValueError('Cached module source changed: ' + module)
    shutil.copyfile(original, target / (collector.escaped(version) + '.zip'))
    info_url = item['sourceUrl'].removesuffix('.zip') + '.info'
    info = collector.fetch(info_url, collector.sha(info_url.encode()) + '.info')
    shutil.copyfile(info, target / (collector.escaped(version) + '.info'))


def prepare():
    inventory = json.loads((HERE / 'inventory.json').read_text())
    STAGE.mkdir(parents=True, exist_ok=True)
    source_url = f'https://codeload.github.com/rclone/rclone/zip/{COMMIT}'
    source = collector.fetch(source_url, 'rclone-source-be8d6044.zip')
    if collector.sha(source.read_bytes()) != '5d4d910057b3f78a360b9ebe7de21aba11d7e7ca4fab4bfaa4d3a8c131fcf4b7':
        raise ValueError('rclone source checksum mismatch')
    shutil.copyfile(source, STAGE / 'rclone-source.zip')
    shutil.copyfile(collector.CACHE / 'go1.26.9.src.tar.gz', STAGE / 'go1.26.9-source.tar.gz')
    sdk_url = 'https://codeload.github.com/macfuse/library/tar.gz/7a6cdd2b6e11071a706f4295aa931c65223ba953'
    sdk = collector.fetch(sdk_url, 'macfuse-library-7a6cdd2b6e11071a706f4295aa931c65223ba953.tar.gz')
    if collector.sha(sdk.read_bytes()) != '3d6c946d3775a7915f2c974b75612dc509e9f094864b9c1d729afd85c73936c8':
        raise ValueError('Unexpected macFUSE header source checksum')
    shutil.copyfile(sdk, STAGE / 'macfuse-headers-source.tar.gz')
    with zipfile.ZipFile(source) as archive:
        prefix = archive.namelist()[0]
        sums = archive.read(prefix + 'go.sum').decode().splitlines()
        shutil.copyfile(ROOT / 'licenses/rclone-MIT.txt', STAGE / 'RCLONE-MIT-LICENSE.txt')
    versions = {}
    for line in sums:
        module, version, checksum = line.split()
        key = module, version.removesuffix('/go.mod')
        if version.endswith('/go.mod'):
            versions[key] = checksum
        else:
            versions.setdefault(key, None)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        pairs = [(module, version, checksum) for (module, version), checksum in versions.items()]
        for index, _ in enumerate(pool.map(write_metadata, pairs), 1):
            if index % 50 == 0:
                print(f'Metadata {index}/{len(pairs)}', flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(copy_module, inventory['modules']))
    for module in {item['module'] for item in inventory['modules']}:
        target = STAGE / 'module-proxy' / collector.escaped(module) / '@v'
        versions = sorted(file.stem for file in target.glob('*.info'))
        (target / 'list').write_text('\n'.join(versions) + '\n')
    if (STAGE / 'notices').exists():
        shutil.rmtree(STAGE / 'notices')
    for item in inventory['modules']:
        for doc in item['documents']:
            target = STAGE / 'notices' / doc['file']
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(HERE / doc['file'], target)
    for name in ['LGPL-3.0.txt', 'GPL-3.0.txt', 'RELINKING.md', 'build-rclone.sh', 'verify-sources.py']:
        if not (HERE / name).exists():
            raise ValueError(f'Missing relink document: {name}')
        shutil.copyfile(HERE / name, STAGE / ('README.md' if name == 'RELINKING.md' else name))
    (STAGE / 'build-rclone.sh').chmod(0o755)
    inner = {
        'version': 1,
        'rcloneVersion': 'v1.75.2',
        'rcloneCommit': COMMIT,
        'rcloneSource': {'url': source_url, 'sha256': collector.sha(source.read_bytes())},
        'officialBinarySha256': inventory['binarySha256'],
        'goVersion': inventory['goVersion'],
        'fuseHeaderSource': {'url': sdk_url, 'sha256': collector.sha(sdk.read_bytes()), 'commit': '7a6cdd2b6e11071a706f4295aa931c65223ba953', 'note': 'Compatible official source-only headers for the verified relink. The original upstream binary does not identify its FUSE SDK revision.'},
        'goSource': inventory['goSource'],
        'goDarwinArm64Toolchain': {
            'url': 'https://go.dev/dl/go1.26.9.darwin-arm64.tar.gz',
            'sha256': 'f9bb7c0a02506c5d9bf0d1eb1f7ee6c7684f844ae49558308a0427b830e022cc',
        },
        'modules': [{key: item[key] for key in ['module', 'version', 'goSum', 'zipSha256', 'sourceUrl']} for item in inventory['modules']],
        'files': [],
    }
    for path in sorted(STAGE.rglob('*')):
        if path.is_file() and path.name not in ['source-manifest.json', '.validation.json'] and '.work' not in path.relative_to(STAGE).parts and 'output' not in path.relative_to(STAGE).parts:
            inner['files'].append({'path': str(path.relative_to(STAGE)), 'sha256': collector.sha(path.read_bytes()), 'bytes': path.stat().st_size})
    (STAGE / 'source-manifest.json').write_text(json.dumps(inner, indent=2) + '\n')
    print(f'Prepared {STAGE} with {len(inner["files"])} files', flush=True)


def package():
    validated = json.loads((STAGE / '.validation.json').read_text())
    if validated.get('baselinePassed') is not True or validated.get('modifiedLibraryPassed') is not True:
        raise ValueError('Both baseline and modified LGPL source rebuilds must pass before packaging')
    manifest = json.loads((STAGE / 'source-manifest.json').read_text())
    for item in manifest['files']:
        if collector.sha((STAGE / item['path']).read_bytes()) != item['sha256']:
            raise ValueError('Source inputs changed after preparation: ' + item['path'])
    manifest['relinkValidation'] = validated
    (STAGE / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    destination = ROOT / 'dist' / NAME
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_STORED) as archive:
        for item in manifest['files']:
            archive.write(STAGE / item['path'], 'Farshore-rclone-1.75.2-source/' + item['path'])
        archive.write(STAGE / 'source-manifest.json', 'Farshore-rclone-1.75.2-source/source-manifest.json')
    result = {'asset': NAME, 'sha256': collector.sha(destination.read_bytes()), 'bytes': destination.stat().st_size, 'url': URL,
              'relinkValidated': True, 'validation': 'Go1.26.9 darwin/arm64 cmount build, offline module proxy; modified LGPL source rebuild also tested.'}
    (HERE / 'source-manifest.json').write_text(json.dumps(result, indent=2) + '\n')
    inventory = json.loads((HERE / 'inventory.json').read_text())
    collector.finalize(inventory)
    print(json.dumps(result, indent=2), flush=True)


if __name__ == '__main__':
    import sys
    if '--package' in sys.argv:
        package()
    else:
        prepare()
