"""Real navigation error ownership and attachment transitions on an intact document."""
from collections import Counter
import http.server
import json
from pathlib import Path
import threading
import time
from urllib.parse import urlencode, urljoin, urlsplit

from fixtures import Events, Server


def verify_same_url_races(command, js, base, out, origin_events):
    plans = {}
    for mode in ('click', 'redirect', 'reload'):
        for first, second in ((500, 200), (200, 500)):
            statuses = [202, first, second] if mode == 'reload' else [first, second]
            for release_while_pending in (False, True):
                path = f'/same-url/{mode}/{first}/{"pending" if release_while_pending else "finished"}'
                plans[path] = dict(mode=mode, statuses=statuses, old_gate=threading.Event(),
                                   new_gate=threading.Event() if release_while_pending else None)
    counts = Counter()
    lock = threading.Lock()
    log = Events(out / 'same-url-server.jsonl')

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            redirect = self.path.startswith('/redirect/')
            path = self.path.removeprefix('/redirect') if redirect else self.path
            plan = plans.get(path)
            if plan is None:
                self.send_error(404)
                return
            statuses = plan['statuses']
            with lock:
                counts[self.path] += 1
                ordinal = counts[self.path]
                log.add(event='request', path=self.path, ordinal=ordinal)
            if ordinal > len(statuses):
                self.send_error(500, 'Unexpected replay')
                return
            gate = plan['old_gate'] if ordinal == len(statuses) - 1 else plan['new_gate'] if ordinal == len(statuses) else None
            if not redirect and gate is not None and not gate.wait(10):
                self.send_error(504, 'Response gate expired')
                return
            status = 302 if redirect else statuses[ordinal - 1]
            body = b'' if redirect else f'<!doctype html><body data-ordinal="{ordinal}">HTTP {status}</body>'.encode()
            outcome = 'written'
            try:
                self.send_response(status)
                if redirect:
                    self.send_header('Location', path)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                outcome = 'client-disconnected'
            log.add(event='response', path=self.path, ordinal=ordinal, status=status, outcome=outcome)

    def assert_document(page, url, ordinal, status, redirects):
        assert page['navigationPhase'] == 'finished' and not page['loading'] and page['lastError'] is None, page
        assert page['httpStatus'] == status and page['url'] == page['committedDocumentURL'] == page['responseURL'] == url, page
        assert page['navigationId'] and page['httpResponseNavigationId'] == page['navigationId'], page
        assert page['redirectCount'] == redirects, page
        assert js('[location.href,Number(document.body.dataset.ordinal),document.body.textContent]') == [
            url, ordinal, f'HTTP {status}'], page

    def assert_pending(page, phase, retained_url, retained_ordinal):
        assert page['navigationPhase'] == phase and page['loading'] and page['url'] == retained_url, page
        assert all(page[key] is None for key in ('httpStatus', 'responseURL', 'httpResponseNavigationId')), page
        if retained_ordinal is not None:
            assert js('Number(document.body.dataset.ordinal)') == retained_ordinal, page

    def responses_for(path, count):
        for _ in range(100):
            responses = [row for row in log.items if row['path'] == path and row['event'] == 'response']
            if len(responses) >= count:
                return responses
            time.sleep(.02)
        raise AssertionError((path, responses))

    results = []
    with Server(('127.0.0.1', 0), Handler) as site:
        threading.Thread(target=site.serve_forever, daemon=True).start()
        try:
            for path, plan in plans.items():
                mode, statuses = plan['mode'], plan['statuses']
                old_gate, new_gate = plan['old_gate'], plan['new_gate']
                url = f'http://127.0.0.1:{site.server_address[1]}{path}'
                via = urljoin(url, '/redirect' + path) if mode == 'redirect' else url
                args = ('reload',) if mode == 'reload' else ('open', via)
                retained_ordinal = 1 if mode == 'reload' else None
                initial = command('open', url if mode == 'reload' else base)['page']
                if mode == 'reload':
                    assert_document(initial, url, 1, 202, 0)
                old_ordinal = len(statuses) - 1
                if mode == 'click':
                    js(f'''document.body.insertAdjacentHTML('beforeend','<button id="race">Submit</button>');
                        document.querySelector('#race').onclick=async () => {{
                            const reply=await fetch('/keyboard-save',{{method:'POST',body:JSON.stringify({{race:{json.dumps(path)}}})}});
                            if (reply.ok) location.href={json.dumps(url)};
                        }};true''')
                    command('click', '#race', '--wait-for-navigation', '--timeout', '600', error='timeout')
                else:
                    command(*args, '--timeout', '600', error='timeout')
                pending = command('state')['page']
                phase = 'redirecting' if mode == 'redirect' else 'provisional'
                assert_pending(pending, phase, initial['url'], retained_ordinal)
                assert pending['navigationId'] != initial['navigationId'], pending
                assert counts[path] == old_ordinal, log.items

                while_pending = []
                if new_gate is not None:
                    command(*args, '--timeout', '600', error='timeout')
                    replacement = command('state')['page']
                    assert_pending(replacement, phase, initial['url'], retained_ordinal)
                    assert replacement['navigationId'] != pending['navigationId'], (pending, replacement)
                    assert counts[path] == len(statuses), log.items
                    old_gate.set()
                    responses_for(path, old_ordinal)
                    for _ in range(5):
                        time.sleep(.05)
                        observed = command('state')['page']
                        assert_pending(observed, phase, initial['url'], retained_ordinal)
                        assert observed['navigationId'] == replacement['navigationId'], (replacement, observed)
                        while_pending.append(observed)
                    new_gate.set()
                    winner = command('wait')['page']
                    assert winner['navigationId'] == replacement['navigationId'], (replacement, winner)
                    order = range(1, len(statuses) + 1)
                else:
                    winner = command(*args)['page']
                    old_gate.set()
                    order = [*range(1, old_ordinal), len(statuses), old_ordinal]
                assert winner['navigationId'] != pending['navigationId'], (pending, winner)
                assert_document(winner, url, len(statuses), statuses[-1], int(mode == 'redirect'))
                responses = responses_for(path, len(statuses))
                assert [(row['ordinal'], row['status']) for row in responses] == [
                    (ordinal, statuses[ordinal - 1]) for ordinal in order], responses
                assert next(row for row in responses if row['ordinal'] == len(statuses))['outcome'] == 'written', responses
                command('wait', '--fn', f'() => Number(document.body.dataset.ordinal)==={len(statuses)}',
                        '--stable-for', '200')
                final = command('state')['page']
                assert_document(final, url, len(statuses), statuses[-1], int(mode == 'redirect'))
                assert final['navigationId'] == winner['navigationId'], (winner, final)
                if mode == 'redirect':
                    redirects = [row['status'] for row in log.items if row['path'] == '/redirect' + path and row['event'] == 'response']
                    assert redirects == [302, 302], log.items
                if mode == 'click':
                    posts = [row for row in origin_events.items if row.get('kind') == 'keyboard-save' and row.get('race') == path]
                    assert len(posts) == 1, posts
                else:
                    posts = []
                results.append(dict(mode=mode, pending=pending, whileReplacementPending=while_pending,
                                    final=final, responses=responses, posts=posts))
            # Recheck completed cases too, in case a replay arrives during a later case.
            expected_requests = Counter({path: len(plan['statuses']) for path, plan in plans.items()})
            expected_requests.update({'/redirect' + path: 2 for path, plan in plans.items() if plan['mode'] == 'redirect'})
            with lock:
                assert counts == expected_requests, (counts, expected_requests)
            expected_posts = Counter(path for path, plan in plans.items() if plan['mode'] == 'click')
            actual_posts = Counter(row['race'] for row in origin_events.items
                                   if row.get('kind') == 'keyboard-save' and row.get('race') in expected_posts)
            assert actual_posts == expected_posts, (actual_posts, expected_posts)
        finally:
            for plan in plans.values():
                plan['old_gate'].set()
                if plan['new_gate'] is not None:
                    plan['new_gate'].set()
            site.shutdown()
    return results


