"""Use the installed real Whistle, with temporary process-only rules and isolated storage."""
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request


class WhistleFixture:
    def __init__(self, out, origin_port, existing=False, port=None):
        self.out = Path(out)
        self.process = None
        self.log = None
        self.existing = existing
        self.port = port if port is not None else (8899 if existing else 0)
        self.state = None
        self.rules = f'example.com http://127.0.0.1:{origin_port}\nexample.com enable://capture'
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.ca_path = self.out / 'whistle-ca.pem'

    @property
    def url(self):
        return f'http://127.0.0.1:{self.port}'

    def start(self):
        if not self.existing:
            with socket.socket() as probe:
                try:
                    probe.bind(('127.0.0.1', self.port))
                    self.port = probe.getsockname()[1]
                except OSError:
                    raise RuntimeError(f'{self.port} 已被占用；不会停止或修改已有服务。省略 --whistle-port 可自动选择空闲端口。')
            executable = shutil.which('whistle') or shutil.which('w2')
            if not executable:
                raise RuntimeError('找不到已安装的 whistle / w2；测试不会自动安装，请确认依赖后重试')
            state = Path(tempfile.mkdtemp(prefix='awk-whistle-'))
            self.state = state
            certificates = state / 'certificates'
            certificates.mkdir(mode=0o700)
            # Whistle's --baseDir isolates rules, but its default CA is shared globally.
            # Use a fresh process-local CA so pre-existing keychain trust cannot mask TLS errors.
            result = subprocess.run([
                'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '2',
                '-subj', '/CN=Agent WebKit Whistle Fixture CA', '-keyout', str(certificates / 'root.key'),
                '-out', str(certificates / 'root.crt'), '-addext', 'basicConstraints=critical,CA:TRUE',
                '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
            ], capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError('生成测试 CA 失败：' + result.stderr)
            self.log = open(self.out / 'whistle.log', 'w')
            self.process = subprocess.Popen([
                executable, 'run', '--port', str(self.port), '--host', '127.0.0.1',
                '--baseDir', str(state), '--storage', 'agent-webkit-test',
                '--certDir', str(certificates),
                '--rcPath', str(state / '.whistlerc'), '--no-global-plugins', '--no-prev-options',
                '--mode', 'capture|prod', '--shadowRules', self.rules,
            ], env=dict(os.environ, WHISTLE_PATH=str(state)),
                stdout=self.log, stderr=self.log, start_new_session=True)
            (self.out / 'whistle-instance.json').write_text(json.dumps({
                'pid': self.process.pid, 'url': self.url, 'state': str(state),
                'certificates': str(certificates), 'rules': self.rules,
            }, indent=2))
        for _ in range(150):
            if self.process and self.process.poll() is not None:
                raise RuntimeError('Whistle 启动失败，见 whistle.log')
            try:
                with self.http.open(self.url + '/cgi-bin/rootca?type=pem', timeout=2) as response:
                    self.ca_path.write_bytes(response.read())
                return self
            except OSError:
                time.sleep(.1)
        raise RuntimeError('Whistle 启动或读取根证书超时')

    def sessions(self):
        with self.http.open(self.url + '/cgi-bin/get-data?startTime=0&count=1000', timeout=5) as response:
            data = json.load(response)
        (self.out / 'whistle-sessions.json').write_text(json.dumps(data, indent=2))
        return list(data['data']['data'].values())

    def close(self):
        if self.process and self.process.poll() is None:
            # `whistle run` spawns its server child. Stop our entire private process group.
            os.killpg(self.process.pid, signal.SIGTERM)
            self.process.wait(timeout=15)
            for _ in range(30):
                try:
                    with socket.create_connection(('127.0.0.1', self.port), timeout=.2):
                        pass
                except OSError:
                    break
                time.sleep(.1)
            else:
                raise RuntimeError(f'Whistle process exited but {self.port} is still listening; cannot claim an offline-proxy test')
        if self.log:
            self.log.close()
