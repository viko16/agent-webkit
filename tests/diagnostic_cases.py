"""Bounded, redacted diagnostic data from real WebKit callbacks and page failures."""
from concurrent.futures import ThreadPoolExecutor
import json
import socket
import time
from urllib.parse import urljoin


def verify_diagnostics(cli, base, out, restart):
    name = 'diagnostic'
    other = 'diagnostic-other'
    cli('space', 'create', name, '--proxy', 'direct')
    cli('space', 'create', other, '--proxy', 'direct')

    def command(*args, **kwargs):
        return cli(*args, '--space', name, **kwargs)

    def js(source, **kwargs):
        return command('evaluate', source, **kwargs)['value']

    def logs(*args):
        response = command('diagnostics', *args)
        assert 'diagnostic-secret' not in json.dumps(response), response
        assert not response['value']['routeVerified'] and response['value']['redacted']
        return response['value']

    def until(predicate, *args):
        for _ in range(80):
            value = logs(*args)
            if predicate(value):
                return value
            time.sleep(.05)
        raise AssertionError(value)

    try:
        focus = cli('status')['frontmostPid']
        command('diagnostics', '--timeout', '100', error='invalid_arguments')
        command('state', '--clear', error='invalid_arguments')
        command('open', urljoin(base, '/diagnostics?secret=diagnostic-secret#diagnostic-secret'))
        initial = until(lambda v: any(e['kind'] == 'capture-ready' for e in v['events']))
        assert js('typeof document.querySelector("#run").onclick') == 'function', initial
        logs('--clear')
        command('click', '#run')
        command('wait', '#result', '--text', 'Done', '--timeout', '5000')
        actual = js('window.actualResults')
        assert actual['nonce'] and actual['status'] == 503 and actual['failed']
        assert [x['status'] for x in actual['xhrs']] == [404, 0, 0, 0], actual
        captured = until(lambda v: {e.get('outcome') for e in v['events'] if e['kind'] == 'xhr'} >= {'response', 'error', 'timeout', 'abort'})
        events = captured['events']
        assert {e.get('level') for e in events if e['kind'] == 'console'} == {'warn', 'error'}, events
        assert any(e['kind'] == 'exception' and e['errorType'] == 'TypeError' and e['line'] > 0 for e in events), events
        assert any(e['kind'] == 'unhandled-rejection' and e['errorType'] == 'RangeError' for e in events), events
        assert any(e['kind'] == 'resource-error' and e['resourceType'] == 'img' for e in events), events
        fetches = [e for e in events if e['kind'] == 'fetch']
        assert {e.get('status') for e in fetches} >= {200, 503}, fetches
        assert any(e.get('outcome') == 'rejected' for e in fetches), fetches
        assert all(e['durationMs'] >= 0 for e in fetches)
        assert all(e['source'] == 'page-script' for e in events)
        opaque = command('evaluate', 'fetch(location.href.replace("127.0.0.1","localhost"),{mode:"no-cors"}).then(r=>({status:r.status,type:r.type}))', '--await')['value']
        assert opaque == {'status': 0, 'type': 'opaque'}, opaque
        until(lambda v: any(e['kind'] == 'fetch' and e.get('status') == 0 and e.get('outcome') == 'response' and e.get('origin') == 'opaque' for e in v['events']))
        (out / 'diagnostics-page.json').write_text(json.dumps(captured, indent=2))
        # Page callbacks may immediately reuse an XHR, before its old loadend fires.
        for callback in ['onload', 'onreadystatechange']:
            logs('--clear')
            result = command('evaluate', '''new Promise(resolve=>{
                const xhr=new XMLHttpRequest();
                xhr.open('GET','/diagnostic-status?status=503');
                xhr[CALLBACK]=()=>{
                    if(xhr.readyState!==4)return;
                    const status=xhr.status;
                    xhr.open('GET','https://example.com/diagnostic-secret');
                    resolve({status,resetStatus:xhr.status});
                };
                xhr.send();
            })'''.replace('CALLBACK', json.dumps(callback)), '--await')['value']
            assert result == {'status': 503, 'resetStatus': 0}, result
            reused = until(lambda v: any(e['kind'] == 'xhr' for e in v['events']))
            xhrs = [e for e in reused['events'] if e['kind'] == 'xhr']
            assert len(xhrs) == 1 and xhrs[0]['status'] == 503, reused
            assert xhrs[0]['origin'] == urljoin(base, '/').rstrip('/') and xhrs[0]['outcome'] == 'response', reused
        logs('--clear')
        chained = command('evaluate', '''new Promise(resolve=>{
            const xhr=new XMLHttpRequest(), statuses=[];
            xhr.open('GET','/diagnostic-status?status=503');
            xhr.onload=()=>{
                statuses.push(xhr.status);
                if(statuses.length===2){resolve(statuses);return;}
                xhr.open('GET','/diagnostic-status?status=201'); xhr.send();
            };
            xhr.send();
        })''', '--await')['value']
        assert chained == [503, 201], chained
        reused = until(lambda v: len([e for e in v['events'] if e['kind'] == 'xhr']) >= 2)
        xhrs = [e for e in reused['events'] if e['kind'] == 'xhr']
        assert [e['status'] for e in xhrs] == [503, 201], reused
        assert all(e['outcome'] == 'response' and e['durationMs'] >= 0 for e in xhrs), reused
        (out / 'diagnostics-xhr-reuse.json').write_text(json.dumps(reused, indent=2))
        # Shared popup content controllers must still route logs to the actual WKWebView.
        js('Boolean(window.open("about:blank"))')
        parent = command('state')['page']['tabId']
        child = next(t['tabId'] for t in command('tab', 'list') if t['tabId'] != parent)
        until(lambda v: any(e['kind'] == 'capture-ready' for e in v['events']), '--tab', child)
        logs('--clear'); logs('--tab', child, '--clear')
        command('evaluate', 'console.error("diagnostic-secret"); true', '--tab', child)
        until(lambda v: any(e['kind'] == 'console' for e in v['events']), '--tab', child)
        assert not any(e['kind'] == 'console' for e in logs()['events'])
        assert not any(e['kind'] == 'console' for e in cli('diagnostics', '--space', other)['value']['events'])
        command('tab', 'close', child)
        logs('--clear')
        command('evaluate', 'new Promise(resolve=>{const f=document.createElement("iframe"); f.onload=()=>{f.contentWindow.webkit.messageHandlers.agentWebKitDiagnostics.postMessage({events:[{kind:"console",level:"error"}]}); console.warn("frame barrier"); resolve(true)}; f.src="/context-frame"; document.body.append(f)})', '--await')
        framed = until(lambda v: any(e['kind'] == 'console' for e in v['events']))
        assert [e['level'] for e in framed['events'] if e['kind'] == 'console'] == ['warn'], framed
        logs('--clear')
        # Untrusted messages cannot introduce arbitrary keys, sources, IDs or unredacted URLs.
        js('window.webkit.messageHandlers.agentWebKitDiagnostics.postMessage({events:[{kind:"console",level:"error",source:"webkit",message:"diagnostic-secret",body:"diagnostic-secret",origin:"https://diagnostic-secret:diagnostic-secret@example.com/private/diagnostic-secret?diagnostic-secret#diagnostic-secret",status:Infinity}],dropped:0}); true')
        forged = until(lambda v: any(e['kind'] == 'console' for e in v['events']))['events'][-1]
        assert forged['source'] == 'page-script' and forged['origin'] == 'https://example.com', forged
        assert 'message' not in forged and 'status' not in forged
        logs('--clear')
        js('for(let i=0;i<1000;i++) console.warn("diagnostic-secret"); true')
        flooded = until(lambda v: v['droppedEvents'] >= 900)
        assert len(flooded['events']) <= flooded['limit'] == 200
        # Several bounded batches also exercise native ring eviction.
        for _ in range(3):
            last = logs()['events'][-1]['id']
            js('for(let i=0;i<100;i++) console.warn("diagnostic-secret"); true')
            until(lambda v: v['events'][-1]['id'] >= last + 100)
        assert len(logs()['events']) == 200
        assert logs('--clear')['events'] == []
        # Reading diagnostics never enters the busy WebContent process.
        with ThreadPoolExecutor(1) as pool:
            future = pool.submit(command, 'evaluate', 'new Promise(r=>setTimeout(()=>r(true),800))', '--await')
            for _ in range(50):
                if cli('space', 'info', name)['busy']:
                    break
                time.sleep(.01)
            assert command('diagnostics')['busy']
            assert future.result()['value'] is True
        command('open', urljoin(base, '/diagnostic-status?status=503&secret=diagnostic-secret'))
        native = logs()['events']
        assert any(e['source'] == 'webkit' and e['kind'] == 'navigation-response' and e['status'] == 503 for e in native)
        assert any(e['kind'] == 'navigation-finished' and e['durationMs'] >= 0 for e in native)
        with socket.socket() as refused:
            refused.bind(('127.0.0.1', 0))
            refused_origin = f'http://127.0.0.1:{refused.getsockname()[1]}'
            refused.close()  # macOS can leave bound-but-not-listening sockets pending instead of refusing.
            command('open', refused_origin + '/diagnostic-secret?diagnostic-secret', '--timeout', '10000', error='operation_failed')
        failure = next(e for e in reversed(logs()['events']) if e['kind'] == 'navigation-failed')
        assert failure['source'] == 'webkit' and failure['reason'] == 'connection_failed', failure
        assert failure['origin'] == refused_origin and failure['durationMs'] >= 0, failure
        command('open', base + '?delay=1', '--timeout', '100', error='timeout')
        assert any(e['kind'] == 'navigation-timeout' for e in logs()['events'])
        command('open', base)
        command('evaluate', 'while(true){}', '--timeout', '100', error='timeout')
        timeout = next(e for e in logs()['events'] if e['kind'] == 'operation-timeout')
        command('reload', '--timeout', '5000')
        assert any(e['id'] == timeout['id'] for e in logs()['events'])
        (out / 'diagnostics-native.json').write_text(json.dumps(logs(), indent=2))
        js('console.warn("diagnostic-secret"); true')
        until(lambda v: any(e['kind'] == 'console' for e in v['events']))
        restart()
        command('wait', '--timeout', '5000')
        assert not any(e['kind'] == 'console' for e in logs()['events'])
        assert cli('status')['frontmostPid'] == focus
        return 'diagnostics: real console/errors/rejection/resource/fetch/XHR; native HTTP/failure/deadline; redaction and forged input; bounded queues; popup/Space isolation; busy/hung reads, recovery retention and restart reset'
    finally:
        (out / 'diagnostics-last.json').write_text(json.dumps(logs(), indent=2))
        cli('space', 'delete', name)
        cli('space', 'delete', other)
