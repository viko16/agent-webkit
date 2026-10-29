"""Restore a real pending store when no live Space has initialized WebKit yet."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]


def cleanup_failure_app(out):
    """Instrument a generated source copy; ship no fault-injection hooks."""
    source = (ROOT / 'Sources/Browser/Browser.swift').read_text()
    removal = '    private func removeStoreOnce(_ id: UUID) async throws {\n'
    clearing = '            store.removeData(ofTypes: types, modifiedSince: .distantPast) {\n'
    assert source.count(removal) == source.count(clearing) == 1
    source = source.replace(removal, removal + '''        if ProcessInfo.processInfo.environment["BROWSER_TEST_CLEANUP_ID"] == id.uuidString {
            if ProcessInfo.processInfo.environment["BROWSER_TEST_CLEANUP_ERROR"] != "data_store_removal_timeout" {
                throw BrowserError("injected_store_in_use", "Force the clearStoreContents fallback")
            }
        }
''')
    callback = '            WKWebsiteDataStore.remove(forIdentifier: id) { error in\n'
    assert source.count(callback) == 1
    source = source.replace(callback, '''            if ProcessInfo.processInfo.environment["BROWSER_TEST_CLEANUP_ID"] == id.uuidString,
               ProcessInfo.processInfo.environment["BROWSER_TEST_CLEANUP_ERROR"] == "data_store_removal_timeout" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { operation.finish(.success(())) }
                return
            }
''' + callback)
    source = source.replace(clearing, '''            if ProcessInfo.processInfo.environment["BROWSER_TEST_CLEANUP_ID"] == id.uuidString {
                let code = ProcessInfo.processInfo.environment["BROWSER_TEST_CLEANUP_ERROR"]!
                fputs("Injected cleanup failure: \\(code) \\(id)\\n", stderr)
                if code == "data_removal_failed" {
                    operation.finish(.failure(BrowserError(code, "Injected remaining website data")))
                } else {
                    // Model a delayed WebKit callback that retains the operation.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { operation.finish(.success(())) }
                }
                // For data_removal_timeout, let the original five-second timer fire.
                return
            }
''' + clearing)
    generated = out / 'Browser.swift'
    generated.write_text(source)
    app = out / 'Cleanup Failure.app'
    binary = app / 'Contents/MacOS/browser'
    binary.parent.mkdir(parents=True)
    # Keep the product Bundle ID: the fixture must use the same real WebKit stores.
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(
        plistlib.loads((ROOT / 'packaging/Info.plist').read_bytes())))
    sources = [str(generated) if path.name == 'Browser.swift' else str(path)
               for path in sorted((ROOT / 'Sources/Browser').glob('*.swift'))]
    build = subprocess.run(['swiftc', '-g', *sources, '-o', str(binary)],
                           capture_output=True, text=True, timeout=120)
    (out / 'cleanup-failure-build.log').write_text(build.stdout + build.stderr)
    assert build.returncode == 0, f'Failure fixture build failed; see {out / "cleanup-failure-build.log"}'
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    return binary


def verify_store_cleanup_failures(cli, start, stop, state, base, out):
    # The preceding real-store case may have left a deferred empty container.
    stop(); start()
    executable = cleanup_failure_app(out)
    registry = state / 'spaces.json'
    results = []
    for code in ('data_removal_failed', 'data_removal_timeout', 'data_store_removal_timeout'):
        failed = cli('space', 'create', 'cleanup-failed', '--proxy', 'direct')
        later = cli('space', 'create', 'cleanup-later', '--proxy', 'direct')
        healthy = cli('space', 'create', 'cleanup-healthy', '--proxy', 'direct')
        url = base + '?cleanup=' + code
        cli('open', url, '--space', 'cleanup-healthy')
        cli('evaluate', 'localStorage.setItem("restore-probe", "preserved"); true', '--space', 'cleanup-healthy')
        stop()
        records = json.loads(registry.read_text())
        for record in records:
            if record['id'] in (failed['id'], later['id']):
                record['deleting'] = True
        temporary = state / 'cleanup-failures.tmp'
        temporary.write_text(json.dumps(records))
        os.replace(temporary, registry)
        started = time.monotonic()
        start(executable=executable, extra_env={
            'BROWSER_TEST_CLEANUP_ID': failed['id'], 'BROWSER_TEST_CLEANUP_ERROR': code})
        startup_seconds = time.monotonic() - started
        if code.endswith('_timeout'):
            assert startup_seconds >= 5, startup_seconds
        status = cli('status')
        assert status['ready'] and status['pendingStoreCleanup'] == 1, status
        assert status['storeCleanupErrors'][0]['error']['code'] == code, status
        spaces = cli('space', 'list')
        assert [space['id'] for space in spaces] == [healthy['id']], spaces
        assert spaces[0]['defaultTabId'] == healthy['defaultTabId'], spaces
        cli('wait', '#message', '--space', 'cleanup-healthy')
        restored = cli('evaluate', '[location.href, localStorage.getItem("restore-probe")]', '--space', 'cleanup-healthy')
        assert restored['value'] == [url, 'preserved'], restored
        records = json.loads(registry.read_text())
        pending = [record for record in records if record.get('deleting')]
        assert [record['id'] for record in pending] == [failed['id']], records
        assert all(record['id'] != later['id'] for record in records), records
        # Explicit deletion still reports the cleanup error instead of false success.
        cli('space', 'delete', failed['id'], error=code)
        assert cli('status')['ready'] and cli('status')['pendingStoreCleanup'] == 1
        stop()
        assert any(record['id'] == failed['id'] and record['deleting']
                   for record in json.loads(registry.read_text()))
        start()
        assert cli('status')['pendingStoreCleanup'] == 0
        cli('wait', '#message', '--space', 'cleanup-healthy')
        assert cli('evaluate', 'localStorage.getItem("restore-probe")', '--space', 'cleanup-healthy')['value'] == 'preserved'
        assert cli('space', 'delete', 'cleanup-healthy')['websiteDataRemoved']
        # Finish any deferred container removal through the normal daemon.
        stop(); start()
        assert cli('status')['pendingStoreCleanup'] == 0
        assert json.loads(registry.read_text()) == []
        results.append(dict(error=code, ready=True, pendingStoreCleanup=1,
                            laterTombstoneRemoved=True, healthySpaceRestored=True,
                            explicitDeleteStillFails=True, retryAfterRestart=True,
                            startupSeconds=startup_seconds))
    return dict(passed=True, method='generated daemon with injected Store fallback failures', cases=results)


def verify_delete_persistence_failure(cli, start, stop, state, base):
    created = cli('space', 'create', 'delete-transaction', '--proxy', 'direct')
    cli('space', 'create', 'delete-peer', '--proxy', 'direct')
    cli('open', base, '--space', 'delete-transaction')
    cli('evaluate', 'document.cookie="deleteProbe=kept; Max-Age=3600; Path=/";localStorage.deleteProbe="kept";true', '--space', 'delete-transaction')
    permissions = state.stat().st_mode & 0o777
    try:
        state.chmod(0o500)
        cli('space', 'delete', 'delete-transaction', error='operation_failed')
    finally:
        state.chmod(permissions)
    cli('tab', 'new', '--space', 'delete-peer')
    records = json.loads((state / 'spaces.json').read_text())
    assert not next(record for record in records if record['id'] == created['id'])['deleting']
    stop(); start()
    cli('wait', '#message', '--space', 'delete-transaction')
    value = cli('evaluate', '[document.cookie,localStorage.deleteProbe]', '--space', 'delete-transaction')['value']
    assert value == ['deleteProbe=kept', 'kept'], value
    for name in ('delete-transaction', 'delete-peer'):
        cli('space', 'delete', name)
    stop(); start()
    return dict(passed=True, failedDeleteRolledBack=True, cookieAndLocalStoragePreserved=True)


def verify_pending_store_only(cli, start, stop, state, base):
    name = 'pending-only'
    created = cli('space', 'create', name, '--proxy', 'direct')
    cli('open', base, '--space', name)
    cli('evaluate', 'localStorage.setItem("cleanup-probe","must-be-removed");true', '--space', name)
    stop()
    registry = state / 'spaces.json'
    records = json.loads(registry.read_text())
    assert len(records) == 1 and records[0]['id'] == created['id'], records
    # This is this run's generated registry. Model a crash after the deletion
    # tombstone was persisted, before the actual WebKit purge could complete.
    # Do not remove the website store or replace WebKit with a mock.
    records[0]['deleting'] = True
    temporary = state / 'pending-only.tmp'
    temporary.write_text(json.dumps(records))
    os.replace(temporary, registry)
    start()
    assert cli('status')['pendingStoreCleanup'] == 0
    assert cli('space', 'list') == [] and json.loads(registry.read_text()) == []
    replacement = cli('space', 'create', name, '--proxy', 'direct')
    assert replacement['id'] != created['id']
    cli('open', base, '--space', name)
    assert cli('evaluate', 'localStorage.getItem("cleanup-probe")', '--space', name)['value'] is None
    assert cli('space', 'delete', name)['websiteDataRemoved']
    return {'passed': True, 'pendingId': created['id'], 'replacementId': replacement['id'],
            'method': 'real store + interrupted-deletion registry; new process with no live Spaces',
            'pendingStoreCleanup': 0, 'registryEmptyAfterRestore': True}


def verify_delete_without_active_stores(cli, start, stop, state, base):
    cases = []
    registry = state / 'spaces.json'
    for mode in ('all-suspended', 'all-invalid'):
        created = []
        for index in range(2):
            name = f'no-runtime-{index}'
            space = cli('space', 'create', name, '--proxy', 'direct')
            created.append(space)
            cli('open', base, '--space', name)
            cli('evaluate', 'localStorage.deleteProbe="old-data";true', '--space', name)
            cli('space', 'suspend', name)
        stop()
        if mode == 'all-invalid':
            records = json.loads(registry.read_text())
            for record in records:
                record['suspended'] = False
                record['proxy'] = 'http://invalid.example:8899'
            temporary = state / 'invalid-delete.tmp'
            temporary.write_text(json.dumps(records)); os.replace(temporary, registry)
        start()
        assert cli('status')['liveWebViews'] == 0
        for space in created:
            info = cli('space', 'info', space['id'])
            assert info['lifecycle'] == ('suspended' if mode == 'all-suspended' else 'configuration-error'), info
            result = cli('space', 'delete', space['id'])
            assert result['websiteDataRemoved'], result
            assert cli('status')['ready'] and cli('status')['liveWebViews'] == 0
        stop(); start()
        assert cli('status')['pendingStoreCleanup'] == 0 and json.loads(registry.read_text()) == []
        replacement = cli('space', 'create', created[0]['name'], '--proxy', 'direct')
        assert replacement['id'] != created[0]['id']
        cli('open', base, '--space', replacement['id'])
        assert cli('evaluate', 'localStorage.deleteProbe??null', '--space', replacement['id'])['value'] is None
        cli('space', 'delete', replacement['id'])
        stop(); start()
        cases.append(dict(case=mode, zeroWebViewsBeforeAndAfterDeletion=True,
                          daemonSurvivesPublicDeletion=True, replacementStoreIsolated=True))
    return dict(passed=True, cases=cases)
