"""Real navigation error ownership and attachment transitions on an intact document."""
import json
from pathlib import Path
import time
from urllib.parse import urlencode, urljoin, urlsplit


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
        command('open', base)
        js('window.noNavigationClicks=0;const b=document.createElement("button");b.id="no-navigation";b.onclick=()=>noNavigationClicks++;document.body.append(b);true')
        command('open', 'http://127.0.0.1:1/old-failure', error='operation_failed')
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
                command('open', attachment)
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
                      newFailureReported=True, noNavigationTimesOut=True, noActionReplay=True,
                      downloadTransitions=['attribute', 'plain', 'redirect', 'open', 'navigation-wait', 'frame'],
                      intactDocumentAndDraftPreserved=True, evidence=evidence)
        (out / 'navigation-failures.json').write_text(json.dumps(report, indent=2))
        return {key: value for key, value in report.items() if key != 'evidence'}
    finally:
        cli('space', 'delete', space['id'])
