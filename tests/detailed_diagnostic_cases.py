"""Opt-in detail capture on real WebKit; default summary regression remains separate."""
from concurrent.futures import ThreadPoolExecutor
import json
import sys
import time
from urllib.parse import urljoin


def verify_detailed_diagnostics(cli, base, out, restart, verify_expiry=False):
    name, peer = 'details', 'details-peer'
    work = cli('space', 'create', name, '--proxy', 'direct')
    cli('space', 'create', peer, '--proxy', 'direct')
    url = urljoin(base, '/diagnostics?token=diagnostic-secret#diagnostic-secret')

    def command(*args, **kwargs):
        return cli(*args, '--space', name, **kwargs)

    def logs(*args):
        response = command('diagnostics', *args)
        assert 'diagnostic-secret' not in json.dumps(response), response
        assert response['value']['redacted'] and not response['value']['persistent']
        return response['value']

    def until(predicate, *args):
        for _ in range(100):
            value = logs(*args)
            if predicate(value):
                return value
            time.sleep(.05)
        raise AssertionError(value)

    try:
        focus = cli('status')['frontmostPid']
        command('diagnostics', '--detail', 'yes', error='invalid_arguments')
        command('state', '--detail', 'on', error='invalid_arguments')
        command('open', url)
        cli('open', url, '--space', peer)
        assert not logs()['inspectable']
        command('diagnostics', '--inspectable', 'yes', error='invalid_arguments')
        command('state', '--inspectable', 'on', error='invalid_arguments')
        command('diagnostics', '--inspectable', 'on', '--detail', 'on', error='invalid_arguments')
        assert logs('--inspectable', 'on')['inspectable']
        assert not logs()['detail']['enabled']
        assert not cli('diagnostics', '--space', peer)['value']['inspectable']
        assert not logs()['detail']['enabled']
        command('evaluate', 'console.error("diagnostic-secret"); true')
        until(lambda v: any(e['kind'] == 'console' for e in v['events']))
        assert not any('detail' in e for e in logs()['events'])
        enabled = logs('--detail', 'on', '--clear')
        assert enabled['detail']['enabled'] and enabled['events'] == []
        remaining = enabled['detail']['expiresAtMs'] - time.time() * 1000
        assert 290000 < remaining <= 300000, enabled
        command('click', '#run')
        command('wait', '#result', '--text', 'Done', '--timeout', '5000')
        captured = until(lambda v: len([e for e in v['events'] if e['kind'] == 'xhr' and 'detail' in e]) >= 4)
        detailed = [e for e in captured['events'] if 'detail' in e]
        assert any(e['kind'] == 'exception' and e['detail'].get('stack') for e in detailed), detailed
        assert any(e['kind'] == 'unhandled-rejection' and e['detail'].get('message') for e in detailed)
        assert any(e['kind'] == 'resource-error' and '/diagnostic-status' in e['detail'].get('resource', '') for e in detailed)
        requests = [e['detail'] for e in detailed if e['kind'] in ('fetch', 'xhr')]
        assert len({e['requestId'] for e in requests}) == len(requests) >= 7
        assert len({e['navigationId'] for e in requests}) == 1
        assert all('?' not in e.get('resource', '') and '#' not in e.get('resource', '') for e in requests)
        assert not any('detail' in e for e in cli('diagnostics', '--space', peer)['value']['events'])
        # Retain useful safe text, redact form values, credential labels, URL credentials/query and long tokens.
        command('evaluate', '''console.error(new Error('Inventory failed diagnostic-secret password=hidden-password Authorization=Bearer hidden-token https://user:pass@example.com/api/12345?token=hidden-query#hidden-fragment file:///private/local?token=hidden-local abcdefghijklmnopqrstuvwxyz123456')); true''')
        message = until(lambda v: any('Inventory failed' in e.get('detail', {}).get('message', '') for e in v['events']))
        rendered = json.dumps(message)
        for secret in ('hidden-password', 'hidden-token', 'hidden-query', 'hidden-fragment', 'hidden-local', 'user:pass', 'abcdefghijklmnopqrstuvwxyz123456'):
            assert secret not in rendered, rendered
        assert '[redacted]' in rendered
        generation = requests[0]['requestId'].split(':')[0]
        forged = dict(kind='console', level='warn', argumentCount=38, generation=generation,
                      detail=dict(message='password="hidden password"', navigationId='page-forged',
                                  resource='https://user:pass@example.com/api/12345/ABCDEFGHIJKLMNOPQRSTUVWXYZ?token=hidden-query#fragment',
                                  stack=['token=hidden-token'] * 20, body='must be omitted'))
        command('evaluate', 'window.webkit.messageHandlers.agentWebKitDiagnostics.postMessage(' + json.dumps(dict(events=[forged])) + '); true')
        hostile = next(e['detail'] for e in until(lambda v: any(e.get('argumentCount') == 38 for e in v['events']))['events'] if e.get('argumentCount') == 38)
        assert hostile['navigationId'] != 'page-forged' and 'body' not in hostile
        assert len(hostile['stack']) == 8 and hostile['resource'] == 'https://example.com/api/[redacted]/[redacted]'
        assert not any(secret in json.dumps(hostile) for secret in ('hidden password', 'hidden-token', 'user:pass', 'hidden-query'))
        logs('--clear')
        command('evaluate', 'console.warn("a".repeat(10000)); true')
        until(lambda v: any(e['kind'] == 'console' and 'detail' in e for e in v['events']))
        assert all(len(e['detail'].get('message', '')) <= 512 and len(e['detail'].get('stack', [])) <= 8 for e in logs()['events'] if 'detail' in e)
        # Popup content controllers may be shared, but detail opt-in is never inherited.
        command('evaluate', 'Boolean(window.open("about:blank"))')
        child = next(tab['tabId'] for tab in command('tab', 'list') if tab['tabId'] != work['defaultTabId'])
        assert not logs('--tab', child)['detail']['enabled']
        assert not logs('--tab', child)['inspectable']
        command('evaluate', 'console.warn("diagnostic-secret"); true', '--tab', child)
        until(lambda v: any(e['kind'] == 'console' for e in v['events']), '--tab', child)
        assert not any('detail' in e for e in logs('--tab', child)['events'])
        command('tab', 'close', child)
        (out / 'diagnostics-detailed.json').write_text(json.dumps(logs(), indent=2))
        # The disabled host rejects even a saved generation and an already queued detail batch.
        stopped = logs('--detail', 'off')
        assert not stopped['detail']['enabled'] and not any('detail' in e for e in stopped['events'])
        logs('--clear')
        command('evaluate', 'window.webkit.messageHandlers.agentWebKitDiagnostics.postMessage({events:[{kind:"console",level:"error",argumentCount:37,generation:' + json.dumps(generation) + ',detail:{message:"diagnostic-secret"}}]}); true')
        until(lambda v: any(e.get('argumentCount') == 37 for e in v['events']))
        assert not any('detail' in e for e in logs()['events'])
        with ThreadPoolExecutor(1) as pool:
            future = pool.submit(command, 'evaluate', 'new Promise(r=>setTimeout(()=>r(true),600))', '--await')
            for _ in range(50):
                if cli('space', 'info', name)['busy']:
                    break
                time.sleep(.01)
            command('diagnostics', '--detail', 'on', error='space_busy')
            assert not logs('--inspectable', 'off')['inspectable']
            assert not logs('--detail', 'off')['detail']['enabled']
            assert future.result()['value'] is True
        logs('--detail', 'on')
        command('evaluate', 'while(true){}', '--timeout', '100', error='timeout')
        hung = logs()
        assert any(e['kind'] == 'operation-timeout' and e.get('detail', {}).get('message') for e in hung['events'])
        assert logs('--inspectable', 'on')['inspectable']
        assert not logs('--detail', 'off')['detail']['enabled']
        command('reload', '--timeout', '5000')
        assert not logs()['inspectable']
        assert not logs()['detail']['enabled']
        logs('--detail', 'on')
        assert logs('--inspectable', 'on')['inspectable']
        command('open', url)
        assert logs()['inspectable']
        assert not logs()['detail']['enabled'] and not any('detail' in e for e in logs()['events'])
        logs('--detail', 'on')
        assert logs('--inspectable', 'on')['inspectable']
        restart()
        command('wait')
        assert not logs()['detail']['enabled']
        assert not logs()['inspectable']
        command('evaluate', 'delete window.__agentWebKitDiagnosticMode; true')
        command('diagnostics', '--detail', 'on', error='diagnostics_unavailable')
        assert not logs()['detail']['enabled']
        command('reload')
        if verify_expiry:
            enabled = logs('--detail', 'on', '--clear')
            command('evaluate', 'console.warn("expiry marker"); true')
            until(lambda v: any('detail' in e for e in v['events']))
            end = time.monotonic() + 310
            while logs()['detail']['enabled'] and time.monotonic() < end:
                time.sleep(2)
            expired = logs()
            assert not expired['detail']['enabled'] and not any('detail' in e for e in expired['events'])
            (out / 'diagnostics-expired.json').write_text(json.dumps(expired, indent=2))
        assert cli('status')['frontmostPid'] == focus
        return dict(detailedDiagnostics=True, expiryVerified=verify_expiry, requests=len(requests),
                    checks=['errors/stacks/resources/request IDs', 'redaction and bounded lengths', 'default/Space/popup isolation',
                            'off clears details; busy/hung off; navigation and restart reset',
                            'inspectable opt-in/Space/popup/busy/hung/replacement/restart; no UI activation', 'foreground unchanged'])
    finally:
        failed = sys.exc_info()[0] is not None
        errors = []
        for target in (name, peer):
            try:
                cli('space', 'delete', target)
            except Exception as error:
                errors.append(str(error))
        if errors:
            (out / 'diagnostics-detail-cleanup-errors.json').write_text(json.dumps(errors, indent=2))
            if not failed:
                raise AssertionError(errors)
