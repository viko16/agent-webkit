"""Production CLI regression for explicit cross-origin document targets."""
from contextlib import contextmanager
import http.server
import json
import socket
import threading
import time
from urllib.parse import urlsplit
import uuid


@contextmanager
def frame_site(host):
    origins, requests, servers = {}, [], []
    nonce = uuid.uuid4().hex

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            role = urlsplit(self.path).path.strip('/') or 'root'
            children = (f'<iframe id="one" src="{origins["B"]}/child"></iframe>'
                        f'<iframe id="two" src="{origins["B"]}/child"></iframe>') if role == 'root' else (
                        f'<iframe id="nested" src="{origins["A"]}/leaf"></iframe>' if role == 'child' else '')
            if role == 'many':
                children = ''.join(f'<iframe src="{origins["B"]}/leaf?n={i}"></iframe>' for i in range(132))
            body = f'''<!doctype html><meta charset="utf-8"><title>{role}</title>
<label>{role} input<input id="same"></label><button id="save">Save</button>
<button id="replace" onclick="const el=document.querySelector('#same');el.replaceWith(el.cloneNode())">Replace</button>
<button id="spa" onclick="history.pushState(null,'','?spa=1')">SPA</button>
<button id="navigate" onclick="location.href='/replacement'">Navigate</button>
<button id="back" onclick="history.back()">Back</button>
<button id="slow" onclick="setTimeout(()=>document.querySelector('#ack').textContent='later',250)">Later</button>
<button id="hang" onclick="while(true){{}}">Hang</button>
<button id="popup" onclick="window.open('/leaf','_blank')">Popup</button>
<button id="clear-nested" onclick="document.querySelector('#nested').remove()">Remove nested</button>
<output id="ack"></output><p id="privacy"></p>{children}<script>
addEventListener('pageshow',e=>window.restoredFromCache=e.persisted);
window.inputTrusted=null;document.querySelector('#same').oninput=e=>window.inputTrusted=e.isTrusted;
document.querySelector('#privacy').textContent=typeof window.__agentWebKitFrame==='undefined' &&
 typeof window.webkit?.messageHandlers?.agentWebKitFrames==='undefined'?'isolated':'exposed';
document.querySelector('#save').onclick=async()=>{{
 const value=document.querySelector('#same').value;
 const response=await fetch('/save',{{method:'POST',body:JSON.stringify({{value,role:{json.dumps(role)},trusted:window.inputTrusted}})}});
 const ack=await response.json();document.querySelector('#ack').textContent=ack.nonce;
}};
</script>'''.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'max-age=60' if role in ('cached', 'replacement') else 'no-store')
            self.end_headers(); self.wfile.write(body)

        def do_POST(self):
            event = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            event.update(nonce=nonce, originPort=self.server.server_address[1])
            requests.append(event)
            body = json.dumps(event).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body)

    try:
        for name, hostname in [('A', '127.0.0.1'), ('B', host)]:
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            servers.append(server)
            origins[name] = f'http://{hostname}:{server.server_address[1]}'
            threading.Thread(target=server.serve_forever, daemon=True).start()
        yield origins, requests, nonce
    finally:
        for server in servers:
            server.shutdown(); server.server_close()
            with socket.socket() as client:
                assert client.connect_ex(server.server_address) != 0, 'Frame fixture still listening'


