"""Diagnostic matrix. Keeps failures visible; it does not replace acceptance B."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from fixtures import origin, proxy

root = Path(__file__).resolve().parents[1]
state = tempfile.mkdtemp(prefix='awk-probe-')
env = dict(os.environ, BROWSER_DATA_DIR=state)
server, origin_events = origin()
relay, events = proxy()
binary = str(root / '.build/debug/browser')
daemon = subprocess.Popen([str(root / '.build/Agent WebKit.app/Contents/MacOS/browser'), 'daemon'], env=env, stdout=subprocess.DEVNULL)

def cli(*args):
    result = subprocess.run([binary, *args], env=env, text=True, capture_output=True, timeout=70)
    return json.loads(result.stdout)

try:
    for _ in range(100):
        if Path(state, 'browser.sock').exists():
            break
        time.sleep(.1)
    print(cli('space','create','probe','--proxy','http://127.0.0.1:8899'), flush=True)
    port = server.server_address[1]
    for url in [f'http://127.0.0.1:{port}',f'http://localhost:{port}',f'https://127.0.0.1:{port}',f'https://localhost:{port}', 'https://example.com']:
        before = len(events.items)
        result = cli('open',url,'--space','probe','--timeout','3000')
        print(json.dumps({'url':url,'response':result,'proxyEvents':events.items[before:]}, ensure_ascii=False), flush=True)
finally:
    print(cli('space','delete','probe'), flush=True)
    cli('shutdown')
    daemon.wait(timeout=15)
    server.shutdown(); relay.shutdown()
