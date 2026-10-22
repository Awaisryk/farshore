#!/usr/bin/env python3
"""Collect original notices for the modules recorded in the shipped rclone.

Uses only Python's standard library. Downloads stay in .tools; only original
license/notice documents, build information and an audit inventory are shipped.
"""
import base64
import concurrent.futures
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
CACHE = ROOT / '.tools/rclone-license-downloads'
ARCHIVE = ROOT / '.tools/rclone.zip'
ARCHIVE_SHA = '610ab7d48615135dfc60b763858b11a426a0d3d1160c1bb76fb0ae6011b02edd'
DOCUMENT = re.compile(r'^(?:licen[cs]e|copying|notice|copyright|patents|authors|contributors|unlicense)(?:[._-].*)?$', re.I)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fetch(url, name):
    CACHE.mkdir(parents=True, exist_ok=True)
    target = CACHE / name
    if not target.exists():
        temporary = target.with_suffix(target.suffix + '.part')
        for attempt in range(3):
            try:
                request = urllib.request.Request(url, headers={'User-Agent': 'Farshore-License-Inventory/1'})
                with urllib.request.urlopen(request, timeout=60) as response, temporary.open('wb') as handle:
                    while True:
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        handle.write(chunk)
                temporary.replace(target)
                break
            except Exception:
                temporary.unlink(missing_ok=True)
                if attempt == 2:
                    raise
                time.sleep(1 + attempt)
    return target


def escaped(value):
    return ''.join('!' + char.lower() if char.isupper() else char for char in value)


def varstring(binary, position):
    length = shift = 0
    while True:
        byte = binary[position]
        position += 1
        length |= (byte & 127) << shift
        if byte < 128:
            break
        shift += 7
        if shift > 63:
            raise ValueError('Invalid Go build information')
    return binary[position:position + length], position + length


def document(path, data, relative):
    target = OUT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    return {'sourcePath': relative, 'file': str(path), 'sha256': sha(data), 'bytes': len(data)}


def module_notice(module):
    path, version, expected = module
    url = f'https://proxy.golang.org/{escaped(path)}/@v/{escaped(version)}.zip'
    result = {'module': path, 'version': version, 'goSum': expected, 'sourceUrl': url}
    try:
        downloaded = fetch(url, sha(url.encode()) + '.zip')
        with zipfile.ZipFile(downloaded) as archive:
            names = sorted(archive.namelist())
            summary = hashlib.sha256()
            for name in names:
                digest = hashlib.sha256()
                with archive.open(name) as handle:
                    while True:
                        chunk = handle.read(1024 * 1024)
                        if not chunk:
                            break
                        digest.update(chunk)
                summary.update(f'{digest.hexdigest()}  {name}\n'.encode())
            actual = 'h1:' + base64.b64encode(summary.digest()).decode()
            if actual != expected:
                raise ValueError(f'Module checksum mismatch: {actual}')
            result['verifiedGoSum'] = actual
            result['zipSha256'] = sha(downloaded.read_bytes())
            prefix = path + '@' + version + '/'
            documents = []
            for name in names:
                relative = name[len(prefix):] if name.startswith(prefix) else name
                parsed = PurePosixPath(relative)
                if '..' in parsed.parts or archive.getinfo(name).is_dir():
                    continue
                if not DOCUMENT.match(parsed.name):
                    continue
                if parsed.suffix.lower() in {'.go', '.c', '.h', '.cc', '.cpp', '.py', '.js'}:
                    continue
                content = archive.read(name)
                if len(content) > 4 * 1024 * 1024 or b'\x00' in content[:4096]:
                    continue
                documents.append(document(Path('modules') / (path + '@' + version) / relative, content, relative))
            result['documents'] = documents
            result['status'] = 'collected' if documents else 'missing-notice'
    except Exception as error:
        result['status'] = 'failed'
        result['error'] = str(error)
    return result


