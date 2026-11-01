"""Real Store deletion callbacks with test-only gates and injected failure paths."""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import plistlib
import socket
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]


def gated_cleanup_app(out):
    source = (ROOT / 'Sources/Browser/Browser.swift').read_text()
    marker = '    private func removeStoreOnce(_ id: UUID) async throws {\n'
    assert source.count(marker) == 1
    source = source.replace(marker, '''    private var testRemovalAttempts = 0
''' + marker + '''        if ProcessInfo.processInfo.environment["BROWSER_TEST_STORE_ID"] == id.uuidString {
            testRemovalAttempts += 1
            testStoreEvent("attempt:\\(testRemovalAttempts)")
            let mode = ProcessInfo.processInfo.environment["BROWSER_TEST_STORE_MODE"]!
            if testRemovalAttempts == 1 && ["failure", "clear-timeout", "retry-timeout"].contains(mode) {
                throw BrowserError("injected_store_in_use", "Exercise the public clear/fetch fallback")
            }
        }
''')
    completed = '            let removed = try await removeStore(id)\n'
    assert source.count(completed) == 1
    source = source.replace(completed, completed + '''            if ProcessInfo.processInfo.environment["BROWSER_TEST_STORE_ID"] == id.uuidString {
                testStoreEvent("result:\\(removed)")
            }
''')
    removal = '''            WKWebsiteDataStore.remove(forIdentifier: id) { error in
                // The caller timing out does not mean WebKit has stopped this operation.
                self.pendingStoreCallbacks.remove(id)
                if let error { operation.finish(.failure(error)) } else { operation.finish(.success(())) }
            }
'''
    assert source.count(removal) == 1
    source = source.replace(removal, '''            WKWebsiteDataStore.remove(forIdentifier: id) { error in
                testStoreCallback(id, phase: "remove") {
                    self.pendingStoreCallbacks.remove(id)
                    if let error { operation.finish(.failure(error)) } else { operation.finish(.success(())) }
                }
            }
''')
    fetch = '''                store.fetchDataRecords(ofTypes: types) { records in
                    self.pendingStoreCallbacks.remove(id)
                    if records.isEmpty { operation.finish(.success(())) }
                    else { operation.finish(.failure(BrowserError("data_removal_failed", "网站数据仍存在；已保留删除标记，下次启动会重试"))) }
                }
'''
    assert source.count(fetch) == 1
    source = source.replace(fetch, '''                store.fetchDataRecords(ofTypes: types) { records in
                    testStoreCallback(id, phase: "fetch") {
                        self.pendingStoreCallbacks.remove(id)
                        let injectFailure = ProcessInfo.processInfo.environment["BROWSER_TEST_STORE_ID"] == id.uuidString &&
                            ProcessInfo.processInfo.environment["BROWSER_TEST_STORE_MODE"] == "failure"
                        if records.isEmpty && !injectFailure { operation.finish(.success(())) }
                        else { operation.finish(.failure(BrowserError("data_removal_failed", "Injected failed verification or remaining data"))) }
                    }
                }
''')
    source += '''
@MainActor private func testStoreEvent(_ event: String) {
    let path = ProcessInfo.processInfo.environment["BROWSER_TEST_STORE_EVENTS"]!
    let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try! handle.seekToEnd()
    try! handle.write(contentsOf: Data((event + "\\n").utf8))
}
@MainActor private func testStoreCallback(_ id: UUID, phase: String, _ finish: @escaping () -> Void) {
    let env = ProcessInfo.processInfo.environment
    let mode = env["BROWSER_TEST_STORE_MODE"] ?? ""
    let gatedPhase = ["failure", "clear-timeout"].contains(mode) ? "fetch" : "remove"
    guard env["BROWSER_TEST_STORE_ID"] == id.uuidString, phase == gatedPhase else { finish(); return }
    testStoreEvent("waiting:" + phase)
    func resumeWhenReleased() {
        if FileManager.default.fileExists(atPath: env["BROWSER_TEST_STORE_RELEASE"]!) {
            finish()
            testStoreEvent("released:" + phase)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: resumeWhenReleased)
        }
    }
    resumeWhenReleased()
}
'''
    generated = out / 'Browser.swift'
    generated.write_text(source)
    app = out / 'Store Callback Gates.app'
    binary = app / 'Contents/MacOS/awb'
    binary.parent.mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(
        plistlib.loads((ROOT / 'packaging/Info.plist').read_bytes())))
    sources = [str(generated) if p.name == 'Browser.swift' else str(p)
               for p in sorted((ROOT / 'Sources/Browser').glob('*.swift'))]
    build = subprocess.run(['swiftc', '-g', *sources, '-o', str(binary)],
                           capture_output=True, text=True, timeout=120)
    (out / 'build.log').write_text(build.stdout + build.stderr)
    assert build.returncode == 0, f'See {out / "build.log"}'
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    return binary


