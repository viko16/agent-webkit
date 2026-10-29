"""Opt-in public AppKit/WebKit background-input experiment, outside the product."""
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


def verify_observations(report, requests, nonce):
    samples = {sample['label']: sample['state'] for sample in report['samples']}

    def check(condition, label):
        assert condition, label
        report['checks'].append(label)

    for route in ('synthetic', 'window', 'view', 'hit-test'):
        for suffix in ('', '-outside'):
            state = samples[f'{route}-hover{suffix}']
            check(not state['hover'] and state['color'] == 'rgb(200, 20, 20)' and state['menu'] == 'none',
                  f'{route}{suffix}: CSS hover and menu remain inactive')
            check(state['activation'] == dict(active=False, sticky=False), f'{route}{suffix}: movement grants no activation')
        events = samples[f'{route}-hover']['events']
        check(len(events) == (4 if route == 'synthetic' else 0) and all(not e['trusted'] for e in events),
              f'{route}: distinguish synthetic listeners from undelivered native mouse movement')
    outcomes = {'enter': ('alpha beta', [10, 10], 'first'), 'tab': ('alpha beta', [10, 10], 'second'),
                'escape': ('alpha beta', [10, 10], 'first'), 'shift-left': ('alpha beta', [9, 10], 'first'),
                'option-left': ('alpha beta', [6, 6], 'first'), 'control-b': ('alpha beta', [9, 9], 'first'),
                'command-a': ('alpha beta', [10, 10], 'first'), 'shift-x': ('alpha betaX', [11, 11], 'first')}
    for route in ('synthetic', 'window', 'view', 'responder'):
        for name, expected in outcomes.items():
            label = f'{route}-{name}'
            state = samples[label]
            keys = [e for e in state['events'] if e['type'] in ('keydown', 'keyup')]
            native = route != 'synthetic'
            check([e['type'] for e in keys] == ['keydown', 'keyup'] and all(e['trusted'] == native for e in keys),
                  f'{label}: event delivery and trust observed')
            check(all(e['activation']['active'] == (native and name != 'escape') for e in keys),
                  f'{label}: event-time activation independent of JS evaluation')
            for field, prefix in [('shift', 'shift-'), ('alt', 'option-'), ('ctrl', 'control-'), ('meta', 'command-')]:
                check(all(e[field] == name.startswith(prefix) for e in keys), f'{label}: {field} flag preserved')
            actual = (state['value'], state['selected'], state['activeElement'])
            check(actual == (expected if native else ('alpha beta', [10, 10], 'first')), f'{label}: default result {actual}')
            check(not state['modal'] and not state['documentFocused'], f'{label}: modal outcome and background focus')
            if name == 'escape':
                check(any(e['type'] == 'cancel' and e['trusted'] for e in state['events']),
                      f'{label}: dialog cancellation observed separately from key trust')
    equivalent = samples['equivalent-command-a']
    check(equivalent['selected'] == [10, 10] and any(e['meta'] for e in equivalent['events']),
          'performKeyEquivalent consumes Command-A but does not select all in this hidden host')
    check(samples['window-cancel-tab']['activeElement'] == 'first', 'preventDefault suppresses native Tab traversal')
    fill, click = samples['product-fill'], samples['product-click']
    check(fill['value'] == 'product-value' and any(e['type'] == 'input' and not e['trusted'] and e['activation']['active'] for e in fill['events']),
          'product fill remains synthetic despite JS-evaluation activation')
    check(any(e['type'] == 'click' and not e['trusted'] for e in click['events'])
          and any(e['type'] == 'submit' and e['trusted'] for e in click['events']),
          'trusted submit event does not prove a trusted initiating click')
    expected_labels = {'window-enter', 'view-enter', 'responder-enter', 'product-fill'}
    acknowledgements = [e for e in report['messages'] if e['kind'] == 'business-result']
    check(len(requests) == len(acknowledgements) == 4 and {r['label'] for r in requests} == expected_labels,
          'exactly three native Enter submissions and one product DOM click submission')
    for acknowledgement in acknowledgements:
        ack = acknowledgement['saved']
        check(ack in requests and ack['nonce'] == nonce and ack['slot'] == acknowledgement['hostSlot'] == 'A1'
              and ack['epoch'] == acknowledgement['epoch'] and ack['label'] == acknowledgement['label']
              and ack['value'] == ('product-value' if ack['label'] == 'product-fill' else 'alpha beta'),
              f'{ack["label"]}: real POST and page acknowledgement match value/nonce/document/Tab')
    report['capabilities'] = dict(
        hover=dict(backgroundVerified=False, requiresForeground=True,
                   reason='No CSS hover through the tested public routes in hidden panels; manual foreground fallback only'),
        keyboard=dict(backgroundVerified=True, physicalInput=False,
                      verified=['Enter', 'Tab', 'Escape', 'Shift-Left', 'Option-Left', 'Control-B', 'Shift-X'],
                      limitation='Command-A flags delivered but select-all not verified; no general IME/shortcut support'))


def main():
    out = ROOT / '.artifacts' / time.strftime('input-probe-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    nonce = uuid.uuid4().hex
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path.split('?', 1)[0] != '/input-probe.html':
                self.send_error(404); return
            body = (ROOT / 'tests/site/input-probe.html').read_bytes()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers(); self.wfile.write(body)

        def do_POST(self):
            if self.path != '/save':
                self.send_error(404); return
            event = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            event['nonce'] = nonce
            requests.append(event)
            with (out / 'requests.jsonl').open('a') as stream:
                stream.write(json.dumps(event) + '\n')
            body = json.dumps(event).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body)

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        app = out / 'Input Probe.app'
        binary = app / 'Contents/MacOS/input-probe'
        binary.parent.mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier='local.agent-webkit.input-probe', CFBundleExecutable='input-probe',
            CFBundlePackageType='APPL', CFBundleName='Input Probe',
            NSAppTransportSecurity=dict(NSAllowsArbitraryLoadsInWebContent=True))))
        command = ['swiftc', '-parse-as-library', *[str(ROOT / f'Sources/Browser/{name}.swift')
                   for name in ('DOM', 'Protocol', 'Execution', 'Timing')],
                   str(ROOT / 'tests/input_probe.swift'), '-o', str(binary)]
        build = subprocess.run(command, capture_output=True, text=True, timeout=90)
        (out / 'build.log').write_text(build.stdout + build.stderr)
        assert build.returncode == 0, f'Build failed; see {out / "build.log"}'
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        with (out / 'probe.log').open('w') as log:
            process = subprocess.run([str(binary), f'http://127.0.0.1:{port}', str(out / 'native.json')],
                                     stdout=log, stderr=log, timeout=120)
        report = json.loads((out / 'native.json').read_text())
        assert process.returncode == 0 and report['ok'], report.get('error')
        verify_observations(report, requests, nonce)
        report.update(independentPOSTs=requests, fixtureOrigin=f'http://127.0.0.1:{port}', nativeProcessExited=True,
                      system=subprocess.check_output(['sw_vers'], text=True), artifacts=str(out))
    finally:
        server.shutdown(); server.server_close()
        with socket.socket() as client:
            assert client.connect_ex(('127.0.0.1', port)) != 0, 'Fixture port still accepts connections'
    report['fixtureCleanupVerified'] = True
    (out / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(dict(ok=True, checks=len(report['checks']), report=str(out / 'report.json'))))


if __name__ == '__main__':
    main()
