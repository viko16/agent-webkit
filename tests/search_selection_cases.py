"""Verify native sidebar search and displayed WebViews in a disposable application."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
from threading import Event
import uuid

from observer_hig_cases import verify_observer_hig
from observer_regression_cases import verify_observer_regressions
from observer_protection_cases import verify_observer_protection
from direct_conflict_cases import prepare_proxy_settings
from fixtures import origin
from skill_workflow import cleanup_test_services, verify_cleanup


ROOT = Path(__file__).resolve().parents[1]


def search_fixture(out):
    # Compile the observer components beside their private, test-only probe extensions.
    observer_sources = ('Window.swift', 'ObserverPageContent.swift', 'ObserverSidebar.swift', 'ObserverTabStrip.swift')
    source = '\n'.join((ROOT / 'Sources/Browser' / name).read_text() for name in observer_sources)
    # Menu copy actions write to a fixture-only pasteboard.
    assert source.count("NSPasteboard.general") == source.count("let pasteboard = NSPasteboard.general") == 1
    source = source.replace('let pasteboard = NSPasteboard.general', 'let pasteboard = NSPasteboard(name: .init(model.storagePath + ".hig-test"))')
    window_init = 'let observerWindow = ObserverKeyWindow(contentRect:'
    assert source.count(window_init) == 1
    source = source.replace(window_init, 'let observerWindow = ObserverProbeWindow(contentRect:')
    marker = '        window.orderBack(nil)\n'
    assert source.count(marker) == 1
    source = source.replace(marker, marker + '''        // WindowServer can defer popover animations indefinitely in a background-only app.
        if ProcessInfo.processInfo.environment["BROWSER_TEST_FOREGROUND"] != "1" {
            infoPopover.animates = false; downloadsPopover.animates = false
        }
        var lastSearchToken = ""
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let directory = URL(fileURLWithPath: self.model.storagePath)
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("search-request.json")),
                      let request = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      let token = request["token"], token != lastSearchToken, let query = request["query"] else { return }
                lastSearchToken = token
                if ["new-tab", "search"].contains(request["action"] ?? ""), let sheet = self.window.attachedSheet {
                    self.window.endSheet(sheet)
                }
                if self.sidebar.search.stringValue != query || request["action"] == "search" {
                    self.sidebar.search.stringValue = query
                    self.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: self.sidebar.search))
                } else if request["action"] == "inspect" {
                    // Re-read the injected proxy settings without changing the field editor.
                    self.refresh()
                }
                Task { @MainActor in
                    if request["action"] == "choose" {
                        _ = self.control(self.sidebar.search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
                    }
                    if request["action"] == "select-row" {
                        self.sidebar.probeTable.selectRowIndexes(IndexSet(integer: Int(request["row"]!)!), byExtendingSelection: false)
                    }
                    if request["action"] == "clear" { self.sidebar.probeClear.performClick(nil) }
                    if request["action"] == "create-from-search" { self.sidebar.probeCreateFromSearch.performClick(nil) }
                    if request["action"] == "new-tab" {
                        self.newTab(nil)
                        while self.creatingTab { try? await Task.sleep(nanoseconds: 10_000_000) }
                    }
                    let probe = await self.probeControls(request["action"] ?? "", request: request)
                    var form: [String: Any] = [:]
                    if let raw = request["policy"], let policy = Int(raw) {
                        let sheet = SpaceCreationSheet()
                        self.split.presentAsSheet(sheet)
                        form = sheet.probeCollapsedTLS(policy)
                    }
                    let row = self.sidebar.probeTable.selectedRow
                    let sidebar = self.sidebar.probeSpaces.indices.contains(row) ? self.sidebar.probeSpaces[row].record.id.uuidString : nil
                    let response: [String: Any] = [
                        "token": token, "query": self.sidebar.search.stringValue, "action": request["action"] ?? "", "probe": probe, "form": form,
                        "filteredSpaceIds": self.sidebar.probeSpaces.map { $0.record.id.uuidString },
                        "sidebarSpaceId": sidebar as Any? ?? NSNull(),
                        "savedTabSpaces": (UserDefaults.standard.dictionary(forKey: self.selectionKey) ?? [:]).keys.sorted(),
                        "selectedSpaceId": self.selectedSpace?.uuidString as Any? ?? NSNull(),
                        "displayedTabId": self.displayed?.id.uuidString as Any? ?? NSNull(),
                        "displayedURL": self.displayed?.webView.url?.absoluteString as Any? ?? NSNull(),
                        "displayedInContent": self.displayed.map { $0.webView.superview === self.page.host } ?? false,
                        "emptyVisible": !self.page.probeEmpty.isHidden,
                        "noResultsVisible": !self.sidebar.probeNoResults.isHidden,
                        "canCreateTab": self.canCreateTab,
                        "message": self.transientMessage as Any? ?? NSNull(),
                        "spaceCount": self.sidebar.probeCount.stringValue,
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
    generated.write_text(source + (ROOT / "tests/observer_controls_probe.swift").read_text())
    app = out / 'Search Selection.app'
    binary = app / 'Contents/MacOS/awb'
    binary.parent.mkdir(parents=True)
    info = plistlib.loads((ROOT / 'packaging/Info.plist').read_bytes())
    info['CFBundleIdentifier'] = 'local.agent-webkit.search-test'
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    sources = []
    for path in sorted((ROOT / 'Sources/Browser').glob('*.swift')):
        if path.name in observer_sources and path.name != 'Window.swift':
            continue
        copied = out / path.name
        if path.name != 'Window.swift':
            text = path.read_text()
            if path.name == 'Browser.swift':
                # Report a deferred container once, then let cleanup retry the real store.
                marker = '    private func removeStore(_ id: UUID) async throws -> Bool {'
                assert text.count(marker) == 1
                text = text.replace(marker, '    private var injectDeferredStore = true\n' + marker + """
        if injectDeferredStore, records.first(where: { $0.id == id })?.name == "test-deferred" {
            injectDeferredStore = false
            return false
        }
