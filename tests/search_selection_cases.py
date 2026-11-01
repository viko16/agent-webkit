"""Verify native sidebar search and displayed WebViews in a disposable application."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time

from fixtures import origin
from skill_workflow import cleanup_test_services, verify_cleanup


ROOT = Path(__file__).resolve().parents[1]


def search_fixture(out):
    source = (ROOT / 'Sources/Browser/Window.swift').read_text()
    marker = '        window.orderBack(nil)\n'
    assert source.count(marker) == 1
    source = source.replace(marker, marker + '''        var lastSearchToken = ""
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let directory = URL(fileURLWithPath: self.model.storagePath)
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("search-request.json")),
                      let request = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      let token = request["token"], token != lastSearchToken, let query = request["query"] else { return }
                lastSearchToken = token
                if let sheet = self.window.attachedSheet { self.window.endSheet(sheet) }
                self.search.stringValue = query
                self.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: self.search))
                Task { @MainActor in
                    if request["action"] == "new-tab" {
                        self.newTab(nil)
                        while self.creatingTab { try? await Task.sleep(nanoseconds: 10_000_000) }
                    }
                    let row = self.table.selectedRow
                    let sidebar = self.filteredSpaces.indices.contains(row) ? self.filteredSpaces[row].record.id.uuidString : nil
                    let response: [String: Any] = [
                        "token": token, "query": self.search.stringValue,
                        "filteredSpaceIds": self.filteredSpaces.map { $0.record.id.uuidString },
                        "sidebarSpaceId": sidebar as Any? ?? NSNull(),
                        "selectedSpaceId": self.selectedSpace?.uuidString as Any? ?? NSNull(),
                        "displayedTabId": self.displayed?.id.uuidString as Any? ?? NSNull(),
                        "displayedURL": self.displayed?.webView.url?.absoluteString as Any? ?? NSNull(),
                        "displayedInContent": self.displayed.map { $0.webView.superview === self.host } ?? false,
                        "emptyVisible": !self.empty.isHidden,
                        "canCreateTab": self.canCreateTab,
                        "message": self.transientMessage as Any? ?? NSNull(),
                        "errorSheet": self.window.attachedSheet != nil]
                    if let result = try? JSONSerialization.data(withJSONObject: response),
                       let output = ProcessInfo.processInfo.environment["BROWSER_TEST_SEARCH_RESPONSE"] {
                        try? result.write(to: URL(fileURLWithPath: output), options: .atomic)
                    }
                }
            }
        }
''')
    generated = out / 'Window.swift'
    generated.write_text(source)
    app = out / 'Search Selection.app'
    binary = app / 'Contents/MacOS/awb'
    binary.parent.mkdir(parents=True)
    info = plistlib.loads((ROOT / 'packaging/Info.plist').read_bytes())
    info['CFBundleIdentifier'] = 'local.agent-webkit.search-test'
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    sources = []
    for path in sorted((ROOT / 'Sources/Browser').glob('*.swift')):
        copied = out / path.name
        if path.name != 'Window.swift':
            text = path.read_text()
            if path.name == 'main.swift':
                text = text.replace('app.setActivationPolicy(.regular)', 'app.setActivationPolicy(.prohibited)')
            copied.write_text(text)
        sources.append(str(copied))
    build = subprocess.run(['swiftc', '-g', '-module-cache-path', str(out / 'module-cache'), *sources, '-o', str(binary)],
                           capture_output=True, text=True, timeout=120)
    (out / 'build.log').write_text(build.stdout + build.stderr)
    assert build.returncode == 0, f'Fixture build failed; see {out / "build.log"}'
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    return binary


def main():
    out = ROOT / '.artifacts' / time.strftime('fix-gui-search-selection-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    binary = search_fixture(out)
    state = Path(tempfile.mkdtemp(prefix='aw-search-'))
    env = dict(os.environ, BROWSER_DATA_DIR=str(state), BROWSER_SOCKET=str(state / 'browser.sock'),
               BROWSER_MAX_TABS_PER_SPACE='3', BROWSER_TEST_SEARCH_RESPONSE=str(out / 'search-response.json'))
    site, _ = origin()
    base = f'http://127.0.0.1:{site.server_address[1]}/index.html'
    daemon = None
    results = []

    def cli(*args):
        process = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=15)
        response = json.loads(process.stdout)
        assert process.returncode == 0 and response['ok'], (args, response, process.stderr)
        return response['result']

    def native(query, action='search'):
        token = str(len(results))
        request = state / 'search-request.json'
        request.write_text(json.dumps(dict(token=token, query=query, action=action)))
        for _ in range(100):
            assert daemon.poll() is None, 'Fixture app exited'
            response = out / 'search-response.json'
            if response.exists():
                result = json.loads(response.read_text())
                if result['token'] == token:
                    break
            time.sleep(.05)
        else:
            raise AssertionError('No native search response')
        results.append(result)
        return result

    def search(query, expected, filtered):
        result = native(query)
        assert result['filteredSpaceIds'] == [space['id'] for space in filtered], result
        expected_id = expected['id'] if expected else None
        assert result['selectedSpaceId'] == result['sidebarSpaceId'] == expected_id, result
        assert result['emptyVisible'] == (expected is None), result
        if expected:
            assert result['displayedTabId'] == expected['defaultTabId'], result
            assert result['displayedURL'] == base + '?space=' + expected['name'], result
            assert result['displayedInContent'], result
        else:
            assert result['displayedTabId'] is None and not result['displayedInContent'], result
        assert cli('status')['observer']['spaceId'] == expected_id

    def new_tab(expected):
        before = cli('space', 'list')
        previous = next(space for space in before if space['id'] == expected['id']) if expected else None
        result = native('no-match', 'new-tab')
        after = cli('space', 'list')
        space = next(space for space in after if space['id'] == expected['id']) if expected else after[0]
        assert len(after) == len(before) + (expected is None), (before, after)
        assert result['query'] == '' and not result['errorSheet'] and result['message'] is None, result
        assert result['selectedSpaceId'] == result['sidebarSpaceId'] == space['id'], result
        assert result['displayedInContent'], result
        assert result['displayedTabId'] == space['tabs'][-1]['tabId'], (result, space)
        if previous:
            assert space['defaultTabId'] == previous['defaultTabId'] != result['displayedTabId'], space
            assert space['proxy'] == previous['proxy'] and space['tls'] == previous['tls'], space
            assert len(space['tabs']) == len(previous['tabs']) + 1, space
            assert [item for item in after if item['id'] != space['id']] == [
                item for item in before if item['id'] != space['id']], (before, after)
        else:
            assert space['name'] == 'personal' and space['proxy'] == 'direct', space
            assert space['tls']['policy'] == 'system' and len(space['tabs']) == 1, space
        assert cli('status')['observer']['tabId'] == result['displayedTabId'], result
        return space

    with (out / 'daemon.log').open('w') as log:
        try:
            daemon = subprocess.Popen([str(binary), 'daemon'], env=env, stdout=log, stderr=log)
            for _ in range(100):
                assert daemon.poll() is None, 'Fixture app exited'
                if (state / 'browser.sock').exists() and cli('status')['ready']:
                    break
                time.sleep(.05)
            else:
                raise AssertionError('Startup timed out')
            frontmost = cli('status')['frontmostPid']
            first = cli('space', 'create', 'search-a', '--proxy', 'direct')
            second = cli('space', 'create', 'search-b', '--proxy', 'direct')
            for space in (first, second):
                cli('open', base + '?space=' + space['name'], '--space', space['id'])
            search('', first, [first, second])
            search('search-b', second, [second])
            search('no-match', None, [])
            search('', first, [first, second])
            # A filter with no selection reuses an existing Space even without personal.
            new_tab(first)
            personal = cli('space', 'create', 'personal', '--proxy', 'direct', '--ignore-certificate-errors')
            new_tab(personal)
            # A visible selection still takes priority over the fallback personal Space.
            selected = native('search-b', 'new-tab')
            assert selected['selectedSpaceId'] == second['id'] and selected['query'] == '', selected
            assert cli('space', 'info', second['id'])['defaultTabId'] == second['defaultTabId']

            # The fallback target's busy state must disable the native command too.
            waiting = subprocess.Popen([str(binary), 'wait', '#never-created', '--timeout', '1500',
                                        '--space', personal['id']], env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            try:
                for _ in range(100):
                    if cli('space', 'info', personal['id'])['busy']:
                        break
                    assert waiting.poll() is None, 'Wait finished before busy state was observed'
                    time.sleep(.01)
                else:
                    raise AssertionError('Space never became busy')
                busy = native('no-match', 'new-tab')
                assert not busy['canCreateTab'] and not busy['errorSheet'], busy
                assert busy['query'] == 'no-match' and busy['selectedSpaceId'] is None, busy
                assert len(cli('tab', 'list', '--space', personal['id'])) == 2
            finally:
                output, errors = waiting.communicate(timeout=5)
                assert waiting.returncode == 1 and json.loads(output)['error']['code'] == 'timeout', (output, errors)

            # Failed persistence must keep the search and roll back the added Tab.
            permissions = state.stat().st_mode & 0o777
            try:
                state.chmod(0o500)
                failed = native('no-match', 'new-tab')
                assert failed['errorSheet'] and failed['message'] and failed['query'] == 'no-match', failed
                assert failed['selectedSpaceId'] is None
                assert len(cli('tab', 'list', '--space', personal['id'])) == 2
            finally:
                state.chmod(permissions)
            new_tab(personal)
            limited = native('no-match', 'new-tab')
            assert limited['errorSheet'] and limited['message'] and limited['query'] == 'no-match', limited
            assert len(cli('tab', 'list', '--space', personal['id'])) == 3
            # Only an actually empty model should create the first personal Space.
            native('')
            for space in cli('space', 'list'):
                cli('space', 'delete', space['id'])
            new_tab(None)
            assert cli('status')['frontmostPid'] == frontmost, 'Native actions changed the foreground app'
        finally:
            failed = sys.exc_info()[0] is not None
            errors = cleanup_test_services(cli, daemon, site)
            if errors:
                (out / 'cleanup-errors.json').write_text(json.dumps([str(error) for error in errors], indent=2))
                if not failed:
                    raise RuntimeError('Search test cleanup failed') from errors[0]
    verify_cleanup(state)
    report = dict(passed=True, cases=results, stateDirectory=str(state), storesCleaned=True)
    (out / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(dict(report=str(out / 'report.json'), passed=True)))


if __name__ == '__main__':
    main()
