#!/usr/bin/env python3
"""Build a hidden native AX runner around an existing release App.framework.

No app compilation, live UI automation, SSH discovery, media decoding, or user
state access occurs. The native harness uses a version-checked test-only Flutter
semantics setter because this engine does not expose one in public headers.
"""
import json
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile


FIXTURE = r'''
import json, os, pathlib, sys, time
state = pathlib.Path(os.environ['FARSHORE_STATE'])
recent = [{'hostId':'fixture','path':f'/fixture/recent-{i}'} for i in range(1,6)]
def save_recents():
    (state / 'fixture-recents.json').write_text(json.dumps(recent))
save_recents()
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    with (state / 'calls.jsonl').open('a') as log:
        log.write(json.dumps({'method': method, 'params':request.get('params',{})}) + '\n')
    if method == 'hosts':
        time.sleep(0.7)
        result = {'hosts': [{'id':'fixture','alias':'AX fixture host','hostname':'invalid.fixture','user':'fixture','port':22}], 'favoriteHostIds':[], 'recentPaths':recent}
    elif method == 'status':
        result = {'mounts':[], 'activity':[],
                  'cache':{'bytesUsed':12*1024*1024,'budgetBytes':512*1024*1024},
                  'readBytes':None,'readMetric':'SFTP payload bytes, current filesystem sessions',
                  'streamBytesServed':0,'activePreviews':0,'mediaDiskCache':'off',
                  'readBufferBytesPerHandle':1024*1024}
    elif method == 'list':
        result = {'path':request.get('params',{}).get('path',''), 'entries':[], 'fresh':True}
    elif method == 'record_path_visit':
        params = request['params']
        item = {'hostId':params['hostId'], 'path':params['path']}
        recent = [item] + [entry for entry in recent if entry != item]
        recent = recent[:5]
        save_recents()
        result = {'recentPaths':recent}
    elif method == 'recent_paths':
        result = {'recentPaths':recent}
    else:
        result = {}
    print(json.dumps({'version':1,'id':request['id'],'ok':True,'result':result}), flush=True)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path, help='Existing release app/framework snapshot')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--palette', action='store_true', help='Exercise the slash path palette and fixture recents')
    mode.add_argument('--home', action='store_true', help='Exercise Home, guarded folder navigation, and workspace preservation')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    source = args.app.resolve() / 'Contents' / 'Frameworks'
    if not (source / 'App.framework').is_dir() or not (source / 'FlutterMacOS.framework').is_dir():
        raise SystemExit('An existing release app/framework snapshot is required.')
    with tempfile.TemporaryDirectory(prefix='accessibility-smoke-', dir=root / '.build') as scratch:
        scratch = Path(scratch)
        app = scratch / 'AccessibilitySmoke.app'
        contents = app / 'Contents'
        frameworks = contents / 'Frameworks'
        binary = contents / 'MacOS' / 'AccessibilitySmoke'
        binary.parent.mkdir(parents=True)
        frameworks.mkdir()
        for name in ('App.framework', 'FlutterMacOS.framework'):
            shutil.copytree(source / name, frameworks / name, symlinks=True)
        with (contents / 'Info.plist').open('wb') as output:
            plistlib.dump({'CFBundleIdentifier':'dev.farshore.tests.accessibility',
                          'CFBundleExecutable':'AccessibilitySmoke', 'CFBundleName':'AccessibilitySmoke',
                          'CFBundlePackageType':'APPL', 'NSPrincipalClass':'NSApplication',
                          'NSHighResolutionCapable':True}, output)
        fixture = scratch / 'fixture'
        (fixture / 'backend').mkdir(parents=True)
        (fixture / 'state').mkdir()
        (fixture / 'backend' / 'farshore_bridge.py').write_text(FIXTURE)
        cache = root / '.build' / 'native-ax-module-cache'
        cache.mkdir(exist_ok=True)
        sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'], text=True).strip()
        subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-O',
                        '-sdk',sdk,'-target',os.uname().machine+'-apple-macos12.0',
                        '-module-cache-path',str(cache),'-F',str(frameworks),
                        '-framework','AppKit','-framework','FlutterMacOS',
                        '-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks',
                        str(root/'tests/native/accessibility_smoke.swift'),'-o',str(binary)], check=True)
        subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(app)], check=True, capture_output=True)
        # Installed/development launcher overrides must never bypass the fake
        # bridge or redirect this isolated component into the user's state.
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith('FARSHORE_') and key not in {'RCLONE', 'PYTHONHOME', 'PYTHONPATH'}}
        environment.update(FARSHORE_ROOT=str(fixture), FARSHORE_STATE=str(fixture/'state'),
                           FARSHORE_CACHE=str(fixture/'cache'), FARSHORE_PYTHON=sys.executable,
                           FARSHORE_BRIDGE_SCRIPT=str(fixture/'backend/farshore_bridge.py'),
                           FARSHORE_AX_PALETTE='1' if args.palette else '0',
                           FARSHORE_AX_HOME='1' if args.home else '0')
        process = subprocess.Popen([str(binary)], env=environment, cwd=fixture,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=35)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
        finally:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        print(stdout, end='')
        ax_errors = [line for line in stderr.splitlines() if 'Failed to update ui::AXTree' in line]
        if process.returncode != 0 or ax_errors:
            # Repeated native AX failures can be emitted every frame. Keep one
            # copy of each diagnostic rather than burying the test result.
            lines = list(dict.fromkeys(stderr.splitlines()))
            print('\n'.join(lines[-12:]), file=sys.stderr)
        calls = fixture / 'state' / 'calls.jsonl'
        requests = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
        host_calls = sum(item['method'] == 'hosts' for item in requests)
        navigation_calls = sum(item['method'] == 'list' for item in requests)
        visit_calls = sum(item['method'] == 'record_path_visit' for item in requests)
        passed = process.returncode == 0 and host_calls >= 1 and not ax_errors
        if args.palette or args.home:
            recent_file = fixture / 'state' / 'fixture-recents.json'
            recent = json.loads(recent_file.read_text()) if recent_file.exists() else []
            passed = passed and navigation_calls >= 1 and visit_calls >= 1 and len(recent) == 5
            passed = passed and recent[0] == {'hostId':'fixture','path':'/fixture/recent-5'}
        print(json.dumps({'ok':passed,'nativeExitCode':process.returncode,'fixtureDiscoveryCalls':host_calls,
                          'fixtureNavigationCalls':navigation_calls,'fixtureRecordedVisits':visit_calls,
                          'paletteChecked':args.palette,'homeChecked':args.home,
                          'nativeAXErrors':len(ax_errors)}))
        raise SystemExit(0 if passed else 1)


if __name__ == '__main__':
    main()