""")
            if path.name == 'Tab.swift':
                # Deliver a real WebKit cancellation after its replacement has finished.
                marker = '    private func failNavigation(_ navigation: WKNavigation?, error: Error, provisional: Bool) {'
                assert text.count(marker) == 1
                text = text.replace(marker, '''    var holdNextCancellation = false
    var heldCancellation: (() -> Void)?
''' + marker + '''
        let cocoaError = error as NSError
        if holdNextCancellation, cocoaError.domain == NSURLErrorDomain, cocoaError.code == NSURLErrorCancelled {
            holdNextCancellation = false
            heldCancellation = { [weak self] in self?.failNavigation(navigation, error: error, provisional: provisional) }
            return
        }
''')
            if path.name == 'SpaceDetailsView.swift':
                # Observe the ID row's real SwiftUI lifecycle, even without accessibility permission.
                marker = 'infoRow(key: tab.id.uuidString, label: "当前标签页 ID", value: tab.id.uuidString, monospace: true, copyable: true)'
                assert text.count(marker) == 1
                text = text.replace(marker, marker + '''
                            .onAppear { Self.probeDisplayedTab = tab.id }
                            .onChange(of: tab.id) { _, id in Self.probeDisplayedTab = id }
                            .onDisappear { Self.probeDisplayedTab = nil }
''')
                text += '\nextension SpaceDetailsView { @MainActor static var probeDisplayedTab: UUID? }\n'
            if path.name == 'SpaceCreationSheet.swift':
                text += (ROOT / 'tests/space_creation_probe.swift').read_text()
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
    _, proxy_env = prepare_proxy_settings(out)
    state = Path(tempfile.mkdtemp(prefix='aw-search-'))
    env = dict(os.environ, **proxy_env, BROWSER_DATA_DIR=str(state), BROWSER_SOCKET=str(state / 'browser.sock'),
               BROWSER_MAX_TABS_PER_SPACE='3', BROWSER_TEST_SEARCH_RESPONSE=str(out / 'search-response.json'))
    download_gate = Event()
    site, events = origin(download_gate=download_gate)
    base = f'http://127.0.0.1:{site.server_address[1]}/index.html'
    daemon = None
    results = []

    def cli(*args):
        process = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=15)
        response = json.loads(process.stdout)
        assert process.returncode == 0 and response['ok'], (args, response, process.stderr)
        return response['result']

    def native(query, action='search', **options):
        token = str(len(results))
        request = state / 'search-request.json'
        request.write_text(json.dumps(dict(token=token, query=query, action=action, **options)))
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

    def search(query, expected, filtered, action='search', **options):
        result = native(query, action, **options)
        assert result['filteredSpaceIds'] == [space['id'] for space in filtered], result
        assert result['selectedSpaceId'] == expected['id'], result
        assert result['sidebarSpaceId'] == (expected['id'] if expected in filtered else None), result
        assert result['noResultsVisible'] == (bool(result['query']) and not filtered), result
        assert not result['emptyVisible'] and result['displayedInContent'], result
        assert result['displayedTabId'] == expected['tabs'][0]['tabId'], result
        assert result['displayedURL'] == base + '?space=' + expected['name'], result
        assert cli('status')['observer']['spaceId'] == expected['id']

    def new_tab(expected):
        before = cli('space', 'list')
        previous = next(space for space in before if space['id'] == expected['id']) if expected else None
        result = native(expected['name'] if expected else '', 'new-tab')
        after = cli('space', 'list')
        space = next(space for space in after if space['id'] == expected['id']) if expected else after[0]
        assert len(after) == len(before) + (expected is None), (before, after)
        assert result['query'] == '' and not result['errorSheet'] and result['message'] is None, result
        assert result['selectedSpaceId'] == result['sidebarSpaceId'] == space['id'], result
        assert result['displayedInContent'], result
        assert result['displayedTabId'] == space['tabs'][-1]['tabId'], (result, space)
        if previous:
            assert space['tabs'][0]['tabId'] == previous['tabs'][0]['tabId'] != result['displayedTabId'], space
            assert space['proxy'] == previous['proxy'] and space['tls'] == previous['tls'], space
            assert len(space['tabs']) == len(previous['tabs']) + 1, space
            assert [item for item in after if item['id'] != space['id']] == [
                item for item in before if item['id'] != space['id']], (before, after)
        else:
            assert space['name'] == 'personal' and space['proxy'] == 'direct', space
            assert space['tls']['policy'] == 'system' and len(space['tabs']) == 1, space
        assert cli('status')['observer']['tabId'] == result['displayedTabId'], result
        return space

    # A UUID with a leading letter also qualifies as a legacy Space name.
    original_id = 'A' + str(uuid.uuid4()).upper()[1:]
    original = dict(id=original_id, name='confirmation-target', proxy='direct',
                    suspended=True, deleting=False, tabs=[dict(id=str(uuid.uuid4()), url='about:blank')])
    (state / 'spaces.json').write_text(json.dumps([original]))
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
            alias = cli('space', 'create', original_id, '--proxy', 'direct')
            legacy = native('confirmation-target', 'choose')['probe']
            assert '1 个标签页' in legacy['emptyText'] and '新标签页' in legacy['emptyText'], legacy
            assert native('confirmation-target', 'resume')['probe']['dispatched']
            assert cli('space', 'info', original_id)['lifecycle'] == 'active'
            assert native('confirmation-target', 'delete')['errorSheet']
            assert cli('space', 'delete', original_id)['dataStoreRemoved']
            confirmed = native('', 'sheet', button='删除 Space')
            assert 'Space 不存在' in confirmed['probe']['sheetText'] and confirmed['message'] is None, confirmed
            assert cli('space', 'info', alias['id'])['id'] == alias['id']
            cli('space', 'delete', alias['id'])
            native('')
            for policy, options in [(0, {}), (1, {'ca-cert': '/tmp/fixture-ca.pem'}),
                                    (2, {'ignore-certificate-errors': 'true'})]:
                form = native('', policy=str(policy))['form']
                assert form['progressAndRetry'], form
                assert form['options'] == dict(proxy='direct', **options), form
                assert form['enabledWithoutCA'] == (policy != 1), form
            assert native('')['probe']['addressEnabled']
            assert native('', 'submit-address', url=base)['probe']['dispatched']
            personal = cli('space', 'info', 'personal')
            assert personal['proxy'] == 'direct' and personal['tls']['policy'] == 'system' and len(personal['tabs']) == 1, personal
            tab_id = personal['tabs'][0]['tabId']
            def wait_display(url):
                for _ in range(80):
                    state = cli('space', 'info', 'personal')
                    result = native('')
                    if result['displayedURL'] == url and not state['busy'] and not state['tabs'][0]['loading']:
                        return result
                    time.sleep(.05)
                raise AssertionError((url, result, state))
            first_page = wait_display(base)
            assert first_page['displayedTabId'] == tab_id and first_page['probe']['addressDisplay'] == base.rsplit('/', 1)[0], first_page
            second_url = base + '?second'
            assert native('', 'submit-address', url=second_url)['probe']['dispatched']
            wait_display(second_url)
            assert native('', 'history-back')['probe']['dispatched']
            assert wait_display(base)['probe']['canGoForward']
            assert native('', 'history-forward')['probe']['dispatched']
            wait_display(second_url)
            find = native('', 'show-find')['probe']
            assert find['dispatched'] and find['findVisible'], find
            for query, expected in [('Save', '已找到'), ('nonexistent-phrase-for-page-search', '未找到')]:
                feedback = native('', 'type-find', text=query)['probe']['findFeedback']
                deadline = time.monotonic() + 5
                while expected not in feedback and time.monotonic() < deadline:
                    feedback = native('')['probe']['findFeedback']
                assert expected in feedback, (query, feedback)
            cli('space', 'delete', personal['id'])
            assert not native('')['probe']['findVisible']
            first = cli('space', 'create', 'search-a', '--proxy', 'direct')
            second = cli('space', 'create', 'search-b', '--proxy', 'direct')
            for space in (first, second):
                cli('open', base + '?space=' + space['name'], '--space', space['id'], '--tab', space['tabs'][0]['tabId'])
            search('', first, [first, second])
            search('search-b', first, [second])
            search('no-match', first, [])
            search('no-match', first, [], 'choose')
            before = cli('space', 'list')
            assert not native('no-match', 'delete')['probe']['dispatched']
            assert native('no-match', 'create-space')['errorSheet']
            assert native('no-match', 'sheet', button='取消')['probe']['dispatched']
            blocked = native('no-match', 'new-tab')
            assert not blocked['canCreateTab'] and blocked['query'] == 'no-match', blocked
            assert cli('space', 'list') == before
            assert native('no-match', 'create-from-search')['errorSheet']
            assert native('no-match', 'sheet', button='取消')['probe']['dispatched']
            search('no-match', first, [first, second], 'clear')
            search('search-b', second, [second], 'search-return' if env.get('BROWSER_TEST_FOREGROUND') == '1' else 'choose')
            search('', second, [first, second])
            search('search-', second, [first, second], 'choose')
            search('search-', first, [first, second], 'select-row', row='0')
            new_tab(first)
            personal = cli('space', 'create', 'personal', '--proxy', 'direct', '--ignore-certificate-errors')
            native('personal', 'choose')
            new_tab(personal)
            native('search-b', 'choose')
            selected = native('search-b', 'new-tab')
            assert selected['selectedSpaceId'] == second['id'] and selected['query'] == '', selected
            assert cli('space', 'info', second['id'])['tabs'][0]['tabId'] == second['tabs'][0]['tabId']

            # A visible target's busy state must disable the native command too.
            native('personal', 'choose')
            waiting = subprocess.Popen([str(binary), 'wait', '#never-created', '--timeout', '1500',
                                        '--space', personal['id'], '--tab', personal['tabs'][0]['tabId']], env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            try:
                for _ in range(100):
                    if cli('space', 'info', personal['id'])['busy']:
                        break
                    assert waiting.poll() is None, 'Wait finished before busy state was observed'
                    time.sleep(.01)
                else:
                    raise AssertionError('Space never became busy')
                personal_tab = personal['tabs'][0]['tabId']
                assert not native('personal', 'close', tab=personal_tab)['probe']['dispatched']
                busy = native('personal', 'new-tab')
                assert not busy['canCreateTab'] and not busy['errorSheet'], busy
                assert busy['query'] == 'personal' and busy['selectedSpaceId'] == personal['id'], busy
                assert len(cli('tab', 'list', '--space', personal['id'])) == 2
            finally:
                output, errors = waiting.communicate(timeout=5)
                assert waiting.returncode == 1 and json.loads(output)['error']['code'] == 'timeout', (output, errors)

            # Failed persistence must keep the search and roll back the added Tab.
            permissions = state.stat().st_mode & 0o777
            try:
                state.chmod(0o500)
                failed = native('personal', 'new-tab')
                assert failed['errorSheet'] and failed['probe']['sheetText'] and failed['query'] == 'personal', failed
                assert failed['selectedSpaceId'] == personal['id']
                assert len(cli('tab', 'list', '--space', personal['id'])) == 2
            finally:
                state.chmod(permissions)
            new_tab(personal)
            limited = native('personal', 'new-tab')
            assert limited['errorSheet'] and limited['probe']['sheetText'] and limited['query'] == 'personal', limited
            assert len(cli('tab', 'list', '--space', personal['id'])) == 3
            assert native('personal', 'sheet', button=limited['probe']['buttons'][0])['probe']['dispatched']
            deferred = cli('space', 'create', 'test-deferred', '--proxy', 'direct')
            native('test-deferred', 'choose')
            assert native('test-deferred', 'delete')['errorSheet']
            pending = native('test-deferred', 'sheet', button='删除 Space')
            assert '仍待清理' in pending['message'] and '1 待清理' in pending['spaceCount'], pending
            assert pending['selectedSpaceId'] == first['id'] and pending['sidebarSpaceId'] is None
            assert deferred['id'] not in pending['savedTabSpaces'], pending
            assert cli('status')['pendingStores'] == [dict(spaceId=deferred['id'], name='test-deferred')]
            assert cli('space', 'delete', deferred['id'])['dataStoreRemoved']
            # Only an actually empty model should create the first personal Space.
            native('')
            for space in cli('space', 'list'):
                cli('space', 'delete', space['id'])
            new_tab(None)
            verify_observer_hig(cli, native, base)
            verify_observer_regressions(cli, native, base)
            verify_observer_protection(cli, native, binary, env, base, events)
            if env.get('BROWSER_TEST_FOREGROUND') == '1':
                assert all(not row['probe']['simulatedKey'] for row in results if row['action'] in ('cmd-w', 'shift-cmd-w'))
            else:
                assert cli('status')['frontmostPid'] == frontmost, 'Native actions changed the foreground app'
        finally:
            download_gate.set()
            failed = sys.exc_info()[0] is not None
            try:
                if env.get('BROWSER_TEST_FOREGROUND') == '1' and daemon and daemon.poll() is None:
                    native('', 'release-foreground')
            finally:
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