def verify_concurrent_store_deletion(cli, start, stop, state, base, out):
    out = out / 'store-deletion-races'
    out.mkdir()
    executable = gated_cleanup_app(out)
    cases = []
    for mode in ('success', 'failure', 'remove-timeout', 'clear-timeout', 'retry-timeout', 'disconnect'):
        target = cli('space', 'create', 'delete-race', '--proxy', 'direct')
        cli('space', 'create', 'delete-healthy', '--proxy', 'direct')
        peer = cli('space', 'create', 'delete-peer', '--proxy', 'direct')
        cli('open', base, '--space', 'delete-healthy')
        cli('evaluate', 'localStorage.deleteRace="preserved";true', '--space', 'delete-healthy')
        stop()
        events = out / f'{mode}-events.txt'
        events.write_text('')
        release = out / f'{mode}-release'
        start(executable=executable, extra_env={
            'BROWSER_TEST_STORE_ID': target['id'], 'BROWSER_TEST_STORE_MODE': mode,
            'BROWSER_TEST_STORE_EVENTS': str(events), 'BROWSER_TEST_STORE_RELEASE': str(release)})
        cli('wait', '#message', '--space', 'delete-healthy')

        def wait_event(prefix):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if any(line.startswith(prefix) for line in events.read_text().splitlines()):
                    return
                time.sleep(.02)
            raise AssertionError((mode, prefix, events.read_text()))

        expected = ('data_removal_failed' if mode == 'failure' else
                    'data_removal_timeout' if mode == 'clear-timeout' else
                    'data_store_removal_timeout' if mode.endswith('timeout') else None)
        with ThreadPoolExecutor(max_workers=1) as pool:
            if mode == 'disconnect':
                with socket.socket(socket.AF_UNIX) as client:
                    client.connect(str(state / 'browser.sock'))
                    client.sendall((json.dumps(dict(command='space.delete', args=[target['id']], options={})) + '\n').encode())
                first = None
            else:
                first = pool.submit(cli, 'space', 'delete', target['id'], error=expected)
            try:
                wait_event('waiting:')
                # A second independent CLI must not issue a second WebKit removal.
                cli('space', 'delete', target['id'].lower(), error='space_busy')
                # Test by name too, while the UUID survives only in the tombstone.
                cli('space', 'delete', 'delete-race', error='space_busy')
                assert cli('evaluate', 'localStorage.deleteRace', '--space', 'delete-healthy')['value'] == 'preserved'
                assert cli('space', 'delete', peer['id'])['websiteDataRemoved']
                if mode.endswith('timeout'):
                    first.result(timeout=10)
                    cli('space', 'delete', target['id'], error='space_busy')
                    records = json.loads((state / 'spaces.json').read_text())
                    assert next(r for r in records if r['id'] == target['id'])['deleting']
                attempts = [line for line in events.read_text().splitlines() if line.startswith('attempt:')]
                assert len(attempts) == (2 if mode == 'retry-timeout' else 1), (mode, attempts)
            finally:
                release.touch()
            wait_event('released:')
            if first is not None:
                result = first.result(timeout=15)
                if expected is None:
                    assert result['websiteDataRemoved'], result
            if mode.endswith('timeout'):
                # A late callback cannot turn the timed-out operation into reported success.
                assert any(r['id'] == target['id'] and r['deleting']
                           for r in json.loads((state / 'spaces.json').read_text()))
                assert cli('space', 'delete', target['id'])['websiteDataRemoved']
            elif mode == 'disconnect':
                wait_event('result:')
            elif mode == 'failure':
                assert any(r['id'] == target['id'] and r['deleting']
                           for r in json.loads((state / 'spaces.json').read_text()))
        stop(); start()
        assert cli('status')['pendingStoreCleanup'] == 0
        cli('wait', '#message', '--space', 'delete-healthy')
        assert cli('evaluate', 'localStorage.deleteRace', '--space', 'delete-healthy')['value'] == 'preserved'
        cli('space', 'delete', 'delete-healthy')
        stop(); start()
        assert json.loads((state / 'spaces.json').read_text()) == []
        cases.append(dict(mode=mode, duplicateCode='space_busy', independentStoreDeleted=True,
                          healthySpacePreserved=True, attemptsBeforeRelease=len(attempts),
                          restartCleanup=True, events=str(events)))
    report = dict(passed=True, method='real WebKit callbacks with generated delay gates; explicit injected fallback/failure', cases=cases)
    (out / 'report.json').write_text(json.dumps(report, indent=2))
    return report
