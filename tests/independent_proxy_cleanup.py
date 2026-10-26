"""Inject an unavailable browser IPC and verify real Whistle resources are released."""
import json
import os
from pathlib import Path
import signal
import socket
import tempfile
import urllib.parse

from fixtures import origin
from independent_proxy_cases import verify_independent_proxies
from whistle_fixture import WhistleFixture


def main():
    out = Path(tempfile.mkdtemp(prefix='awk-proxy-cleanup-'))
    site, events = origin()
    whistle = WhistleFixture(out, site.server_address[1])
    instance_b = out / 'independent-proxies/whistle-instance.json'

    def unavailable_cli(*args, **kwargs):
        raise RuntimeError('Injected browser IPC failure')

    try:
        whistle.start()
        try:
            verify_independent_proxies(out, unavailable_cli, None, whistle, site, events)
        except RuntimeError as error:
            assert str(error) == 'Injected browser IPC failure', error
        else:
            raise AssertionError('The IPC failure must remain visible')
        instance = json.loads(instance_b.read_text())
        ports = [urllib.parse.urlsplit(instance['url']).port,
                 urllib.parse.urlsplit(instance['rules'].splitlines()[0].split()[1]).port]
        for port in ports:
            with socket.socket() as probe:
                probe.settimeout(1)
                assert probe.connect_ex(('127.0.0.1', port)) != 0, f'Leaked listener: {port}'
        report = json.loads((out / 'independent-proxies/report.json').read_text())
        assert not report['passed'] and report['proxyBStopped'], report
        print(json.dumps({'passed': True, 'releasedPorts': ports, 'out': str(out)}))
    finally:
        # Rescue only the process group recorded by this test if the regression returns.
        if instance_b.exists():
            pid = json.loads(instance_b.read_text())['pid']
            try:
                os.killpg(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        whistle.close()
        site.shutdown(); site.server_close()


if __name__ == '__main__':
    main()
