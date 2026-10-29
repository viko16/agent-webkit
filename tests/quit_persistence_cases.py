"""Exercise AppKit quit persistence with a generated, observable test application."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]


def quit_fixture(out):
    source = (ROOT / 'Sources/Browser/main.swift').read_text()
    marker = '            self.model = model\n'
    assert source.count(marker) == 1
    source = source.replace(marker, marker + '''            var lastQuitToken = ""
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let trigger = self.options.dataDirectory.appendingPathComponent("quit-trigger")
                    guard let data = try? Data(contentsOf: trigger),
                          let token = String(data: data, encoding: .utf8), token != lastQuitToken else { return }
                    lastQuitToken = token
                    if let window = self.observer?.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
                    NSApp.terminate(nil)
                    fputs("QUIT-CANCELLED sheet=\\(self.observer?.window.attachedSheet != nil)\\n", stderr)
                }
            }
''')
    generated_main = out / 'main.swift'
    generated_main.write_text(source)
    browser = (ROOT / 'Sources/Browser/Browser.swift').read_text()
    marker = '    func save(_ space: Space) throws {\n'
    assert browser.count(marker) == 1
    browser = browser.replace(marker, marker + '        fputs("SAVE-ATTEMPT: \\(space.record.name)\\n", stderr)\n')
    generated_browser = out / 'Browser.swift'
    generated_browser.write_text(browser)
    app = out / 'Quit Persistence.app'
    binary = app / 'Contents/MacOS/browser'
    binary.parent.mkdir(parents=True)
    info = plistlib.loads((ROOT / 'packaging/Info.plist').read_bytes())
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    replacements = {'main.swift': generated_main, 'Browser.swift': generated_browser}
    sources = [str(replacements.get(path.name, path))
               for path in sorted((ROOT / 'Sources/Browser').glob('*.swift'))]
    build = subprocess.run(['swiftc', '-g', *sources, '-o', str(binary)],
                           capture_output=True, text=True, timeout=120)
    (out / 'build.log').write_text(build.stdout + build.stderr)
    assert build.returncode == 0, f'Fixture build failed; see {out / "build.log"}'
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    return binary


def main():
    out = ROOT / '.artifacts' / time.strftime('quit-persistence-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    binary = quit_fixture(out)
    state = Path(tempfile.mkdtemp(prefix='aw-quit-'))
    env = dict(os.environ, BROWSER_DATA_DIR=str(state), BROWSER_SOCKET=str(state / 'browser.sock'))
    log_path = out / 'daemon.log'
    daemon = None
    permissions = 0o700

    def cli(*args):
        result = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=15)
        response = json.loads(result.stdout)
        assert result.returncode == 0 and response['ok'], (args, response, result.stderr)
        return response['result']

    def wait_for(check, message):
        for _ in range(100):
            assert daemon.poll() is None, f'Unexpected app exit; see {log_path}'
            if check():
                return
            time.sleep(.05)
        raise AssertionError(message)

    with log_path.open('w') as log:
        try:
            daemon = subprocess.Popen([str(binary), 'daemon'], env=env, stdout=log, stderr=log)
            wait_for(lambda: (state / 'browser.sock').exists(), 'No IPC socket')
            wait_for(lambda: cli('status')['ready'], 'App did not become ready')
            for name in ('quit-first', 'quit-second'):
                cli('space', 'create', name, '--proxy', 'direct')
            permissions = state.stat().st_mode & 0o777
            before = log_path.read_text()
            trigger = state / 'quit-trigger'
            trigger.write_text('')
            state.chmod(0o500)
            trigger.write_text('fail')
            wait_for(lambda: 'QUIT-CANCELLED sheet=true' in log_path.read_text(), 'Quit was not cancelled with a prompt')
            attempts = log_path.read_text()[len(before):]
            for name in ('quit-first', 'quit-second'):
                assert f'SAVE-ATTEMPT: {name}' in attempts, attempts
            assert cli('status')['ready']
            assert len(cli('space', 'list')) == 2
            state.chmod(permissions)
            trigger.write_text('succeed')
            assert daemon.wait(timeout=15) == 0
            assert len(json.loads((state / 'spaces.json').read_text())) == 2
            # Restart after normal GUI quit, then remove only this test's real stores.
            trigger.write_text('')
            daemon = subprocess.Popen([str(binary), 'daemon'], env=env, stdout=log, stderr=log)
            time.sleep(.3)
            wait_for(lambda: cli('status')['ready'], 'App did not restart after GUI quit')
            for space in cli('space', 'list'):
                assert cli('space', 'delete', space['id'])['websiteDataRemoved']
            cli('shutdown', '--all')
            assert daemon.wait(timeout=15) == 0
            assert json.loads((state / 'spaces.json').read_text()) == []
            report = dict(passed=True, appKitQuitCancelled=True, errorPromptShown=True,
                          allSpacesAttempted=True, daemonSurvived=True,
                          normalQuitAfterPermissionRecovery=True, storesCleaned=True,
                          stateDirectory=str(state))
            (out / 'report.json').write_text(json.dumps(report, indent=2))
            print(json.dumps(dict(report=str(out / 'report.json'), **report)))
        finally:
            state.chmod(permissions)
            if daemon and daemon.poll() is None:
                try:
                    for space in cli('space', 'list'):
                        cli('space', 'delete', space['id'])
                    cli('shutdown', '--all')
                    daemon.wait(timeout=15)
                except Exception:
                    daemon.terminate()
                    try:
                        daemon.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        daemon.kill(); daemon.wait(timeout=10)
                    raise


if __name__ == '__main__':
    main()
