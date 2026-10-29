"""Opt-in standalone cross-origin frame spike; never connects to a user's daemon."""
import http.server
import json
from pathlib import Path
import plistlib
import socket
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    out = ROOT / '.artifacts' / time.strftime('cross-origin-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    nonce = uuid.uuid4().hex
    origins = {}
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            role = self.path.split('?', 1)[0].strip('/')
            if role not in ('root', 'child', 'leaf'):
                self.send_error(404); return
            frames = (f'<iframe id="one" src="{origins["B"]}/child"></iframe>'
                      f'<iframe id="two" src="{origins["B"]}/child"></iframe>') if role == 'root' else (
                      f'<iframe id="nested" src="{origins["A"]}/leaf"></iframe>' if role == 'child' else '')
            html = f'''<!doctype html><meta charset="utf-8"><body data-role="{role}">
<label>Frame input<input id="same"></label><button id="save">Save once</button><output id="ack"></output>{frames}
<script>
window.inputTrusted=null;
document.querySelector('#same').addEventListener('input',e=>window.inputTrusted=e.isTrusted);
document.querySelector('#save').onclick=async()=>{{
 const value=document.querySelector('#same').value;
 const response=await fetch('/save',{{method:'POST',headers:{{'Content-Type':'application/json'}},body:JSON.stringify({{value}})}});
 window.saved=await response.json();document.querySelector('#ack').textContent=saved.nonce;
}};
</script>'''.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(html)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers(); self.wfile.write(html)

        def do_POST(self):
            if self.path != '/save':
                self.send_error(404); return
            value = json.loads(self.rfile.read(int(self.headers['Content-Length'])))['value']
            event = dict(value=value, nonce=nonce, originPort=self.server.server_address[1])
            requests.append(event)
            with (out / 'requests.jsonl').open('a') as stream:
                stream.write(json.dumps(event) + '\n')
            body = json.dumps(dict(value=value, nonce=nonce)).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body)

    servers = []
    try:
        for name in ('A', 'B'):
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            servers.append(server)
            origins[name] = f'http://127.0.0.1:{server.server_address[1]}'
            threading.Thread(target=server.serve_forever, daemon=True).start()
        app = out / 'Frame Probe.app'
        executable = app / 'Contents/MacOS/frame-probe'
        executable.parent.mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier='local.agent-webkit.frame-probe', CFBundleExecutable='frame-probe',
            CFBundlePackageType='APPL', CFBundleName='Frame Probe',
            NSAppTransportSecurity=dict(NSAllowsArbitraryLoadsInWebContent=True))))
        command = ['swiftc', '-parse-as-library', str(ROOT / 'Sources/Browser/DOM.swift'),
                   str(ROOT / 'Sources/Browser/Protocol.swift'), str(ROOT / 'Sources/Browser/Execution.swift'),
                   str(ROOT / 'Sources/Browser/Timing.swift'),
                   str(ROOT / 'tests/cross_origin_probe.swift'), '-o', str(executable)]
        build = subprocess.run(command, capture_output=True, text=True, timeout=90)
        (out / 'build.log').write_text(build.stdout + build.stderr)
        assert build.returncode == 0, f'Probe build failed; see {out / "build.log"}'
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        runs = []
        for mode, host in [('ports', '127.0.0.1'), ('hosts', 'localhost')]:
            origins['B'] = f'http://{host}:{servers[1].server_address[1]}'
            start = len(requests)
            native = out / f'native-{mode}.json'
            with (out / f'probe-{mode}.log').open('w') as log:
                process = subprocess.run([str(executable), origins['A'], origins['B'], str(native)],
                                         stdout=log, stderr=log, timeout=90)
            result = json.loads(native.read_text())
            assert process.returncode == 0 and result['ok'], f'Probe failed: {result["error"]}; see {native}'
            received = requests[start:]
            assert len(received) == 2 and {r['value'] for r in received} == {'cross-child', 'nested-leaf'}, received
            assert all(r['nonce'] == nonce for r in received)
            assert next(r for r in received if r['value'] == 'cross-child')['originPort'] == servers[1].server_address[1]
            assert next(r for r in received if r['value'] == 'nested-leaf')['originPort'] == servers[0].server_address[1]
            acknowledgements = [e for e in result['events'] if e['kind'] == 'business-result']
            assert len(acknowledgements) == 2, acknowledgements
            for acknowledgement in acknowledgements:
                actual = acknowledgement['value']
                expected = next(r for r in received if r['value'] == actual['value'])
                assert actual == dict(value=expected['value'], nonce=expected['nonce']), acknowledgement
                registration = next(e for e in result['events'] if e['kind'] == 'registered'
                                    and e['epoch'] == acknowledgement['epoch'] and e['slot'] == acknowledgement['slot'])
                role, depth = ('child', 1) if actual['value'] == 'cross-child' else ('leaf', 2)
                assert acknowledgement['slot'] == 'A1' and registration['role'] == role and registration['depth'] == depth, acknowledgement
            result.update(mode=mode, origins=dict(origins), independentPOSTs=received)
            runs.append(result)
        report = dict(ok=True, runs=runs, probeOnly=True,
                      system=subprocess.check_output(['sw_vers'], text=True), artifacts=str(out))
    finally:
        for server in servers:
            server.shutdown(); server.server_close()
        for origin in origins.values():
            port = int(origin.rsplit(':', 1)[1])
            with socket.socket() as client:
                assert client.connect_ex(('127.0.0.1', port)) != 0, 'Fixture server still accepts connections'
    report['fixtureCleanupVerified'] = True
    (out / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(dict(ok=True, checks=sum(len(run['checks']) for run in runs), report=str(out / 'report.json'))))


if __name__ == '__main__':
    main()
