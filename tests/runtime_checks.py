"""Isolated real-process termination/observer checks, or Release CLI timing samples."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import signal
import socket
import statistics
import subprocess
import tempfile
import time
import uuid

from fixtures import origin
from skill_workflow import cleanup_test_services, verify_cleanup

ROOT = Path(__file__).resolve().parents[1]


def eventually(read, accept, seconds=10):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = read()
        if accept(value):
            return value
        time.sleep(.05)
    raise AssertionError(f'Condition not reached: {value}')


class Runtime:
    def __init__(self, out, binary):
        self.out, self.binary = out, binary
        self.state = Path(tempfile.mkdtemp(prefix='aw-runtime-'))
        self.env = dict(os.environ, BROWSER_DATA_DIR=str(self.state), BROWSER_SOCKET=str(self.state / 'browser.sock'))
        self.site, self.events = origin()
        self.base = f'http://127.0.0.1:{self.site.server_address[1]}/index.html'
        self.daemon = None
        self.log = (out / 'daemon.log').open('w')
        self.rows = []

    def command(self, *args, error=None, sample=None):
        start = time.perf_counter_ns()
        process = subprocess.run([str(self.binary), *args], env=self.env, capture_output=True, text=True, timeout=70)
        elapsed = (time.perf_counter_ns() - start) / 1e6
        response = json.loads(process.stdout)
        row = dict(args=args, response=response, cliEndToEndMs=elapsed, sample=sample)
        self.rows.append(row)
        with (self.out / 'commands.jsonl').open('a') as stream:
            stream.write(json.dumps(row, ensure_ascii=False) + '\n')
        assert process.returncode == (1 if error else 0) and response['ok'] == (error is None), row
        if error:
            assert response['error']['code'] == error, row
            return response
        return response['result']

    def start(self, executable, *args):
        self.daemon = subprocess.Popen([str(executable), *args], env=self.env, stdout=self.log, stderr=self.log)
        for _ in range(200):
            assert self.daemon.poll() is None, f'Host exited; see {self.log.name}'
            if (self.state / 'browser.sock').exists() and self.command('status')['ready']:
                return
            time.sleep(.05)
        raise AssertionError('Host startup timed out')

    def page(self, space, tab, *args, **kwargs):
        return self.command(*args, '--space', space, '--tab', tab, **kwargs)

    def gui(self, action='capture', **values):
        request = dict(id=uuid.uuid4().hex, action=action, **values)
        pending = self.out / 'gui-request.tmp'
        pending.write_text(json.dumps(request))
        pending.replace(self.out / 'gui-request.json')
        def read():
            try:
                return json.loads((self.out / 'gui-response.json').read_text())
            except FileNotFoundError:
                return {}
        result = eventually(read, lambda r: r.get('id') == request['id'])
        assert result['ok'], result
        assert not result['activated'] and not result['foregroundChanged'] and not result['key'], result
        if values.get('capture') == 'true':
            subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(result['windowNumber']),
                            str(self.out / f'gui-{request["id"]}.png')], check=True, capture_output=True, timeout=10)
        (self.out / f'gui-{request["id"]}.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
        return result

    def content_processes(self):
        assert self.daemon.poll() is None
        # launchd's PID domain identifies this host's XPC services, unlike global name matching.
        result = subprocess.run(['launchctl', 'print', f'pid/{self.daemon.pid}'], capture_output=True, text=True, check=True)
        services = re.search(r'\n\s*services = \{(.*?)\n\s*\}', result.stdout, re.S)
        assert services, 'Cannot establish host XPC ownership'
        rows = re.findall(r'^\s*(\d+)\s+\S+\s+(com\.apple\.WebKit\.WebContent\S*)\s*$', services[1], re.M)
        return {int(pid): name for pid, name in rows if int(pid) > 0}

    def terminate_content(self, pid):
        owned = self.content_processes()
        assert pid in owned and pid != self.daemon.pid, (pid, owned)
        executable = subprocess.check_output(['ps', '-p', str(pid), '-o', 'comm='], text=True).strip()
        assert '/WebKit.framework/' in executable and '/com.apple.WebKit.WebContent' in executable, executable
        evidence = dict(hostPID=self.daemon.pid, targetPID=pid, service=owned[pid], executable=executable)
        with (self.out / 'terminations.jsonl').open('a') as stream:
            stream.write(json.dumps(evidence) + '\n')
        os.kill(pid, signal.SIGKILL)
        return evidence

    def close(self):
        errors = cleanup_test_services(self.command, self.daemon, self.site)
        self.log.close()
        if errors:
            raise AssertionError([str(error) for error in errors])
        if (self.state / 'spaces.json').exists():
            verify_cleanup(self.state)
        with socket.socket() as client:
            assert client.connect_ex(self.site.server_address) != 0, 'Fixture still listening'


def build_host(out):
    app = out / 'Termination Host.app'
    binary = app / 'Contents/MacOS/termination-host'
    binary.parent.mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier='local.agent-webkit.termination-test', CFBundleExecutable=binary.name,
        CFBundlePackageType='APPL', NSAppTransportSecurity=dict(NSAllowsArbitraryLoadsInWebContent=True))))
    sources = [str(p) for p in sorted((ROOT / 'Sources/Browser').glob('*.swift')) if p.name != 'main.swift']
    result = subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(ROOT / '.build/probe-module-cache'),
                             *sources, str(ROOT / 'tests/termination_host.swift'), '-o', str(binary)],
                            capture_output=True, text=True, timeout=180)
    (out / 'build.log').write_text(result.stdout + result.stderr)
    assert result.returncode == 0, f'Build failed: {out / "build.log"}'
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    return binary


def termination(runtime):
    r = runtime
    host = build_host(r.out)
    r.start(host, str(r.state), str(r.out))
    peer = r.command('space', 'create', 'peer', '--proxy', 'direct')['defaultTabId']
    r.page('peer', peer, 'open', r.base)
    r.page('peer', peer, 'evaluate', 'window.peerSentinel=73;true')
    before = r.content_processes()
    victim = r.command('space', 'create', 'victim', '--proxy', 'direct')['defaultTabId']
    r.page('victim', victim, 'open', r.base)
    r.gui('select', space='victim')
    page = lambda *args, **kwargs: r.page('victim', victim, *args, **kwargs)
    page('evaluate', 'document.cookie="termination=kept;Max-Age=3600;Path=/";localStorage.termination="kept";true')
    checks = []
    with ThreadPoolExecutor(1) as pool:
        for mode in ['idle', 'pending-js', 'dialog', 'navigation']:
            candidates = eventually(r.content_processes, lambda p: len(set(p) - set(before)) == 1)
            pid, = set(candidates) - set(before)
            frame_id = page('frame', 'list')['value']['frames'][0]['frameId']
            snapshot = page('snapshot')['value']
            reference = next(e['ref'] for e in snapshot['elements'] if e['tag'] == 'input')
            future = None
            dialog_id = None
            if mode == 'pending-js':
                source = 'fetch("/keyboard-save",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({marker:"termination-once"})}).then(()=>new Promise(()=>{}))'
                future = pool.submit(page, 'evaluate', source, '--await', '--timeout', '30000', error='web_content_terminated')
                eventually(lambda: list(r.events.items), lambda events: any(e.get('marker') == 'termination-once' for e in events))
            elif mode == 'dialog':
                future = pool.submit(page, 'evaluate', 'confirm("termination fixture")', '--timeout', '30000', error='web_content_terminated')
                pending = eventually(lambda: page('dialog', 'list')['value'], lambda value: bool(value['dialogs']))
                dialog_id = pending['dialogs'][0]['id']
            elif mode == 'navigation':
                future = pool.submit(page, 'open', r.base + '?delay=3', '--timeout', '30000', error='web_content_terminated')
                eventually(lambda: page('state'), lambda state: state['page']['loading'])
                loading = r.gui(capture='true')
                assert loading['progressVisible'] and ('处理' in loading['status'] or '加载' in loading['status']), loading
            if future:
                assert not future.done(), 'Operation completed before fault injection'
            started = time.monotonic()
            evidence = r.terminate_content(pid)
            eventually(lambda: page('state'), lambda state: state['page']['webContentTerminated'])
            if future:
                future.result(timeout=8)
            assert time.monotonic() - started < 8, 'Pending operation waited for the full deadline'
            page('snapshot', error='web_content_terminated')
            failed = r.gui(capture='true')
            assert failed['bannerVisible'] and '进程已退出' in failed['banner'] and failed['retryEnabled'], failed
            assert r.page('peer', peer, 'evaluate', 'window.peerSentinel')['value'] == 73
            assert not page('dialog', 'list')['value']['dialogs']
            # Exercise the actual native recovery button once; other cases use the production CLI.
            before = r.content_processes()
            before.pop(pid, None)
            if mode == 'idle':
                r.gui('reload')
                eventually(lambda: page('state'), lambda state: not state['page']['webContentTerminated'] and not state['page']['loading'])
                page('wait', '#message')
            else:
                page('reload')
            recovered = r.gui(capture='true')
            assert not recovered['bannerVisible'] and not recovered['progressVisible'], recovered
            state = page('state')['page']
            assert state['tabId'] == victim and not state['webContentTerminated'], state
            data = page('evaluate', '({cookie:document.cookie,local:localStorage.termination})')['value']
            assert 'termination=kept' in data['cookie'] and data['local'] == 'kept', data
            page('click', reference, error='stale_ref')
            page('snapshot', '--frame', frame_id, error='stale_frame')
            checks.append(dict(mode=mode, termination=evidence, failedGUI=failed, recoveredGUI=recovered, dialogID=dialog_id))
        assert len([e for e in r.events.items if e.get('marker') == 'termination-once']) == 1, 'A side effect was replayed'
    # Termination classification must not swallow genuine script or serialization errors.
    page('evaluate', 'throw new Error("still a script error")', error='javascript_error')
    page('evaluate', 'document.body', error='operation_failed')
    assert page('evaluate', 'Promise.resolve(42)', '--await')['value'] == 42
    hidden = r.gui('hide')
    assert not hidden['visible']
    page('snapshot')
    page('screenshot', '--out', str(r.out / 'hidden-page.png'))
    assert not r.gui()['visible'], 'Background commands reopened the observer'
    assert r.gui('show')['visible']
    return dict(checks=checks, backgroundAfterClose=True, noSideEffectReplay=True,
                hostBinarySHA256=hashlib.sha256(host.read_bytes()).hexdigest(),
                scope='Real SIGKILL; product browser/socket/observer sources in a separately signed test host. GUI actions and native view assertions are automated, not manual interaction.')


def summary(values):
    values = sorted(values)
    return dict(n=len(values), median=statistics.median(values), p95=values[math.ceil(len(values) * .95) - 1], min=values[0], max=values[-1])


def benchmark(runtime, count):
    r = runtime
    app_binary = ROOT / '.build/Agent WebKit.app/Contents/MacOS/awb'
    def build_ids(binary):
        output = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(binary)], text=True)
        ids = set(re.findall(r'UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)', output))
        assert ids, f'Cannot identify build: {binary}'
        return ids
    # Ad-hoc signing changes file bytes, but preserves the linked Mach-O UUID.
    assert build_ids(app_binary) == build_ids(ROOT / '.build/release/awb'), 'Build/package the matching Release binary first'
    r.start(app_binary, 'daemon')
    tab = r.command('space', 'create', 'timing', '--proxy', 'direct')['defaultTabId']
    page = lambda *args, **kwargs: r.page('timing', tab, *args, **kwargs)
    page('open', r.base)
    foreground = r.command('status')['frontmostPid']
    workflows = []
    for iteration in range(-3, count):
        measured = iteration >= 0
        start_index = len(r.rows)
        start = time.perf_counter_ns()
        for label, args in [('state', ('state',)), ('snapshot', ('snapshot',)),
                            ('fill', ('fill', '#message', f'sample-{iteration}')),
                            ('click', ('click', '#save')), ('wait', ('wait', '#result', '--text', f'sample-{iteration}')),
                            ('evaluate', ('evaluate', 'document.querySelector("#result").textContent'))]:
            value = page(*args, sample=label if measured else None)
            if label == 'evaluate':
                assert value['value'] == f'sample-{iteration}'
        elapsed = (time.perf_counter_ns() - start) / 1e6
        if measured:
            workflows.append(dict(wallMs=elapsed, commandMs=sum(row['cliEndToEndMs'] for row in r.rows[start_index:]),
                                  outsideIPCMs=sum(row['cliEndToEndMs'] - row['response']['timing']['ipcRoundTripMs'] for row in r.rows[start_index:])))
        page('open', r.base + '?delay=0.25', sample='navigation-250ms' if measured else None)
        page('screenshot', '--out', str(r.out / 'benchmark-page.png'), sample='screenshot' if measured else None)
    assert r.command('status')['frontmostPid'] == foreground
    groups = {}
    for row in r.rows:
        if not row['sample']:
            continue
        timing = row['response']['timing']
        external = row['cliEndToEndMs']
        assert external >= timing['cliMs'] >= timing['ipcRoundTripMs'] >= timing['serverMs'] >= timing['webkitMs'] >= 0, row
        values = dict(cliEndToEndMs=external, **{key: timing[key] for key in ['cliMs', 'ipcRoundTripMs', 'serverMs', 'webkitMs']},
                      outsideMainMs=external - timing['cliMs'], outsideIPCMs=external - timing['ipcRoundTripMs'])
        group = groups.setdefault(row['sample'], {})
        for key, value in values.items():
            group.setdefault(key, []).append(value)
    return dict(samplesPerCommand=count, warmupIterations=3,
                commands={label: {key: summary(values) for key, values in group.items()} for label, group in groups.items()},
                workflow={key: summary([row[key] for row in workflows]) for key in workflows[0]},
                workflows=workflows, definitions={
                    'outsideMainMs': 'End-to-end minus cliMs: process loading, final encoding/output/exit, parent collection and scheduling; NOT pure process startup.',
                    'outsideIPCMs': 'End-to-end minus IPC roundtrip: optimistic removable client/process overhead, NOT a measured batching speedup.',
                    'workflow': 'Six CLI commands: state, snapshot, fill, click, wait, evaluate. Wall time includes driver validation/log writes; commandMs excludes these.',
                    'scope': 'Warm local fixture, one Release daemon, repeated CLI processes. No LLM latency, public network, true cold-cache benchmark or implemented batch endpoint.'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['termination', 'timing'])
    parser.add_argument('--samples', type=int, default=30)
    args = parser.parse_args()
    if args.samples < 5:
        parser.error('--samples must be at least 5')
    out = ROOT / '.artifacts' / f'{args.mode}-{time.strftime("%Y%m%d-%H%M%S")}'
    out.mkdir(parents=True)
    binary = ROOT / '.build/Agent WebKit.app/Contents/MacOS/awb'
    report = dict(ok=False, artifacts=str(out), macOS=platform.mac_ver()[0],
                  architecture=platform.machine(), binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  sourceSHA256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in sorted((ROOT / 'Sources/Browser').glob('*.swift'))},
                  commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                  version=json.loads(subprocess.check_output([str(binary), 'version'], text=True))['result']['version'])
    runtime = Runtime(out, binary)
    try:
        report.update(termination(runtime) if args.mode == 'termination' else benchmark(runtime, args.samples))
    except BaseException as error:
        report['error'] = repr(error)
        raise
    finally:
        try:
            runtime.close()
            report['cleanupVerified'] = True
        except BaseException as error:
            report['cleanupError'] = repr(error)
            raise
        finally:
            report['ok'] = 'error' not in report and 'cleanupError' not in report
            (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
            print(json.dumps(dict(ok=report['ok'], report=str(out / 'report.json')), ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
