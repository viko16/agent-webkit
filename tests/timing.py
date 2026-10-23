"""Validate real timing boundaries and navigation waits against a delayed local origin."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import time
import uuid

from fixtures import origin

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket')
    args = parser.parse_args()
    spaces = ['timing-' + uuid.uuid4().hex[:10] for _ in range(2)]
    created = []
    site, _ = origin()
    url = f'http://127.0.0.1:{site.server_address[1]}/index.html'
    count = 0

    def cli(*arguments, ok=True):
        nonlocal count
        command = [str(ROOT / '.build/debug/browser'), *arguments]
        if args.socket:
            command += ['--socket', args.socket]
        start = time.perf_counter_ns()
        process = subprocess.run(command, capture_output=True, text=True, timeout=80)
        external = (time.perf_counter_ns() - start) / 1_000_000
        response = json.loads(process.stdout)
        assert response['ok'] == ok and (process.returncode == 0) == ok, response
        timing = response['timing']
        # These nested intervals use one host's monotonic clock, with no precision rounding.
        assert external >= timing['cliMs'] >= timing['ipcRoundTripMs'] >= timing['serverMs'] >= timing['webkitMs'] >= 0, (arguments, external, timing)
        count += 1
        return response

    def operation(response, name):
        return next(item for item in response['timing']['webkitOperations'] if item['operation'] == name)

    try:
        for space in spaces:
            cli('space', 'create', space, '--proxy', 'direct')
            created.append(space)
        with ThreadPoolExecutor(2) as pool:
            futures = [pool.submit(cli, 'open', url + '?delay=0.25', '--space', space) for space in spaces]
            for future in futures:
                response = future.result()
                assert response['timing']['webkitMs'] >= 250, response
                assert operation(response, 'navigation')['inProgress'] == 0
        space = spaces[0]
        cli('snapshot', '--space', space)
        cli('evaluate', 'throw new Error("timing-error")', '--space', space, ok=False)
        cli('evaluate', '({invalid: Infinity})', '--space', space, ok=False)
        cli('fill', '#message', 'timed', '--space', space)
        # A DOM button without navigation must time out, not report the previous load as new.
        response = cli('click', '#save', '--space', space, '--wait-for-navigation', '--timeout', '150', ok=False)
        assert response['error']['code'] == 'timeout', response
        assert response['timing']['serverMs'] >= 150
        cli('evaluate', f'(() => {{ const a=document.createElement("a"); a.id="next"; a.href={json.dumps(url + "?delay=0.25&next=1")}; a.textContent="next"; document.body.append(a); return true; }})()', '--space', space)
        response = cli('click', '#next', '--space', space, '--wait-for-navigation', '--timeout', '5000')
        assert 'next=1' in response['result']['page']['url'] and not response['result']['page']['loading'], response
        assert response['timing']['webkitMs'] >= 250, response
        assert operation(response, 'navigation')['inProgress'] == 0
        response = cli('open', url + '?delay=0.5&timeout=1', '--space', space, '--timeout', '100', ok=False)
        assert response['error']['code'] == 'timeout', response
        assert operation(response, 'navigation')['inProgress'] == 1, response
        assert response['timing']['webkitMs'] >= 100, response
        cli('wait', '--space', space)
        # A navigation completing after timeout must not be charged to the next request.
        response = cli('evaluate', 'document.title', '--space', space)
        assert all(item['operation'] != 'navigation' for item in response['timing']['webkitOperations']), response
        path = ROOT / '.artifacts' / 'timing-test.png'
        response = cli('screenshot', '--space', space, '--out', str(path))
        assert operation(response, 'takeSnapshot')['totalMs'] > 0
        assert path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
        cli('snapshot', '--space', space, '--wait-for-navigation', ok=False)
        print(json.dumps({'ok': True, 'checks': count, 'verified': [
            'nested timing intervals', 'parallel per-space navigation attribution', 'JS error timing',
            'no-navigation timeout', 'click waits for delayed destination', 'open timeout preserves in-progress timing',
            'no late-span leakage into next request', 'real PNG snapshot', 'flag validation'
        ]}, ensure_ascii=False))
    finally:
        for space in created:
            cli('space', 'delete', space)
        site.shutdown(); site.server_close()


if __name__ == '__main__':
    main()
