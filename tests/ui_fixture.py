"""Disposable, separately identified app for manual GUI checks; Enter cleans up its Spaces."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

from direct_conflict_cases import prepare_proxy_settings
from fixtures import origin, proxy

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--conflict', action='store_true')
    args = parser.parse_args()
    out = ROOT / '.artifacts' / time.strftime('ui-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    app = out / 'Agent WebKit UI Test.app'
    shutil.copytree(ROOT / '.build/Agent WebKit.app', app)
    info = app / 'Contents/Info.plist'
    plist = plistlib.loads(info.read_bytes())
    plist.update(CFBundleIdentifier='local.agent-webkit.ui-test', CFBundleName='Agent WebKit UI Test',
                 CFBundleDisplayName='Agent WebKit UI Test')
    info.write_bytes(plistlib.dumps(plist))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    settings, injection = prepare_proxy_settings(out)
    # Unix socket paths are limited to 104 bytes on macOS.
    import tempfile
    state = Path(tempfile.mkdtemp(prefix='aw-ui-'))
    env = dict(os.environ, BROWSER_DATA_DIR=str(state), BROWSER_SOCKET=str(state / 'browser.sock'))
    binary = ROOT / '.build/debug/awb'
    site, _ = origin()
    relay, _ = proxy()
    proxy_url = f'http://127.0.0.1:{relay.server_address[1]}'
    url = f'http://127.0.0.1:{site.server_address[1]}/popups'
    daemon = None
    log = (out / 'daemon.log').open('w')

    def cli(*arguments):
        p = subprocess.run([str(binary), *arguments], env=env, capture_output=True, text=True, timeout=20)
        result = json.loads(p.stdout)
        assert result['ok'], result
        return result['result']

    def start():
        nonlocal daemon
        daemon = subprocess.Popen([str(app / 'Contents/MacOS/awb'), 'daemon'],
                                  env=dict(env, **injection), stdout=log, stderr=log)
        for _ in range(100):
            assert daemon.poll() is None
            if (state / 'browser.sock').exists():
                try:
                    if cli('status')['ready']:
                        return
                except (AssertionError, json.JSONDecodeError):
                    pass
            time.sleep(.1)
        raise AssertionError('GUI fixture failed to start')

    try:
        start()
        cli('space', 'create', 'ui-direct', '--proxy', 'direct')
        cli('open', url, '--space', 'ui-direct')
        cli('space', 'create', 'ui-proxy', '--proxy', proxy_url)
        if args.conflict:
            cli('shutdown', '--all'); daemon.wait(timeout=15)
            settings.write_text(json.dumps({'HTTPEnable': 1}))
            start()
        metadata = dict(app=str(app), socket=env['BROWSER_SOCKET'], settings=str(settings), url=url, proxyURL=proxy_url)
        (out / 'fixture.json').write_text(json.dumps(metadata, indent=2))
        print(json.dumps(metadata), flush=True)
        input('Press Enter to delete fixture Spaces and stop this test app: ')
    finally:
        settings.write_text('{}')
        if daemon and daemon.poll() is None:
            for space in cli('space', 'list'):
                cli('space', 'delete', space['id'])
            cli('shutdown', '--all'); daemon.wait(timeout=15)
        site.shutdown(); site.server_close()
        relay.shutdown(); relay.server_close(); log.close()


if __name__ == '__main__':
    main()