def finalize(inventory):
    unresolved = []
    source_modules = []
    review = []
    for item in inventory['modules']:
        documents = item.get('documents', [])
        primary = [entry for entry in documents if re.match(r'^(?:licen[cs]e|copying|copyright|unlicense)', PurePosixPath(entry['sourcePath']).name, re.I)]
        if item['status'] != 'collected' or not primary:
            unresolved.append(item['module'])
            continue
        headers = [(entry, (OUT / entry['file']).read_text(errors='replace')[:1600].lower()) for entry in primary]
        is_mpl = any('mozilla public license' in header for _, header in headers)
        is_sddl = item['module'] == 'github.com/cloudsoda/sddl'
        if is_mpl or is_sddl:
            source_file = Path('sources') / (item['module'].replace('/', '--') + '@' + item['version'] + '.zip')
            target = OUT / source_file
            target.parent.mkdir(parents=True, exist_ok=True)
            original = CACHE / (sha(item['sourceUrl'].encode()) + '.zip')
            shutil.copyfile(original, target)
            item['sourceArchive'] = {'file': str(source_file), 'sha256': sha(target.read_bytes()), 'license': 'MPL-2.0' if is_mpl else 'LGPL-3.0'}
            if is_mpl:
                source_modules.append(item['module'])
        for entry, header in headers:
            if 'mozilla public license' not in header and re.search(r'gnu (?:lesser |affero )?general public license|common development and distribution license|eclipse public license', header):
                review.append({'module': item['module'], 'document': entry['file']})
    inventory['unresolvedModules'] = unresolved
    inventory['includedSourceModules'] = source_modules
    provision_file = OUT / 'source-manifest.json'
    provision = json.loads(provision_file.read_text()) if provision_file.exists() else {}
    artifact = ROOT / 'dist' / provision.get('asset', 'missing-source-asset')
    source_provided = provision.get('relinkValidated') is True and artifact.is_file() and sha(artifact.read_bytes()) == provision.get('sha256')
    if source_provided:
        inventory['sourceProvision'] = provision
        review = [item for item in review if item['module'] != 'github.com/cloudsoda/sddl']
    inventory['additionalTermsReview'] = review
    inventory['additionalDocuments'] = [
        {'file': 'GPL-3.0.txt', 'sourceUrl': 'https://raw.githubusercontent.com/spdx/license-list-data/v3.27.0/text/GPL-3.0-only.txt',
         'sha256': sha((OUT / 'GPL-3.0.txt').read_bytes())},
        {'file': 'LGPL-3.0.txt', 'sourceUrl': 'https://proxy.golang.org/github.com/cloudsoda/sddl/@v/v0.0.0-20250224235906-926454e91efc.zip',
         'sha256': sha((OUT / 'LGPL-3.0.txt').read_bytes())},
    ]
    inventory['relinkHeaderSource'] = {
        'url': 'https://codeload.github.com/macfuse/library/tar.gz/7a6cdd2b6e11071a706f4295aa931c65223ba953',
        'sha256': '3d6c946d3775a7915f2c974b75612dc509e9f094864b9c1d729afd85c73936c8',
        'note': 'Compatible official source-only headers supplied in the relink asset; original upstream SDK revision is not recorded in the binary.',
    }
    inventory['complete'] = not unresolved and not review and source_provided and bool(inventory.get('goSource'))
    (OUT / 'inventory.json').write_text(json.dumps(inventory, indent=2) + '\n')
    source_lines = [
        'RCLONE DEPENDENCY SOURCE AVAILABILITY',
        '',
        'This distribution includes an unchanged official rclone v1.75.2 executable.',
        'rclone contains github.com/cloudsoda/sddl under the GNU Lesser General Public',
        'License version 3. Its use is covered by that license. Original LGPL3 and GPL3',
        'texts accompany these notices. Farshore imposes no restriction on reverse',
        'engineering to debug modifications to that library.',
        '',
        'The exact library source, corresponding rclone/application source, all242',
        'compiled dependency sources, offline build/relink scripts and installation',
        'instructions are provided together as a matching release asset:',
        'https://github.com/Awaisryk/farshore/releases/download/v0.2.0-beta.1/Farshore-0.2.0-rclone-corresponding-source.zip',
        'See RELINKING.md and source-manifest.json for checksums and rebuilding details.',
        '',
        'The following dependency source archives are also supplied inside the app.',
        'The MPL-2.0 components are supplied without modifications.',
        'The MPL source remains under MPL-2.0; the sddl source remains under LGPL3.',
        'See each module\'s original LICENSE document and the enclosed license texts.',
        '',
        'Inside Farshore.app, these archives are in:',
        'Contents/Resources/Runtime/licenses/rclone-third-party/sources/',
        '',
        'Exact source downloads are also available at the URLs below. SHA-256 and Go h1',
        'checksums for every archive are recorded in inventory.json.',
        '',
    ]
    for item in inventory['modules']:
        if 'sourceArchive' in item:
            source_lines += [item['module'] + ' ' + item['version'] + ' · ' + item['sourceArchive']['license'], 'Bundled: ' + item['sourceArchive']['file'], 'Upstream: ' + item['sourceUrl'], '']
    (OUT / 'SOURCE_AVAILABILITY.txt').write_text('\n'.join(source_lines) + '\n')
    return inventory['complete']


