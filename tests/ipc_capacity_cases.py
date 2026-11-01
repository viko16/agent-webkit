"""Real socket saturation, request completion and client-only routing options."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

from contract_cases import verify_live_contract
from fixtures import origin
from skill_workflow import cleanup_test_services, verify_cleanup


ROOT = Path(__file__).resolve().parents[1]


def verify_capacity(cli, path):
    def raw(command, args=None, options=None):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(5)
            client.connect(str(path))
            client.sendall(json.dumps(dict(command=command, args=args or [], options=options or {})).encode() + b'\n')
            return json.loads(client.makefile('rb').readline())

    with ThreadPoolExecutor(1) as pool, ExitStack() as stack:
        accepted = pool.submit(raw, 'evaluate', ['new Promise(r=>setTimeout(()=>r("accepted"),1200))'],
                               {'space': 'work', 'await': 'true', 'timeout': '3000'})
        for _ in range(100):
            if cli('space', 'info', 'work')['busy']:
                break
            time.sleep(.01)
        else:
            raise AssertionError('No accepted in-flight request')
        for _ in range(31):
            client = stack.enter_context(socket.socket(socket.AF_UNIX))
            client.settimeout(5)
            client.connect(str(path))
            client.sendall(b'{')
        busy = raw('status')
        assert busy['ok'] is False and busy['error']['code'] == 'server_busy', busy
        response = accepted.result(timeout=5)
        assert response['ok'] and response['result']['value'] == 'accepted', response
        assert raw('status')['ok'], 'Completed request did not release its connection slot'
    for _ in range(100):
        if raw('status')['ok']:
            break
        time.sleep(.01)
    else:
        raise AssertionError('Capacity did not recover after clients disconnected')
    return dict(passed=True, incompleteConnectionsBounded=True, structuredBusyError=True,
                acceptedRequestCompletes=True, slotsReleasedAfterReplyAndDisconnect=True)


def main():
    out = ROOT / '.artifacts' / time.strftime('ipc-capacity-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    state = Path(tempfile.mkdtemp(prefix='aw-ipc-'))
    env = dict(os.environ, BROWSER_DATA_DIR=str(state), BROWSER_SOCKET=str(state / 'browser.sock'))
    binary = ROOT / '.build/debug/awb'
    app = ROOT / '.build/Agent WebKit.app/Contents/MacOS/awb'
    site, _ = origin()
    daemon = None

    def cli(*args):
        process = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=15)
        response = json.loads(process.stdout)
        assert process.returncode == 0 and response['ok'], (args, response, process.stderr)
        return response['result']

    with (out / 'daemon.log').open('w') as log:
        try:
            daemon = subprocess.Popen([str(app), 'daemon'], env=env, stdout=log, stderr=log)
            for _ in range(100):
                assert daemon.poll() is None, 'Test daemon exited'
                if (state / 'browser.sock').exists():
                    try:
                        if cli('status')['ready']:
                            break
                    except (AssertionError, OSError, json.JSONDecodeError):
                        pass
                time.sleep(.05)
            else:
                raise AssertionError('Startup timed out')
            cli('space', 'create', 'work', '--proxy', 'direct')
            cli('open', f'http://127.0.0.1:{site.server_address[1]}/index.html', '--space', 'work')
            # Existing contract cases include error expectations; adapt without hiding failures.
            def contract_cli(*args, error=None):
                process = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=15)
                response = json.loads(process.stdout)
                assert process.returncode == (1 if error else 0) and response['ok'] == (error is None), (args, response)
                if error:
                    assert response['error']['code'] == error, response
                    return response
                return response['result']
            contract = verify_live_contract(contract_cli, state / 'browser.sock')
            result = verify_capacity(cli, state / 'browser.sock')
        finally:
            failed = sys.exc_info()[0] is not None
            errors = cleanup_test_services(cli, daemon, site)
            if errors:
                (out / 'cleanup-errors.json').write_text(json.dumps([str(error) for error in errors]))
                if not failed:
                    raise AssertionError('IPC test cleanup failed') from errors[0]
    verify_cleanup(state)
    report = dict(passed=True, contract=contract, capacity=result, clientRoutingRejectedOverIPC=True)
    (out / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(dict(passed=True, report=str(out / 'report.json'))))


if __name__ == '__main__':
    main()
