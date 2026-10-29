"""Native WKDownload callbacks, bounded waits and per-Tab ownership."""
import json
from pathlib import Path
import time
from urllib.parse import urljoin


def verify_download_tls(cli, page_url, destination, space, accepted):
    cli('open', page_url, '--space', space)
    previous = {d['id'] for d in cli('download', 'list', '--space', space)['value']['downloads']}
    cli('evaluate', f'document.querySelector("#download").href={json.dumps(destination)};true', '--space', space)
    cli('click', '#download', '--space', space)
    for _ in range(100):
        items = [d for d in cli('download', 'list', '--space', space)['value']['downloads'] if d['id'] not in previous]
        if items:
            break
        time.sleep(.02)
    else:
        raise AssertionError('No native TLS download')
    result = cli('download', 'wait', items[0]['id'], '--space', space)['value']
    assert result['status'] == ('completed' if accepted else 'failed'), result
    if accepted:
        assert Path(result['path']).read_text().startswith('download-')
    else:
        assert result['error'] and result['path'] is None
    # Download trust failures must not poison an intact document's navigation state.
    cli('wait', '#single', '--space', space)
    assert cli('state', '--space', space)['page']['lastTLSChallenge'] == {}
    return dict(status=result['status'], pageWaitUnaffected=True)


def verify_downloads(cli, base, out, restart, state):
    name, peer = 'file-work', 'file-peer'
    work = cli('space', 'create', name, '--proxy', 'direct')
    cli('space', 'create', peer, '--proxy', 'direct')
    target = cli('tab', 'new', urljoin(base, '/files'), '--space', name)['tabId']
    flags = ('--space', name, '--tab', target)

    def command(*args, **kwargs):
        return cli(*args, *flags, **kwargs)

    def begin(selector):
        ids = {d['id'] for d in command('download', 'list')['value']['downloads']}
        command('click', selector)
        for _ in range(100):
            new = [d for d in command('download', 'list')['value']['downloads'] if d['id'] not in ids]
            if new:
                return new[0]['id']
            time.sleep(.02)
        raise AssertionError('No native download')

    try:
        before = cli('status')
        first = begin('#download')
        complete = command('download', 'wait', first)['value']
        assert complete['status'] == 'completed', complete
        path = Path(complete['path'])
        assert path.read_text().startswith('download-')
        assert work['id'] in str(path) and target in str(path)
        second = command('download', 'wait', begin('#download'))['value']
        assert second['filename'] == complete['filename'] and second['path'] != complete['path']
        assert Path(second['path']).read_bytes() == path.read_bytes()
        folder = path.parent.parent
        try:
            folder.chmod(0o500)
            denied = command('download', 'wait', begin('#download'))['value']
            assert denied['status'] == 'failed' and denied['error'] and denied['path'] is None, denied
        finally:
            folder.chmod(0o700)
        cli('download', 'wait', first, '--space', peer, error='download_not_found')
        cli('download', 'wait', first, '--space', name, error='download_not_found')
        slow = begin('#slow')
        command('download', 'wait', slow, '--timeout', '50', error='timeout')
        cli('space', 'suspend', name, error='space_busy')
        cancelled = command('download', 'cancel', slow)['value']
        assert cancelled['status'] == 'cancelled' and cancelled['path'] is None
        assert cancelled['cleanupError'] is None
        assert not (path.parent.parent / slow).exists()
        assert command('download', 'cancel', slow)['value']['status'] == 'cancelled'
        failed = command('download', 'wait', begin('#drop'))['value']
        assert failed['status'] == 'failed' and failed['error'] and failed['path'] is None, failed
        for _ in range(100):
            leftovers = [p for item in (slow, failed['id']) for p in (path.parent.parent / item).rglob('*') if p.is_file()]
            if not leftovers:
                break
            time.sleep(.02)
        assert not leftovers, leftovers
        assert not (path.parent.parent / failed['id']).exists()
        active_ids = [begin('#slow') for _ in range(9)]
        capacity = command('download', 'wait', active_ids[-1])['value']
        assert capacity['status'] == 'failed' and capacity['error'] == 'download_capacity', capacity
        for item in active_ids[:-1]:
            command('download', 'cancel', item)
        # Native file chooser delegate must never activate a background window.
        command('click', '#single')
        chooser = command('state')['page']['fileChooser']
        assert chooser['requiresForeground'] and chooser['status'] == 'requires_foreground', chooser
        assert cli('status')['frontmostPid'] == before['frontmostPid']
        active = begin('#slow')
        cli('tab', 'close', target, '--space', name)
        cli('download', 'wait', active, *flags, error='tab_not_found')
        assert path.exists()
        for _ in range(100):
            if not (state / 'downloads' / work['id'] / target / active).exists():
                break
            time.sleep(.02)
        assert not (state / 'downloads' / work['id'] / target / active).exists()
        target = cli('tab', 'new', urljoin(base, '/files'), '--space', name)['tabId']
        flags = ('--space', name, '--tab', target)
        interrupted = begin('#slow')
        restart()
        assert command('download', 'list')['value']['downloads'] == []
        assert not any(p.is_file() for p in (state / 'downloads' / work['id'] / target / interrupted).rglob('*'))
        assert path.exists()
        report = dict(nativeDownloads=True, completed=2, sameNamePreserved=True, timeoutWithoutReplay=True,
                      cancellation=True, failure=True, tabAndSpaceIsolation=True, retainedAfterRestart=True,
                      foregroundUnchanged=True, completedPath=str(path), capacityVerified=True, shutdownCancellation=True)
        (out / 'downloads.json').write_text(json.dumps(report, indent=2))
        return report
    finally:
        cli('space', 'delete', name)
        cli('space', 'delete', peer)
