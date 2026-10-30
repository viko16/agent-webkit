"""Real concurrent downloads; only the sampled-scan return is fault-injected."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit

from skill_workflow import cleanup_test_services, verify_cleanup


def wait_until(predicate, message, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.005)
    raise AssertionError(message)


def concurrent_case(out, binary, *, same_space, known_length, stale_scan=False, unreadable=False):
    name = ('same' if same_space else 'cross') + ('-known' if known_length else '-stream')
    name += '-stale-scan' if stale_scan else '-unreadable' if unreadable else ''
    out = out / name
    out.mkdir()
    state = Path(tempfile.mkdtemp(prefix='aw-budget-'))
    gate = threading.Event()
    sampled_gate = out / 'scan-gate'
    sampled_gate.mkdir()
    size, cap = 80 * 1024, 100 * 1024

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if urlsplit(self.path).path == '/blob':
                query = parse_qs(urlsplit(self.path).query)
                length = int(query.get('bytes', [str(size)])[0])
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Disposition', 'attachment; filename="payload.bin"')
                if known_length:
                    self.send_header('Content-Length', str(length))
                self.end_headers()
                try:
                    # First bytes let WebKit choose its destination. The remaining
                    # body waits until both downloads have been admitted.
                    self.wfile.write(b'x' * min(4096, length)); self.wfile.flush()
                    if length > 4096:
                        assert gate.wait(15), 'Host did not release response body'
                    for offset in range(4096, length, 4096):
                        self.wfile.write(b'x' * min(4096, length - offset)); self.wfile.flush()
                        if not stale_scan:
                            time.sleep(.025)  # Deliberate fixture transfer rate.
                except (BrokenPipeError, ConnectionResetError):
                    pass
            else:
                body = b'<a id="download" href="/blob">download</a><a id="small" href="/blob?bytes=1024">small</a>'
                self.send_response(200); self.send_header('Content-Type', 'text/html')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers(); self.wfile.write(body)

        def log_message(self, *args):
            pass

    site = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=site.serve_forever, daemon=True).start()
    env = dict(os.environ, BROWSER_DATA_DIR=str(state), BROWSER_SOCKET=str(state / 'browser.sock'),
               BROWSER_DOWNLOAD_MAX_FILE_BYTES=str(size), BROWSER_DOWNLOAD_MIN_FREE_BYTES='0',
               BROWSER_DOWNLOAD_MAX_SPACE_BYTES=str(cap if same_space else 4 * cap),
               BROWSER_DOWNLOAD_MAX_TOTAL_BYTES=str(4 * cap if same_space else cap))
    if stale_scan:
        env['BROWSER_TEST_SCAN_GATE'] = str(sampled_gate)
    log_path = out / 'daemon.log'
    log = log_path.open('w')
    daemon = None
    sampling_done = threading.Event()
    samples = []
    sampler = None
    denied = None

    def cli(*args):
        process = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=15)
        response = json.loads(process.stdout)
        with (out / 'commands.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(args=args, response=response)) + '\n')
        assert process.returncode == 0 and response['ok'], (args, response, process.stderr)
        return response['result']

    def sample():
        while not sampling_done.is_set():
            total = 0
            for path in (state / 'downloads').glob('*/*/*/*'):
                try:
                    total += path.stat().st_size
                except FileNotFoundError:
                    pass
            samples.append((time.monotonic(), total))
            sampling_done.wait(.005)

    def begin(flags, selector='#download'):
        previous = {item['id'] for item in cli('download', 'list', *flags)['value']['downloads']}
        cli('click', selector, *flags)
        found = []

        def appeared():
            found[:] = [item for item in cli('download', 'list', *flags)['value']['downloads'] if item['id'] not in previous]
            return bool(found)

        wait_until(appeared, 'No real native download')
        return found[0]['id']

    result = None
    try:
        daemon = subprocess.Popen([str(binary), 'daemon'], env=env, stdout=log, stderr=log)
        wait_until(lambda: daemon.poll() is not None or (state / 'browser.sock').exists(), 'No daemon socket')
        assert daemon.poll() is None, log_path.read_text()
        wait_until(lambda: cli('status')['ready'], 'Daemon not ready')
        targets = []
        for index in range(2):
            name_space = 'budget-a' if same_space or index == 0 else 'budget-b'
            if not same_space or index == 0:
                tab = cli('space', 'create', name_space, '--proxy', 'direct')['defaultTabId']
            else:
                tab = cli('tab', 'new', '--space', name_space)['tabId']
            flags = ('--space', name_space, '--tab', tab)
            cli('open', f'http://127.0.0.1:{site.server_port}/', *flags)
            targets.append(flags)
        if unreadable:
            # A real inaccessible subtree, not a mocked scan error. The first
            # download has never scanned this data directory, so no cache applies.
            denied = state / 'downloads' / 'unreadable'
            denied.mkdir(parents=True)
            (denied / 'retained.bin').write_bytes(b'retained')
            denied.chmod(0)
            download = begin(targets[0], '#small')
            failed = cli('download', 'wait', download, *targets[0])['value']
            assert failed['status'] == 'failed' and failed['error'] == 'download_budget_unavailable', failed
            assert failed['path'] is None and failed['cleanupError'] is None, failed
            denied.chmod(0o700)
            recovered = cli('download', 'wait', begin(targets[0], '#small'), *targets[0])['value']
            assert recovered['status'] == 'completed' and Path(recovered['path']).read_bytes() == b'x' * 1024, recovered
            result = dict(case=name, passed=True, inaccessibleDirectoryRejected=True, recoveredAfterPermissionsRestored=True)
        else:
            ids = [begin(flags) for flags in targets]
            wait_until(lambda: len(list((state / 'downloads').glob('*/*/*'))) == 2, 'Both destinations were not admitted')
            sampler = threading.Thread(target=sample, daemon=True); sampler.start()
            if stale_scan:
                (sampled_gate / 'armed').touch()
                wait_until(lambda: (sampled_gate / 'sampled').exists(), 'No shared scan captured partial files')
            gate.set()
            if stale_scan:
                wait_until(lambda: log_path.read_text().count('DOWNLOAD-FINISH') >= 2, 'Both real finish callbacks did not arrive')
                (sampled_gate / 'release').touch()
            terminals = [cli('download', 'wait', download, *flags)['value'] for download, flags in zip(ids, targets)]
            all_terminal_at = time.monotonic()
            sampling_done.set(); sampler.join()
            limit_error = 'download_space_limit' if same_space else 'download_total_limit'
            assert any(item['status'] == 'failed' and item['error'] == limit_error for item in terminals), terminals
            retained = 0
            for item in terminals:
                assert item['cleanupError'] is None and item['bytesReceived'] <= size, item
                if item['status'] == 'completed':
                    assert Path(item['path']).read_bytes() == b'x' * size
                    retained += size
                else:
                    assert item['status'] == 'failed' and item['error'] == limit_error and item['path'] is None, item
                    assert not list((state / 'downloads').glob('*/*/' + item['id']))
            assert retained <= cap, terminals
            # A follow-up transfer proves the failed download no longer consumes
            # quota. Ordinary admission intentionally caches usage for 100 ms;
            # allow that documented cache lifetime after confirmed cleanup.
            time.sleep(.1)
            small = cli('download', 'wait', begin(targets[0], '#small'), *targets[0])['value']
            assert small['status'] == 'completed' and Path(small['path']).read_bytes() == b'x' * 1024, small
            assert cli('evaluate', 'document.querySelector("#small").textContent', *targets[1])['value'] == 'small'
            exceeded = [instant for instant, count in samples if count > cap]
            recovered_at = next((instant for instant, count in samples if exceeded and instant > exceeded[0] and count <= cap), None)
            result = dict(case=name, passed=True, knownLength=known_length, sameSpace=same_space,
                          delayedScanReturn=stale_scan, limitBytes=cap, sampledPeakBytes=max(count for _, count in samples),
                          retainedBytes=retained, quotaReleased=True, peerUsable=True, terminals=terminals,
                          sampleIntervalSeconds=.005,
                          excessToAllTerminalSeconds=(all_terminal_at - exceeded[0]) if exceeded else None,
                          excessToObservedRecoverySeconds=(recovered_at - exceeded[0]) if recovered_at is not None else None)
        # Public deletion can leave an empty container pending; restart cleanup
        # is already covered by download_limit_cases, and cleanup below verifies
        # every owned Space has actually had its website data removed.
    finally:
        failed = sys.exc_info()[0] is not None
        gate.set(); (sampled_gate / 'release').touch(); sampling_done.set()
        if sampler is not None:
            sampler.join(timeout=2)
        if denied is not None:
            denied.chmod(0o700)
        errors = cleanup_test_services(cli, daemon, site)
        log.close()
        if errors:
            (out / 'cleanup-errors.json').write_text(json.dumps([str(error) for error in errors]))
            if not failed:
                raise AssertionError('Concurrent download cleanup failed') from errors[0]
    verify_cleanup(state)
    (out / 'report.json').write_text(json.dumps(result, indent=2))
    return result


def verify_concurrent_budgets(out, binary):
    cases = [dict(same_space=same, known_length=known) for same in (False, True) for known in (False, True)]
    cases.extend([dict(same_space=False, known_length=True, stale_scan=True),
                  dict(same_space=False, known_length=True, unreadable=True)])
    return [concurrent_case(out, binary, **case) for case in cases]


if __name__ == '__main__':
    from download_limit_cases import ROOT, fixture_app
    out = ROOT / '.artifacts' / time.strftime('download-budgets-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    results = verify_concurrent_budgets(out, fixture_app(out))
    (out / 'report.json').write_text(json.dumps(dict(passed=True, cases=results), indent=2))
    print(json.dumps(dict(passed=True, report=str(out / 'report.json'))))
