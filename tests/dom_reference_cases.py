"""Real WebKit bounded-reference stress and document/context isolation regression."""
import json
from pathlib import Path
import plistlib
import socket
import subprocess
import time

from fixtures import origin


ROOT = Path(__file__).resolve().parents[1]


def main():
    out = ROOT / '.artifacts' / time.strftime('dom-references-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    app = out / 'DOM Reference Probe.app'
    binary = app / 'Contents/MacOS/dom-reference-probe'
    binary.parent.mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier='local.agent-webkit.dom-reference-probe', CFBundleExecutable=binary.name,
        CFBundlePackageType='APPL', NSAppTransportSecurity=dict(NSAllowsArbitraryLoadsInWebContent=True))))
    sources = [str(path) for path in sorted((ROOT / 'Sources/Browser').glob('*.swift')) if path.name != 'main.swift']
    command = ['swiftc', '-parse-as-library', '-module-cache-path', str(ROOT / '.build/probe-module-cache'),
               *sources, str(ROOT / 'tests/dom_reference_probe.swift'), '-o', str(binary)]
    build = subprocess.run(command, capture_output=True, text=True, timeout=120)
    (out / 'build.log').write_text(build.stdout + build.stderr)
    assert build.returncode == 0, f'Build failed; see {out / "build.log"}'
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    server, _ = origin()
    port = server.server_address[1]
    try:
        with (out / 'probe.log').open('w') as log:
            process = subprocess.run([str(binary), f'http://127.0.0.1:{port}', str(out / 'native.json')],
                                     stdout=log, stderr=log, timeout=90)
        report = json.loads((out / 'native.json').read_text())
        assert process.returncode == 0 and report['ok'], report
    finally:
        server.shutdown(); server.server_close()
        with socket.socket() as client:
            assert client.connect_ex(('127.0.0.1', port)) != 0, 'Fixture still accepts connections'
    report.update(fixtureCleanupVerified=True, artifacts=str(out))
    (out / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(dict(ok=True, checks=len(report['checks']), report=str(out / 'report.json'))))


if __name__ == '__main__':
    main()