def verify_navigation_failures(cli, base, out, events):
    name = 'navigation-failures'
    space = cli('space', 'create', name, '--proxy', 'direct')
    flags = ('--space', space['id'], '--tab', space['defaultTabId'])
    evidence = []

    def command(*args, **kwargs):
        result = cli(*args, *flags, **kwargs)
        evidence.append(dict(args=args, response=result))
        return result

    def js(source):
        return command('evaluate', source)['value']

    def requests(url):
        path = urlsplit(url).path + ('?' + urlsplit(url).query if urlsplit(url).query else '')
        return sum(e.get('kind') == 'origin' and e.get('path') == path for e in events.items)

    def next_download(before):
        for _ in range(100):
            new = [d for d in command('download', 'list')['value']['downloads'] if d['id'] not in before]
            if new:
                assert len(new) == 1, new
                result = command('download', 'wait', new[0]['id'])['value']
                assert result['status'] == 'completed' and Path(result['path']).read_bytes().startswith(b'download-'), result
                return result
            time.sleep(.02)
        raise AssertionError('No converted download')

    def download_ids():
        return {d['id'] for d in command('download', 'list')['value']['downloads']}

    try:
        races = verify_same_url_races(command, js, base, out, events)
        (out / 'same-url-navigation.json').write_text(json.dumps(races, indent=2))
        direct = command('open', base)['page']
        assert direct['httpStatus'] == 200 and direct['responseURL'] == base and direct['navigationPhase'] == 'finished', direct
        redirect = urljoin(base, '/download-redirect?' + urlencode(dict(to=base)))
        redirected = command('open', redirect)['page']
        assert redirected['httpStatus'] == 200 and redirected['responseURL'] == base and redirected['redirectCount'] == 1, redirected
        assert redirected['navigationId'] != direct['navigationId']
        history_page = urljoin(base, '/diagnostic-status?status=200')
        original_history = command('open', history_page)['page']
        assert command('back')['page']['url'] == base
        restored_history = command('forward')['page']
        assert restored_history['url'] == restored_history['responseURL'] == history_page
        assert restored_history['httpStatus'] == 200
        assert restored_history['httpResponseNavigationId'] in (restored_history['navigationId'], original_history['navigationId'])
        command('forward', error='history_unavailable')
        js('history.back(); true')
        command('wait', '--url', base)
        assert command('wait')['page']['httpStatus'] == 200
        js('history.forward(); true')
        command('wait', '--url', history_page)
        assert command('wait')['page']['responseURL'] == history_page
        js('history.pushState({step:1},"","?step=1");history.pushState({step:2},"","?step=2");true')
        history_back = command('back')
        assert history_back['value']['sameDocument'] and history_back['page']['url'].endswith('?step=1')
        history_forward = command('forward')
        assert history_forward['value']['sameDocument'] and history_forward['page']['url'].endswith('?step=2')
        js('history.pushState({step:3},"",location.href);true')
        assert command('back')['value']['sameDocument'] and js('history.state.step') == 2
        for status in (401, 404, 500):
            url = urljoin(base, f'/diagnostic-status?status={status}')
            page = command('open', url)['page']
            assert page['httpStatus'] == status and page['responseURL'] == url and page['navigationPhase'] == 'finished', page
            command('reload', '--fail-on-http-error', error='http_error')
            strict = command('state')['page']
            assert strict['httpStatus'] == status and strict['navigationId'] != page['navigationId'], strict
        command('open', base)
        js('window.noNavigationClicks=0;const b=document.createElement("button");b.id="no-navigation";b.onclick=()=>noNavigationClicks++;document.body.append(b);true')
        command('open', 'http://127.0.0.1:1/old-failure', error='operation_failed')
        failed = command('state')['page']
        assert failed['navigationPhase'] == 'provisional-failure' and failed['httpStatus'] is None and failed['responseURL'] is None, failed
        old_error = command('state')['page']['lastError']
        started = time.monotonic()
        command('click', '#no-navigation', '--wait-for-navigation', '--timeout', '150', error='timeout')
        assert time.monotonic() - started >= .12
        assert js('noNavigationClicks') == 1
        assert command('state')['page']['lastError'] == old_error, 'Waiting erased the historical error'

        destination = base + '?delay=0.25&navigation=recovered'
        js(f'document.querySelector("#no-navigation").onclick=()=>setTimeout(()=>location.href={json.dumps(destination)},250);true')
        before = requests(destination)
        started = time.monotonic()
        result = command('click', '#no-navigation', '--wait-for-navigation', '--timeout', '5000')
        assert time.monotonic() - started >= .4, 'New navigation was not awaited'
        assert result['page']['url'] == destination and result['page']['lastError'] is None, result
        assert requests(destination) == before + 1, 'Navigation action was replayed'

        # A previous open can time out before its failure callback arrives.
        # That failure belongs to the older sequence even though it is received after click.
        pending_destination = base + '?navigation=after-pending-failure'
        js(f'const b=document.createElement("button");b.id="pending-retry";b.onclick=()=>setTimeout(()=>location.href={json.dumps(pending_destination)},1000);document.body.append(b);true')
        pending_failure = urljoin(base, '/download-redirect?' + urlencode(dict(
            to='http://127.0.0.1:1/late-old-failure', delay='0.6')))
        command('open', pending_failure, '--timeout', '100', error='timeout')
        before = requests(pending_destination)
        started = time.monotonic()
        result = command('click', '#pending-retry', '--wait-for-navigation', '--timeout', '4000')
        assert time.monotonic() - started >= .9, 'A pending old failure terminated the new wait'
        assert result['page']['url'] == pending_destination and result['page']['lastError'] is None, result
        assert requests(pending_destination) == before + 1, 'Pending-navigation recovery replayed the click'

        js('const b=document.createElement("button");b.id="new-failure";b.onclick=()=>setTimeout(()=>location.href="http://127.0.0.1:7/new-failure",250);document.body.append(b);true')
        command('open', 'http://127.0.0.1:1/old-failure', error='operation_failed')
        started = time.monotonic()
        command('click', '#new-failure', '--wait-for-navigation', '--timeout', '3000', error='operation_failed')
        assert time.monotonic() - started >= .2, 'The old failure terminated the new action'

        page = urljoin(base, '/files')
        command('open', page)
        command('fill', '#not-file', 'unsaved draft')
        js('window.unsavedMarker="keep me";true')
        for kind in ('attribute', 'plain', 'redirect', 'open', 'navigation-wait', 'frame'):
            attachment = urljoin(base, '/download?mode=ok&navigation_case=' + kind)
            before_ids = download_ids()
            before_requests = requests(attachment)
            if kind == 'open':
                download = command('open', attachment)['page']
                assert download['navigationPhase'] == 'download' and download['httpStatus'] == 200 and download['responseURL'] == attachment, download
            elif kind == 'frame':
                js('const f=document.createElement("iframe");f.id="download-frame";document.body.append(f);true')
                command('wait', '#download-frame >>> body', '--state', 'attached')
                js(f'document.querySelector("#download-frame").contentDocument.body.innerHTML=\'<a id="child-download" href="{attachment}">Download</a>\';true')
                command('click', '#download-frame >>> #child-download')
            else:
                target = urljoin(base, '/download-redirect?' + urlencode(dict(to=attachment))) if kind == 'redirect' else attachment
                js(f'(()=>{{const a=document.querySelector("#download");a.href={json.dumps(target)};a.removeAttribute("download");' +
                   ('a.setAttribute("download","same.txt");' if kind == 'attribute' else '') + 'return true})()')
                if kind == 'navigation-wait':
                    command('click', '#download', '--wait-for-navigation', '--timeout', '2000', error='unsupported_navigation')
                else:
                    command('click', '#download')
            next_download(before_ids)
            command('wait', '#single')
            command('wait')
            command('wait', '--url', page)
            assert command('state')['page']['lastError'] is None, kind
            assert js('({marker:unsavedMarker,draft:document.querySelector("#not-file").value})') == dict(marker='keep me', draft='unsaved draft')
            assert requests(attachment) == before_requests + 1, (kind, 'Download was replayed')
        report = dict(passed=True, historicalErrorPreserved=True, newClickWaitIgnoresOldError=True,
                      sameURLResponseRaces=len(races),
                      pendingOldFailureDoesNotAbortNewClick=True,
                      newFailureReported=True, noNavigationTimesOut=True, noActionReplay=True,
                      downloadTransitions=['attribute', 'plain', 'redirect', 'open', 'navigation-wait', 'frame'],
                      intactDocumentAndDraftPreserved=True, evidence=evidence)
        (out / 'navigation-failures.json').write_text(json.dumps(report, indent=2))
        return {key: value for key, value in report.items() if key != 'evidence'}
    finally:
        cli('space', 'delete', space['id'])