def main():
    if not ARCHIVE.exists():
        downloaded = fetch('https://downloads.rclone.org/v1.75.2/rclone-v1.75.2-osx-arm64.zip', 'rclone-official-distribution.zip')
        ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(downloaded, ARCHIVE)
    archive_bytes = ARCHIVE.read_bytes()
    if sha(archive_bytes) != ARCHIVE_SHA:
        raise ValueError('Unexpected rclone distribution archive')
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
        executable = archive.read(next(name for name in archive.namelist() if name.endswith('/rclone')))
    offset = executable.index(b'\xff Go buildinf:')
    if executable[offset + 15] & 2 == 0:
        raise ValueError('Expected inline Go build information')
    go_version, offset = varstring(executable, offset + 32)
    raw, _ = varstring(executable, offset)
    build_info = raw[16:-16].decode()
    if any(line.startswith('=>') for line in build_info.splitlines()):
        raise ValueError('Replacement module needs explicit provenance review')
    modules = [line.split('\t')[1:] for line in build_info.splitlines() if line.startswith('dep\t')]
    (OUT / 'BUILDINFO.txt').write_text(build_info)
    inventory = {
        'version': 1,
        'rcloneVersion': 'v1.75.2',
        'archiveUrl': 'https://downloads.rclone.org/v1.75.2/rclone-v1.75.2-osx-arm64.zip',
        'archiveSha256': ARCHIVE_SHA,
        'binarySha256': sha(executable),
        'goVersion': go_version.decode(),
        'method': 'All dependency modules embedded in the shipped binary; original notice files collected recursively from module zips verified against embedded Go h1 checksums. Module-level collection is conservative and may include notices for source packages not linked on darwin/arm64.',
    }
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = []
        for number, result in enumerate(pool.map(module_notice, modules), 1):
            results.append(result)
            print(f'{number}/{len(modules)} {result["status"]} {result["module"]}', flush=True)
    inventory['modules'] = results
    inventory['moduleCount'] = len(results)
    inventory['unresolvedModules'] = [item['module'] for item in results if item['status'] != 'collected']
    version = go_version.decode()
    metadata_url = 'https://go.dev/dl/?mode=json&include=all'
    metadata = json.loads(fetch(metadata_url, 'go-downloads.json').read_text())
    release = next(item for item in metadata if item['version'] == version)
    source = next(item for item in release['files'] if item['kind'] == 'source')
    source_url = 'https://go.dev/dl/' + source['filename']
    downloaded = fetch(source_url, source['filename'])
    source_bytes = downloaded.read_bytes()
    if sha(source_bytes) != source['sha256']:
        raise ValueError('Go source checksum mismatch')
    documents = []
    with tarfile.open(fileobj=io.BytesIO(source_bytes), mode='r:gz') as archive:
        for item in archive.getmembers():
            if not item.isfile() or not DOCUMENT.match(PurePosixPath(item.name).name):
                continue
            relative = item.name.removeprefix('go/')
            content = archive.extractfile(item).read()
            documents.append(document(Path('go-runtime') / relative, content, relative))
    inventory['goSource'] = {'url': source_url, 'sha256': source['sha256'], 'documents': documents, 'metadataUrl': metadata_url}
    complete = finalize(inventory)
    print(json.dumps({'modules': len(results), 'unresolved': inventory['unresolvedModules'], 'goDocuments': len(documents)}), flush=True)
    if inventory['unresolvedModules']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
