"""Real Vite HMR over domain-mapped Whistle/WSS, never a direct loopback substitute."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import urllib.request
from urllib.parse import urlsplit
import uuid

from whistle_fixture import WhistleFixture

ROOT = Path(__file__).resolve().parents[1]


def verify_hmr_acknowledgements(acknowledgements, expected_documents):
    for revision, document_ids in expected_documents.items():
        matches = [event for event in acknowledgements if event['revision'] == revision]
        expected_ids = set(document_ids)
        assert (len(expected_ids) == 2 and len(matches) == 2
                and {event.get('documentId') for event in matches} == expected_ids), (revision, document_ids, matches)


@contextmanager
def vite_site(out):
    assert (ROOT / 'tests/forms/node_modules/vite').is_dir(), 'Run npm ci --prefix tests/forms first'
    project = out / 'project'
    shutil.copytree(ROOT / 'tests/vite', project)
    log_path = out / 'vite.log'
    with log_path.open('w') as log:
        process = subprocess.Popen(['node', str(ROOT / 'tests/forms/vite-workflow.mjs')],
            env=dict(os.environ, VITE_PROJECT_ROOT=str(project),
                     VITE_WORKFLOW_LOG=str(out / 'origin.jsonl')), stdout=log, stderr=log)
        try:
            for _ in range(150):
                assert process.poll() is None, log_path.read_text()
                urls = [line.removeprefix('VITE_URL=') for line in log_path.read_text().splitlines()
                        if line.startswith('VITE_URL=')]
                if urls:
                    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                    with opener.open(urls[0] + 'api/probe', timeout=5) as response:
                        nonce = json.load(response)['nonce']
                    yield urlsplit(urls[0]).port, nonce, project
                    return
                time.sleep(.1)
            raise AssertionError(f'Vite startup timed out: {log_path.read_text()}')
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=5)


def verify_vite_workflow(out, cli, restart):
    directory = out / 'vite-workflow'
    directory.mkdir()
    report = {'passed': False, 'rounds': [], 'realSystemProxyToggleTested': False}
    created = {}
    names = ('vite-a', 'vite-b')
    try:
        with vite_site(directory) as (port, nonce, project):
            whistle = WhistleFixture(directory, port)
            try:
                whistle.start()
                report.update(originPort=port, nonce=nonce, proxy=whistle.url, rules=whistle.rules)
                focus = cli('status')['frontmostPid']
                target = f'https://example.com/?vite_workflow={uuid.uuid4().hex}'
                report['url'] = target
                for name in names:
                    created[name] = cli('space', 'create', name, '--proxy', whistle.url,
                                        '--ignore-certificate-errors')
                created['vite-direct'] = cli('space', 'create', 'vite-direct', '--proxy', 'direct')

                def command(name, *args, **kwargs):
                    return cli(*args, '--space', name, '--tab', created[name]['defaultTabId'], **kwargs)

                def js(name, source):
                    return command(name, 'evaluate', source)['value']

                def ready(name, revision):
                    command(name, 'wait', '#revision', '--text', revision, '--timeout', '10000')
                    command(name, 'wait', '--fn', f'() => document.querySelector("#revision").textContent === {json.dumps(revision)}',
                            '--stable-for', '100', '--timeout', '10000')

                def events():
                    return [json.loads(line) for line in (directory / 'origin.jsonl').read_text().splitlines()]

                def await_events(predicate):
                    for _ in range(100):
                        received = events()
                        if predicate(received):
                            return received
                        time.sleep(.05)
                    raise AssertionError(f'Vite evidence did not arrive: {received}')

                with ThreadPoolExecutor(2) as pool:
                    list(pool.map(lambda name: command(name, 'open', target), names))
                initial = {}
                for count, name in enumerate(names, 1):
                    ready(name, 'initial')
                    for _ in range(count):
                        command(name, 'click', '#increment')
                    command(name, 'click', '#probe')
                    command(name, 'wait', '#result', '--text', nonce)
                    js(name, f'document.cookie="vite={name}; Max-Age=3600; Path=/";'
                       f'localStorage.setItem("vite",{json.dumps(name)});true')
                    initial[name] = js(name, 'window.workflowState')
                assert initial['vite-a']['documentId'] != initial['vite-b']['documentId']
                assert cli('evaluate', 'window.workflowState', '--space', 'vite-b',
                           '--tab', created['vite-a']['defaultTabId'], ok=False)['code'] == 'tab_not_found'
                spare = cli('tab', 'new', 'about:blank', '--space', 'vite-a')['tabId']
                cli('tab', 'default', spare, '--space', 'vite-a')
                await_events(lambda items: len([e for e in items if e['kind'] == 'ws-connected']) == 2)

                # Direct must visit the same public domain, without reaching Vite or Whistle.
                before_sessions = {s['id'] for s in whistle.sessions()}
                before_hits = (directory / 'origin.jsonl').read_text()
                command('vite-direct', 'open', target)
                assert js('vite-direct', '({title:document.title,state:window.workflowState||null})') == {
                    'title': 'Example Domain', 'state': None}
                assert {s['id'] for s in whistle.sessions()} == before_sessions
                assert (directory / 'origin.jsonl').read_text() == before_hits
                report['directAddedRequests'] = 0

                # Only change a generated module in this run's disposable project.
                # Stable document IDs + counters distinguish HMR from a full reload.
                for index in range(1, 4):
                    revision = f'update-{index}-{nonce}'
                    (project / 'revision.js').write_text(f'export const revision = {json.dumps(revision)};\n')
                    states = {}
                    for name in names:
                        ready(name, revision)
                        state = js(name, 'window.workflowState')
                        assert state == dict(initial[name], revision=revision, updates=index), state
                        assert js(name, '({cookie:document.cookie,local:localStorage.getItem("vite")})') == {
                            'cookie': f'vite={name}', 'local': name}
                        states[name] = state
                    report['rounds'].append(states)

                assert cli('evaluate', 'window.workflowState||null', '--space', 'vite-a', '--tab', spare)['value'] is None
                assert command('vite-a', 'wait', '#revision', '--text', 'never-published',
                               '--timeout', '100', ok=False)['code'] == 'timeout'
                assert js('vite-a', 'window.workflowState') == report['rounds'][-1]['vite-a']
                cli('tab', 'close', spare, '--space', 'vite-a')
                assert cli('space', 'info', 'vite-a')['defaultTabId'] == created['vite-a']['defaultTabId']
                final_revision = report['rounds'][-1][names[0]]['revision']
                old_ref = next(e['ref'] for e in command('vite-a', 'snapshot')['value']['elements']
                               if e['name'] == 'Increment')
                command('vite-a', 'open', target + '&renavigated=1')
                ready('vite-a', final_revision)
                assert js('vite-a', 'window.workflowState.documentId') != initial['vite-a']['documentId']
                assert command('vite-a', 'click', old_ref, ok=False)['code'] == 'stale_ref'
                command('vite-a', 'screenshot', '--out', str(directory / 'after-hmr.png'))
                time.sleep(2)  # Allow WebKit to flush the persistent test Cookie.
                restart()
                restored_documents = []
                for name in names:
                    info = cli('space', 'info', name)
                    for key in ('id', 'dataStoreId', 'defaultTabId', 'proxy', 'tls'):
                        assert info[key] == created[name][key], (key, info)
                    ready(name, final_revision)
                    restored_documents.append(js(name, 'window.workflowState.documentId'))
                    assert js(name, '({cookie:document.cookie,local:localStorage.getItem("vite")})') == {
                        'cookie': f'vite={name}', 'local': name}
                # Verify the restored pages reconnect to WSS and still apply a real hot update.
                revision = f'after-restart-{nonce}'
                (project / 'revision.js').write_text(f'export const revision = {json.dumps(revision)};\n')
                for name in names:
                    ready(name, revision)
                    assert js(name, 'window.workflowState.updates') == 1
                assert cli('status')['frontmostPid'] == focus

                received = await_events(lambda items: len([e for e in items if e['kind'] == 'hmr-applied']) >= 8)
                sessions = whistle.sessions()
                http = [s for s in sessions if s.get('url', '').startswith('https://example.com/')]
                websocket = [s for s in sessions if s.get('url', '').startswith('wss://example.com/')]
                assert any(s['url'] == target and s['res']['statusCode'] == 200 for s in http), http
                for path in ('/main.js', '/revision.js', '/api/probe', '/@vite/client'):
                    assert any(path in s['url'] and s['res']['statusCode'] == 200 for s in http), (path, http)
                    assert any(e['kind'] == 'http' and e['path'].startswith(path) for e in received), path
                assert websocket and all(str(s['res']['statusCode']) == '101' for s in websocket), websocket
                assert any(e['kind'] == 'upgrade' for e in received)
                acknowledgements = [e for e in received if e['kind'] == 'hmr-applied']
                expected_documents = {states[names[0]]['revision']: [states[name]['documentId'] for name in names]
                                      for states in report['rounds']}
                expected_documents[revision] = restored_documents
                verify_hmr_acknowledgements(acknowledgements, expected_documents)
                for session in http + websocket:
                    scheme = 'ws' if session in websocket else 'http'
                    assert session.get('realUrl', '').startswith(f'{scheme}://127.0.0.1:{port}/'), session
                    assert int(session['res']['port']) == port, session
                    assert session['rules']['rule']['matcher'] == f'http://127.0.0.1:{port}', session
                report.update(websocketSessionIds=[s['id'] for s in websocket],
                    httpSessionIds=[s['id'] for s in http], hmrAcknowledgements=acknowledgements,
                    hmrExpectedDocumentIds=expected_documents,
                    foregroundPid=focus, restored=True, syntheticInput=True,
                    explicitTabIsolation=True, waitTimeoutDidNotReplay=True)
            finally:
                # Stop the test-owned network resources even if a Space deletion fails.
                try:
                    for name in created:
                        cli('space', 'delete', name)
                finally:
                    whistle.close()
        report['passed'] = True
        return report
    finally:
        (directory / 'report.json').write_text(json.dumps(report, indent=2))
