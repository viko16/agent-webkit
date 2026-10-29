"""Real native download limits, restart accounting and acknowledged cancellation."""
import http.server
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit

from skill_workflow import cleanup_test_services, verify_cleanup


ROOT = Path(__file__).resolve().parents[1]


def fixture_app(out):
    app = out / 'Download Limits.app'
    binary = app / 'Contents/MacOS/browser'
    binary.parent.mkdir(parents=True)
    info = plistlib.loads((ROOT / 'packaging/Info.plist').read_bytes())
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    sources = []
    for path in sorted((ROOT / 'Sources/Browser').glob('*.swift')):
        copied = out / path.name
        source = path.read_text()
        if path.name == 'Files.swift':
            marker = '    private static func scan(_ root: URL) throws -> Usage {\n'
            assert source.count(marker) == 1
            source = source.replace(marker, marker + '''        if ProcessInfo.processInfo.environment["BROWSER_TEST_SLOW_BUDGET_SCAN"] == "1" {
            fputs("BUDGET-SCAN\\n", stderr)
            Thread.sleep(forTimeInterval: 2)
        }
''')
        copied.write_text(source)
        sources.append(str(copied))
    build = subprocess.run(['swiftc', '-g', *sources, '-o', str(binary)], capture_output=True, text=True, timeout=120)
    (out / 'build.log').write_text(build.stdout + build.stderr)
    assert build.returncode == 0, f'Fixture build failed; see {out / "build.log"}'
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    return binary


def download_site():
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if urlsplit(self.path).path == '/blob':
                query = parse_qs(urlsplit(self.path).query)
                size = int(query.get('bytes', ['1024'])[0])
                stream = 'stream' in query
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Disposition', 'attachment; filename="payload.bin"')
                if not stream:
                    self.send_header('Content-Length', str(size))
                self.end_headers()
                try:
                    for offset in range(0, size, 4096):
                        self.wfile.write(b'x' * min(4096, size - offset))
                        self.wfile.flush()
                        if stream:
                            time.sleep(.03)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            else:
                body = b'<a id="small" href="/blob?bytes=1024">small</a><a id="large" href="/blob?bytes=65536">large</a><a id="stream" href="/blob?bytes=1048576&stream=1">stream</a>'
                self.send_response(200)
                self.send_header('Content-Type', 'text/html')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers(); self.wfile.write(body)

        def log_message(self, *args):
            pass

    site = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=site.serve_forever, daemon=True).start()
    return site