def verify_frames(cli, out, restart):
    initial = cli('status')
    evidence = []
    for host in ['127.0.0.1', 'localhost']:
        with frame_site(host) as (origins, requests, nonce):
            a = cli('space', 'create', 'frames-a', '--proxy', 'direct')
            b = cli('space', 'create', 'frames-b', '--proxy', 'direct')
            tab = a['defaultTabId']
            peer = b['defaultTabId']

            def command(*args, frame=None, target=tab, space='frames-a', **kwargs):
                options = ['--space', space, '--tab', target]
                if frame is not None:
                    options += ['--frame', frame]
                return cli(*args, *options, **kwargs)

            def js(source):
                return command('evaluate', source)['value']

            def documents(target=tab, space='frames-a'):
                return command('frame', 'list', target=target, space=space)['value']['frames']

            def loaded(target=tab, space='frames-a'):
                for _ in range(50):
                    frames = documents(target, space)
                    if len(frames) == 5 and all(f['title'] for f in frames):
                        return frames
                    time.sleep(.05)
                raise AssertionError(('Frame registration incomplete', frames))

            try:
                if host == '127.0.0.1':
                    command('open', origins['A'] + '/cached')
                    cached_frame = documents()[0]['frameId']
                    old_snapshot = command('snapshot', frame=cached_frame)['value']
                    old_ref = next(e['ref'] for e in old_snapshot['elements'] if e['tag'] == 'input')
                    command('click', '#navigate', '--wait-for-navigation')
                    command('click', '#back', '--wait-for-navigation')
                    assert js('window.restoredFromCache') is True, 'Regression requires a real page-cache restore'
                    restored_frame = documents()[0]['frameId']
                    assert restored_frame != cached_frame
                    command('fill', old_ref, 'WRONG', frame=restored_frame, error='stale_ref')
                    restored_snapshot = command('snapshot', frame=restored_frame)['value']
                    new_ref = next(e['ref'] for e in restored_snapshot['elements'] if e['tag'] == 'input')
                    assert new_ref != old_ref, 'New snapshot revived a pre-navigation element ref'
                    command('fill', old_ref, 'WRONG', frame=restored_frame, error='stale_ref')
                    command('fill', old_ref, 'WRONG', error='stale_ref')
                command('open', origins['A'] + '/root')
                frames = loaded()
                observer = cli('status')['observer']
                assert len({f['frameId'] for f in frames}) == 5
                assert all(f['parentFrameId'] is None for f in frames)
                children = [f['frameId'] for f in frames if f['title'] == 'child']
                leaves = [f['frameId'] for f in frames if f['title'] == 'leaf']
                assert len(children) == len(leaves) == 2
                assert len({f['url'] for f in frames if f['title'] == 'child'}) == 1
                assert js('document.querySelector("#one").contentDocument===null') is True
                snapshots = {f['frameId']: command('snapshot', frame=f['frameId'])['value'] for f in frames}
                assert all('isolated' in snap['text'] and snap['textScope'] == 'selected-frame' for snap in snapshots.values())
                assert all(el['bounds']['coordinateSpace'] == 'frame-viewport' for snap in snapshots.values() for el in snap['elements'])
                child, leaf = children[0], leaves[0]
                child_ref = next(e['ref'] for e in snapshots[child]['elements'] if e['name'] == 'child input')
                command('fill', child_ref, 'child-' + host, frame=child)
                command('fill', child_ref, 'WRONG', frame=children[1], error='stale_ref')
                command('fill', child_ref, 'WRONG', error='stale_ref')
                command('click', '#save', frame=child)
                command('wait', '#ack', '--text', nonce, frame=child)
                command('fill', '#same', 'leaf-' + host, frame=leaf)
                command('click', '#save', frame=leaf)
                command('wait', '--text', nonce, frame=leaf)
                assert len(requests) == 2
                assert {(r['value'], r['role'], r['trusted'], r['nonce']) for r in requests} == {
                    ('child-' + host, 'child', False, nonce), ('leaf-' + host, 'leaf', False, nonce)}
                for role, origin in [('child', 'B'), ('leaf', 'A')]:
                    assert next(r for r in requests if r['role'] == role)['originPort'] == urlsplit(origins[origin]).port
                # Correlate the POST values with the addressed documents, including same-URL siblings.
                for item in frames:
                    snapshot = command('snapshot', frame=item['frameId'])['value']
                    actual = next(e['value'] for e in snapshot['elements'] if e['tag'] == 'input')
                    assert actual == {child: 'child-' + host, leaf: 'leaf-' + host}.get(item['frameId'], '')
                command('wait', '#missing', '--state', 'detached', frame=child)
                command('wait', '#missing', '--state', 'hidden', frame=child)
                command('wait', '#same', '--state', 'enabled', frame=child)
                command('wait', '#same', '--state', 'disabled', '--timeout', '80', frame=child, error='timeout')
                command('wait', frame=child)
                command('click', '#slow', frame=child)
                command('wait', '#ack', '--text', 'later', frame=child)
                command('click', '#spa', frame=child)
                command('wait', '--url', origins['B'] + '/child?spa=1', frame=child)
                command('fill', child_ref, 'same-document', frame=child)
                command('click', '#replace', frame=child)
                command('fill', child_ref, 'WRONG', frame=child, error='stale_ref')
                command('fill', '#same', 'new-node', frame=child)
                # Ambiguous or unsupported operations must not silently pick another scope.
                command('fill', 'button', 'WRONG', frame=child, error='selector_count')
                command('snapshot', frame='unknown', error='stale_frame')
                cli('snapshot', '--space', 'frames-a', '--frame', child, error='invalid_arguments')
                command('evaluate', 'true', frame=child, error='invalid_arguments')
                command('screenshot', '--out', '/tmp/unused-frame.png', frame=child, error='invalid_arguments')
                command('click', '#one >>> #save', error='unsupported_context')
                command('open', origins['A'] + '/root', target=peer, space='frames-b')
                loaded(peer, 'frames-b')
                second_tab = command('click', '#popup', '--wait-for-popup', frame=child)['value']['newTabId']
                command('snapshot', frame=child, target=second_tab, error='stale_frame')
                command('open', origins['A'] + '/root', target=second_tab)
                loaded(second_tab)
                for target, space in [(peer, 'frames-b'), (second_tab, 'frames-a')]:
                    command('fill', '#same', 'WRONG', frame=child, target=target, space=space, error='stale_frame')
                    for item in documents(target, space):
                        snapshot = command('snapshot', frame=item['frameId'], target=target, space=space)['value']
                        assert next(e['value'] for e in snapshot['elements'] if e['tag'] == 'input') == ''
                # A failed provisional top-level navigation leaves the old documents alive.
                with socket.socket() as unavailable:
                    unavailable.bind(('127.0.0.1', 0))
                    unavailable_port = unavailable.getsockname()[1]
                    command('open', f'http://127.0.0.1:{unavailable_port}/unreachable', error='operation_failed')
                surviving = documents()
                assert {f['frameId'] for f in surviving} == {f['frameId'] for f in frames}, 'Failed navigation lost live frame targets'
                command('wait', '#same', frame=child)
                command('fill', '#same', 'after-failed-navigation', frame=child)
                # Nested removal and parent navigation reject old documents before mutation.
                old = {f['frameId'] for f in documents()}
                command('click', '#clear-nested', frame=child)
                remaining = {f['frameId'] for f in documents()}
                removed = old - remaining
                assert len(removed) == 1 and removed <= set(leaves)
                command('fill', '#same', 'WRONG', frame=removed.pop(), error='stale_frame')
                command('click', '#navigate', frame=child)
                command('fill', '#same', 'WRONG', frame=child, error='stale_frame')
                replacement = next(f for f in documents() if f['title'] == 'replacement')
                command('wait', '#same', frame=replacement['frameId'])
                assert next(e['value'] for e in command('snapshot', frame=replacement['frameId'])['value']['elements'] if e['tag'] == 'input') == ''
                command('click', '#back', frame=replacement['frameId'])
                for _ in range(50):
                    restored = [f for f in documents() if f['url'] == origins['B'] + '/child?spa=1']
                    if restored:
                        break
                    time.sleep(.05)
                assert len(restored) == 1 and restored[0]['frameId'] != child
                command('fill', child_ref, 'WRONG', frame=restored[0]['frameId'], error='stale_ref')
                command('fill', '#same', 'WRONG', frame=child, error='stale_frame')
                descendant = next(f['frameId'] for f in documents() if f['frameId'] in leaves)
                command('click', '#navigate', frame=children[1])
                command('fill', '#same', 'WRONG', frame=descendant, error='stale_frame')
                old_documents = {f['frameId'] for f in documents() if not f['mainFrame']}
                js('document.querySelectorAll("iframe").forEach(el=>el.replaceWith(el.cloneNode()));true')
                replacements = loaded()
                assert not old_documents & {f['frameId'] for f in replacements}
                for old_id in old_documents:
                    command('fill', '#same', 'WRONG', frame=old_id, error='stale_frame')
                for item in replacements:
                    if not item['mainFrame']:
                        snapshot = command('snapshot', frame=item['frameId'])['value']
                        assert next(e['value'] for e in snapshot['elements'] if e['tag'] == 'input') == ''
                # Registration order does not identify #one versus #two.
                before_remove = [f['frameId'] for f in documents() if not f['mainFrame']]
                js('document.querySelectorAll("iframe").forEach(el=>el.remove());true')
                for removed_id in before_remove:
                    command('snapshot', frame=removed_id, error='stale_frame')
                before_reload = [f['frameId'] for f in documents()]
                command('reload')
                loaded()
                for old_id in before_reload:
                    command('fill', '#same', 'WRONG', frame=old_id, error='stale_frame')
                before_suspend = documents()[0]['frameId']
                cli('space', 'suspend', 'frames-a')
                command('snapshot', frame=before_suspend, error='stale_frame')
                fresh = loaded()[0]['frameId']
                restart()
                command('snapshot', frame=fresh, error='stale_frame')
                fresh_frames = loaded()
                hung = next(f['frameId'] for f in fresh_frames if f['title'] == 'leaf')
                began = time.monotonic()
                command('click', '#hang', '--timeout', '150', frame=hung, error='timeout')
                assert time.monotonic() - began < 3, 'Frame timeout did not bound the host wait'
                assert command('state')['page']['unresponsive']
                command('frame', 'list', error='web_content_unresponsive')
                other = documents(peer, 'frames-b')[0]['frameId']
                command('snapshot', frame=other, target=peer, space='frames-b')
                command('reload')
                loaded()
                command('snapshot', frame=hung, error='stale_frame')
                if host == '127.0.0.1':
                    command('open', origins['A'] + '/many')
                    capacity = command('frame', 'list')['value']
                    assert capacity['limit'] == 128 and len(capacity['frames']) == 128
                    assert capacity['truncated'] and capacity['evictedDocuments'] >= 5
                    # Surviving targets remain usable when the registry is full.
                    command('fill', '#same', 'bounded', frame=capacity['frames'][-1]['frameId'])
                cli('tab', 'close', second_tab, '--space', 'frames-a')
                command('snapshot', frame=child, target=second_tab, error='tab_not_found')
                assert len(requests) == 2, 'Inputs or submissions were replayed'
                after = cli('status')
                assert after['frontmostPid'] == initial['frontmostPid']
                assert after['observer'] == observer, (observer, after['observer'])
                evidence.append(dict(host=host, initialFrames=frames, independentPOSTs=requests))
            finally:
                for space in ['frames-a', 'frames-b']:
                    cli('space', 'delete', space)
    (out / 'frames.json').write_text(json.dumps(evidence, indent=2))
    return 'production frame list and snapshot/fill/click/wait; two cross-origin topologies; duplicate URLs/nested documents; real POSTs; isolation/stale targets/navigation/removal/suspend/restart; foreground unchanged'
