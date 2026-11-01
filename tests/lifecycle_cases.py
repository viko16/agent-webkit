"""Real Space runtime release, persistence and on-demand restore."""
from concurrent.futures import ThreadPoolExecutor
import json
import time


def verify_lifecycle(cli, base, out, restart, state, interrupt_restart, site_events=None):
    name, peer = 'sleep-work', 'sleep-peer'
    work = cli('space', 'create', name, '--proxy', 'direct', '--ignore-certificate-errors')
    cli('space', 'create', peer, '--proxy', 'direct')
    target = cli('tab', 'new', base + '?sleep=target', '--space', name)['tabId']
    flags = ('--space', name, '--tab', target)

    def command(*args, **kwargs):
        return cli(*args, *flags, **kwargs)

    try:
        cli('open', base + '?sleep=default', '--space', name)
        cli('open', base, '--space', peer)
        if site_events:
            previous = {tab['tabId'] for tab in cli('tab', 'list', '--space', name)}
            with ThreadPoolExecutor(1) as pool:
                pending_tab = pool.submit(cli, 'tab', 'new', base + '?delay=.6&transaction=late-save', '--space', name, error='operation_failed')
                for _ in range(200):
                    if cli('space', 'info', name)['busy']:
                        break
                    time.sleep(.01)
                else:
                    raise AssertionError('No delayed Tab operation')
                time.sleep(.15)
                assert not pending_tab.done(), 'Navigation completed before failure injection'
                permissions = state.stat().st_mode & 0o777
                try:
                    state.chmod(0o500)
                    response = pending_tab.result()
                finally:
                    state.chmod(permissions)
            created = next(tab['tabId'] for tab in cli('tab', 'list', '--space', name) if tab['tabId'] not in previous)
            assert created in response['error']['message'], response
            cli('tab', 'close', created, '--space', name)
        stable = cli('space', 'info', name)
        command('evaluate', 'window.transactionProbe="kept";true')
        permissions = state.stat().st_mode & 0o777
        try:
            state.chmod(0o500)
            cli('tab', 'new', '--space', name, error='operation_failed')
            cli('tab', 'default', target, '--space', name, error='operation_failed')
            cli('tab', 'close', target, '--space', name, error='operation_failed')
        finally:
            state.chmod(permissions)
        current = cli('space', 'info', name)
        for key in ('defaultTabId', 'tabs', 'liveWebViews'):
            assert current[key] == stable[key], (key, stable, current)
        assert command('evaluate', 'window.transactionProbe')['value'] == 'kept'
        cli('tab', 'new', '--space', peer)
        registry = json.loads((state / 'spaces.json').read_text())
        record = next(record for record in registry if record['id'] == work['id'])
        assert record['defaultTab'] == stable['defaultTabId']
        assert [tab['id'] for tab in record['tabs']] == [tab['tabId'] for tab in stable['tabs']]
        command('evaluate', 'document.cookie="sleep=kept; Max-Age=3600; Path=/";localStorage.sleep="kept";window.memoryOnly=42;true')
        assert command('evaluate', 'document.cookie')['value'] == 'sleep=kept'
        ref = command('snapshot')['value']['elements'][0]['ref']
        original = cli('space', 'info', name)
        before = cli('status')
        with ThreadPoolExecutor(1) as pool:
            pending = pool.submit(command, 'evaluate', 'new Promise(r=>setTimeout(()=>r(true),900))', '--await')
            for _ in range(100):
                if cli('space', 'info', name)['busy']:
                    break
                time.sleep(.01)
            else:
                raise AssertionError('No in-flight operation')
            cli('space', 'suspend', name, error='space_busy')
            cli('space', 'resume', name, error='space_busy')
            assert cli('evaluate', 'document.title', '--space', peer)['value']
            assert pending.result()['value'] is True
        permissions = state.stat().st_mode & 0o777
        try:
            state.chmod(0o500)
            cli('space', 'suspend', name, error='operation_failed')
        finally:
            state.chmod(permissions)
        assert cli('space', 'info', name)['lifecycle'] == 'active'
        command('evaluate', 'setTimeout(()=>confirm("sleep cancellation"),0);true')
        for _ in range(100):
            dialogs = command('dialog', 'list')['value']['dialogs']
            if dialogs:
                break
            time.sleep(.02)
        else:
            raise AssertionError('No autonomous dialog')
        sleeping = cli('space', 'suspend', name)
        assert sleeping['lifecycle'] == 'suspended' and sleeping['liveWebViews'] == 0
        assert cli('space', 'suspend', work['id']) == sleeping
        assert [t['tabId'] for t in sleeping['tabs']] == [t['tabId'] for t in original['tabs']]
        assert [t['url'] for t in sleeping['tabs']] == [t['url'] for t in original['tabs']]
        assert sleeping['tls'] == original['tls'] and sleeping['proxy'] == original['proxy']
        assert sleeping['defaultTabId'] == original['defaultTabId']
        assert command('state')['page']['suspended']
        command('diagnostics', error='space_suspended')
        command('dialog', 'respond', dialogs[0]['id'], 'accept', error='space_suspended')
        command('snapshot', '--tab', 'wrong', error='invalid_arguments')
        cli('snapshot', '--space', name, '--tab', 'wrong', error='tab_not_found')
        cli('tab', 'close', 'wrong', '--space', name, error='tab_not_found')
        cli('tab', 'default', 'wrong', '--space', name, error='tab_not_found')
        cli('open', 'invalid-url', '--space', name, error='invalid_url')
        cli('tab', 'new', 'invalid-url', '--space', name, error='invalid_url')
        assert cli('space', 'info', name)['liveWebViews'] == 0
        assert cli('status')['liveWebViews'] == before['liveWebViews'] - 2
        cli('space', 'suspend', peer)
        peer_extra = cli('tab', 'list', '--space', peer)[1]['tabId']
        requests = len(site_events.items) if site_events else None
        cli('tab', 'default', target, '--space', name)
        cli('tab', 'default', original['defaultTabId'], '--space', name)
        cli('tab', 'default', peer_extra, '--space', peer)
        cli('tab', 'close', peer_extra, '--space', peer)
        assert cli('space', 'info', name)['liveWebViews'] == 0
        assert cli('space', 'info', peer)['liveWebViews'] == 0
        time.sleep(.15)
        if site_events:
            assert len(site_events.items) == requests
        assert cli('status')['frontmostPid'] == before['frontmostPid']
        assert cli('status')['liveWebViews'] == 0
        started = time.monotonic()
        restart()
        restart_ms = (time.monotonic() - started) * 1000
        assert cli('space', 'info', name) == sleeping
        assert len(cli('tab', 'list', '--space', name)) == 2
        assert cli('status')['liveWebViews'] == 0
        assert cli('space', 'info', name)['liveWebViews'] == 0
        interrupt_restart()
        assert cli('space', 'info', name) == sleeping
        assert cli('status')['liveWebViews'] == 0
        # Resume persistence failure must release the newly constructed views again.
        try:
            state.chmod(0o500)
            cli('space', 'resume', name, error='operation_failed')
        finally:
            state.chmod(permissions)
        assert cli('space', 'info', name)['lifecycle'] == 'suspended'
        # A real page command restores the requested nondefault Tab only as target.
        outcome = command('evaluate', '({cookie:document.cookie,local:localStorage.sleep,memory:typeof window.memoryOnly})')['value']
        assert outcome == dict(cookie='sleep=kept', local='kept', memory='undefined'), outcome
        command('click', ref, error='stale_ref')
        command('dialog', 'respond', dialogs[0]['id'], 'accept', error='dialog_not_found')
        assert cli('space', 'info', name)['defaultTabId'] == original['defaultTabId']
        command('screenshot', '--out', str(out / 'resumed.png'))
        command('evaluate', 'while(true){}', '--timeout', '100', error='timeout')
        cli('space', 'suspend', name)
        cli('space', 'resume', name)
        command('wait', '#message')
        assert not command('state')['page']['unresponsive']
        assert cli('space', 'resume', name)['lifecycle'] == 'active'
        cli('space', 'suspend', name)
        deleted = cli('space', 'delete', name)
        assert deleted['websiteDataRemoved']
        replacement = cli('space', 'create', name, '--proxy', 'direct')
        assert replacement['id'] != work['id']
        cli('open', base, '--space', name)
        assert cli('evaluate', 'localStorage.sleep??null', '--space', name)['value'] is None
        assert cli('status')['frontmostPid'] == before['frontmostPid']
        report = dict(lifecycle=True, suspendedWebViews=0, releasedWebViews=2,
                      restartWithSuspendedSpaceMs=restart_ms, persistentOutcome=outcome,
                      busyAndSaveFailure=True, tabTransactions=True, sleepingMetadataKeepsZeroViews=True,
                      dialogAndHungRecovery=True, interruptedRestart=True, deletionVerified=True)
        (out / 'lifecycle.json').write_text(json.dumps(report, indent=2))
        return report
    finally:
        for item in cli('space', 'list'):
            if item['name'] in (name, peer):
                cli('space', 'delete', item['id'])