def run_case(case, configured, out, binary):
    state = Path(tempfile.mkdtemp(prefix='aw-limit-'))
    settings = dict(MAX_FILE_BYTES=2097152, MAX_SPACE_BYTES=4194304, MAX_TOTAL_BYTES=8388608, MIN_FREE_BYTES=0)
    settings.update(configured)
    env = dict(os.environ, BROWSER_DATA_DIR=str(state), BROWSER_SOCKET=str(state / 'browser.sock'),
               **{'BROWSER_DOWNLOAD_' + key: str(value) for key, value in settings.items()})
    if case == 'responsive':
        env['BROWSER_TEST_SLOW_BUDGET_SCAN'] = '1'
    site = download_site()
    base = f'http://127.0.0.1:{site.server_port}/'
    daemon = None
    created = []

    def cli(*args):
        process = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=15)
        response = json.loads(process.stdout)
        assert process.returncode == 0 and response['ok'], (args, response, process.stderr)
        return response['result']

    with (out / (case + '-daemon.log')).open('w') as log:
        def start():
            nonlocal daemon
            daemon = subprocess.Popen([str(binary), 'daemon'], env=env, stdout=log, stderr=log)
            for _ in range(100):
                assert daemon.poll() is None, 'Test app exited'
                if (state / 'browser.sock').exists():
                    try:
                        if cli('status')['ready']:
                            return
                    except (AssertionError, json.JSONDecodeError):
                        pass
                time.sleep(.05)
            raise AssertionError('Startup timed out')

        def stop():
            cli('shutdown', '--all')
            assert daemon.wait(timeout=15) == 0

        def begin(selector, space='limit-a'):
            before = {item['id'] for item in cli('download', 'list', '--space', space)['value']['downloads']}
            cli('click', selector, '--space', space)
            for _ in range(100):
                items = cli('download', 'list', '--space', space)['value']['downloads']
                new = [item for item in items if item['id'] not in before]
                if new:
                    return new[0]['id']
                time.sleep(.02)
            raise AssertionError('No native download')

        def wait(download, space='limit-a'):
            return cli('download', 'wait', download, '--space', space)['value']

        def assert_failed(item, code):
            assert item['status'] == 'failed' and item['error'] == code, item
            assert item['path'] is None and item['cleanupError'] is None, item
            assert not list((state / 'downloads').glob('*/*/' + item['id']))

        try:
            start()
            for name in ('limit-a', 'limit-b'):
                created.append(cli('space', 'create', name, '--proxy', 'direct'))
                cli('open', base, '--space', name)
            limits = cli('download', 'list', '--space', 'limit-a')['value']['limits']
            assert limits == dict(fileBytes=settings['MAX_FILE_BYTES'], spaceBytes=settings['MAX_SPACE_BYTES'],
                                  totalBytes=settings['MAX_TOTAL_BYTES'], minFreeBytes=settings['MIN_FREE_BYTES'])
            completed = None
            if case == 'file':
                assert_failed(wait(begin('#large')), 'download_file_limit')
                assert_failed(wait(begin('#stream')), 'download_file_limit')
                completed = wait(begin('#small'))
            elif case in ('space', 'total'):
                completed = wait(begin('#small'))
                assert completed['status'] == 'completed', completed
                stop(); start()
                cli('wait', '#small', '--space', 'limit-a')
                cli('wait', '#small', '--space', 'limit-b')
                destination = 'limit-a' if case == 'space' else 'limit-b'
                assert_failed(wait(begin('#small', destination), destination), 'download_' + case + '_limit')
                if case == 'space':
                    assert wait(begin('#small', 'limit-b'), 'limit-b')['status'] == 'completed'
            elif case == 'disk':
                assert_failed(wait(begin('#small')), 'download_disk_limit')
            elif case == 'responsive':
                first = begin('#small')
                second = begin('#stream', 'limit-b')
                log_path = out / (case + '-daemon.log')
                assert log_path.read_text().count('BUDGET-SCAN') == 1
                folder = state / 'downloads' / created[1]['id'] / created[1]['defaultTabId'] / second
                assert not folder.exists(), 'Destination must wait for the budget scan'
                with ThreadPoolExecutor(1) as pool:
                    pending = pool.submit(cli, 'download', 'cancel', second, '--space', 'limit-b')
                    began = time.monotonic()
                    assert cli('evaluate', 'document.querySelector("#small").textContent', '--space', 'limit-a')['value'] == 'small'
                    response_seconds = time.monotonic() - began
                    assert response_seconds < 1, response_seconds
                    cancelled = pending.result()['value']
                assert cancelled['status'] == 'cancelled' and cancelled['cleanupError'] is None, cancelled
                completed = wait(first)
                time.sleep(.15)
                assert not folder.exists(), 'A late scan recreated the cancelled destination'
            elif case == 'cancel':
                completed = wait(begin('#small'))
                download = begin('#stream')
                folder = state / 'downloads' / created[0]['id'] / created[0]['defaultTabId'] / download
                for _ in range(100):
                    if folder.exists():
                        break
                    time.sleep(.02)
                assert folder.exists()
                cancelled = cli('download', 'cancel', download.lower(), '--space', 'limit-a')['value']
                assert cancelled['status'] == 'cancelled' and cancelled['cleanupError'] is None, cancelled
                assert not folder.exists()
            if completed:
                assert completed['status'] == 'completed', completed
                path = Path(completed['path'])
                assert path.read_bytes() == b'x' * 1024
                stop(); start()
                assert path.read_bytes() == b'x' * 1024
            # Leave no pending container to mask a successful test cleanup.
            for space in cli('space', 'list'):
                assert cli('space', 'delete', space['id'])['websiteDataRemoved']
            stop(); start()
            assert cli('status')['pendingStoreCleanup'] == 0
        finally:
            failed = sys.exc_info()[0] is not None
            errors = cleanup_test_services(cli, daemon, site)
            if errors:
                (out / (case + '-cleanup-errors.json')).write_text(json.dumps([str(error) for error in errors]))
                if not failed:
                    raise AssertionError('Download limit cleanup failed') from errors[0]
    verify_cleanup(state)
    result = dict(case=case, passed=True, limits=limits, stateDirectory=str(state))
    if case == 'responsive':
        result.update(peerResponseSeconds=response_seconds, initialSharedScans=1,
                      cancelledDestinationRemainsAbsent=True)
    return result


def main():
    out = ROOT / '.artifacts' / time.strftime('download-limits-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    binary = fixture_app(out)
    cases = [('file', dict(MAX_FILE_BYTES=32768)),
             ('space', dict(MAX_SPACE_BYTES=1536)),
             ('total', dict(MAX_TOTAL_BYTES=1536)),
             ('disk', dict(MIN_FREE_BYTES=9223372036854775807)),
             ('cancel', {}), ('responsive', {})]
    results = [run_case(case, settings, out, binary) for case, settings in cases]
    report = dict(passed=True, cases=results, completedFilesRetained=True,
                  restartAccounting=True, unknownLengthStreamBounded=True, cancellationAcknowledged=True)
    report['sharedBackgroundScanAndLateCancellation'] = True
    (out / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(dict(report=str(out / 'report.json'), passed=True)))


if __name__ == '__main__':
    main()
