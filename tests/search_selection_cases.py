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
                self.search.stringValue = query
                self.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: self.search))
                let row = self.table.selectedRow
                let sidebar = self.filteredSpaces.indices.contains(row) ? self.filteredSpaces[row].record.id.uuidString : nil
                let response: [String: Any] = [
                    "token": token, "query": query,
                    "filteredSpaceIds": self.filteredSpaces.map { $0.record.id.uuidString },
                    "sidebarSpaceId": sidebar as Any? ?? NSNull(),
                    "selectedSpaceId": self.selectedSpace?.uuidString as Any? ?? NSNull(),
                    "displayedTabId": self.displayed?.id.uuidString as Any? ?? NSNull(),
                    "displayedURL": self.displayed?.webView.url?.absoluteString as Any? ?? NSNull(),
                    "displayedInContent": self.displayed.map { $0.webView.superview === self.host } ?? false,
                    "emptyVisible": !self.empty.isHidden]
                if let result = try? JSONSerialization.data(withJSONObject: response) {
                    try? result.write(to: directory.appendingPathComponent("search-response.json"), options: .atomic)
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
            copied.write_text(path.read_text())
        sources.append(str(copied))
    build = subprocess.run(['swiftc', '-g', *sources, '-o', str(binary)],
                           capture_output=True, text=True, timeout=120)
    (out / 'build.log').write_text(build.stdout + build.stderr)
    assert build.returncode == 0, f'Fixture build failed; see {out / "build.log"}'
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    return binary


def main():
    out = ROOT / '.artifacts' / time.strftime('search-selection-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    binary = search_fixture(out)
    state = Path(tempfile.mkdtemp(prefix='aw-search-'))
    env = dict(os.environ, BROWSER_DATA_DIR=str(state), BROWSER_SOCKET=str(state / 'browser.sock'))
    site, _ = origin()
    base = f'http://127.0.0.1:{site.server_address[1]}/index.html'
    daemon = None
    results = []

    def cli(*args):
        process = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=15)
        response = json.loads(process.stdout)
        assert process.returncode == 0 and response['ok'], (args, response, process.stderr)
        return response['result']

    def search(query, expected, filtered):
        token = str(len(results))
        request = state / 'search-request.json'
        request.write_text(json.dumps(dict(token=token, query=query)))
        for _ in range(100):
            assert daemon.poll() is None, 'Fixture app exited'
            response = state / 'search-response.json'
            if response.exists():
                result = json.loads(response.read_text())
                if result['token'] == token:
                    break
            time.sleep(.05)
        else:
            raise AssertionError('No native search response')
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
        results.append(result)

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
            first = cli('space', 'create', 'search-a', '--proxy', 'direct')
            second = cli('space', 'create', 'search-b', '--proxy', 'direct')
            for space in (first, second):
                cli('open', base + '?space=' + space['name'], '--space', space['id'])
            search('', first, [first, second])
            search('search-b', second, [second])
            search('no-match', None, [])
            search('', first, [first, second])
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
