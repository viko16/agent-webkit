"""Real document identity, invalid restored configuration and JS error boundaries."""
import json
import os
import socket
import sys
import time


def verify_state_integrity(cli, base, out, start, stop, state):
    names = ('identity-work', 'config-healthy', 'config-bad', 'config-bad-suspended')
    created = []
    running = True
    registry = state / 'spaces.json'
    try:
        for name in names:
            created.append(cli('space', 'create', name, '--proxy', 'direct'))
        flags = ('--space', names[0])
        original_url = base + '?identity=original'
        cli('open', original_url, *flags)
        cli('evaluate', 'document.querySelector("#result").textContent="Document A survives";true', *flags)
        # macOS may leave bound-but-not-listening sockets pending; close to refuse.
        with socket.socket() as refused:
            refused.bind(('127.0.0.1', 0))
            failed_url = f'http://127.0.0.1:{refused.getsockname()[1]}/unreachable'
            refused.close()
            cli('open', failed_url, '--timeout', '10000', *flags, error='operation_failed')
        page = cli('state', *flags)['page']
        assert page['url'] == page['committedDocumentURL'] == page['restoreURL'] == original_url, page
        assert page['requestedURL'] == failed_url, page
        assert cli('evaluate', 'location.href', *flags)['value'] == original_url
        snapshot = cli('snapshot', *flags)['value']
        assert 'Document A survives' in snapshot['text'], snapshot
        cli('evaluate', 'history.pushState({},"","?identity=spa");true', *flags)
        original_url = base + '?identity=spa'
        for _ in range(100):
            page = cli('state', *flags)['page']
            if page['url'] == page['restoreURL'] == original_url:
                break
            time.sleep(.02)
        else:
            raise AssertionError(page)
        saved = next(record for record in json.loads(registry.read_text()) if record['id'] == created[0]['id'])
        assert saved['tabs'][0]['url'] == original_url, saved
        stop(); running = False
        start(); running = True
        cli('wait', '#message', *flags)
        assert cli('state', *flags)['page']['url'] == original_url
        assert cli('evaluate', 'location.href', *flags)['value'] == original_url

        # Cancel a restoration load with an explicit load of the same URL. WebKit
        # may release the first token without a terminal callback; a later token
        # must not be mistaken for it when the native allocator reuses an address.
        overlap_url = base + '?delay=1&identity=overlap'
        cli('open', overlap_url, *flags)
        stop(); running = False
        start(); running = True
        cli('open', overlap_url, *flags)
        cli('open', original_url, *flags)
        assert cli('state', *flags)['page']['url'] == original_url

        stop(); running = False
        records = json.loads(registry.read_text())
        next(record for record in records if record['id'] == created[0]['id'])['tabs'][0]['url'] = failed_url
        temporary = state / 'failed-restore.tmp'
        temporary.write_text(json.dumps(records)); os.replace(temporary, registry)
        start(); running = True
        cli('wait', '--timeout', '10000', *flags, error='operation_failed')
        page = cli('state', *flags)['page']
        assert page['url'] == page['committedDocumentURL'] == 'about:blank', page
        assert page['restoreURL'] == page['requestedURL'] == failed_url, page
        assert cli('evaluate', 'location.href', *flags)['value'] == 'about:blank'
        cli('open', original_url, *flags)

        for message in ('stale_ref', 'selector_count', 'page stale_ref: ordinary failure'):
            quoted = json.dumps(message)
            response = cli('evaluate', f'(()=>{{throw new Error({quoted})}})()', *flags, error='javascript_error')
            assert message in response['error']['message'], response
            response = cli('evaluate', f'Promise.reject(new Error({quoted}))', '--await', *flags, error='javascript_error')
            assert message in response['error']['message'], response
        old_ref = next(element['ref'] for element in cli('snapshot', *flags)['value']['elements'] if element['tag'] == 'button')
        # Exercise the product recovery route, retaining an actual pre-hang ref.
        cli('evaluate', 'while(true) {}', '--timeout', '100', *flags, error='timeout')
        assert cli('state', *flags)['page']['unresponsive']
        cli('reload', '--timeout', '5000', *flags)
        cli('click', old_ref, *flags, error='stale_ref')
        old_ref = next(element['ref'] for element in cli('snapshot', *flags)['value']['elements'] if element['tag'] == 'button')
        cli('evaluate', 'document.querySelector("#save").remove();true', *flags)
        cli('click', old_ref, *flags, error='stale_ref')

        cli('open', base + '?configuration=healthy', '--space', names[1])
        cli('open', base + '?configuration=bad', '--space', names[2])
        cli('tab', 'new', base + '?configuration=bad-extra', '--space', names[2])
        cli('tab', 'new', base + '?configuration=bad-third', '--space', names[2])
        cli('open', base + '?configuration=suspended', '--space', names[3])
        cli('space', 'suspend', names[3])
        expected_tabs = {name: [(tab['tabId'], tab['url']) for tab in cli('tab', 'list', '--space', name)]
                         for name in names[2:]}
        stop(); running = False
        records = json.loads(registry.read_text())
        invalid_proxy = 'http://remote.invalid:8899'
        for record in records:
            if record['name'] in names[2:]:
                record['proxy'] = invalid_proxy
        temporary = state / 'invalid-config.tmp'
        temporary.write_text(json.dumps(records))
        os.replace(temporary, registry)
        start(); running = True
        assert cli('status')['ready']
        cli('wait', '#message', '--space', names[1])
        assert cli('evaluate', 'location.href', '--space', names[1])['value'] == base + '?configuration=healthy'
        for name in names[2:]:
            info = cli('space', 'info', name)
            assert info['configurationError']['code'] == 'invalid_proxy', info
            assert info['liveWebViews'] == 0 and info['proxy'] == invalid_proxy, info
            tabs = cli('tab', 'list', '--space', name)
            assert [(tab['tabId'], tab['url']) for tab in tabs] == expected_tabs[name], tabs
            impact = next(space for space in cli('status')['shutdownImpact']['spaces'] if space['spaceId'] == info['id'])
            assert impact['tabIds'] == [tab_id for tab_id, _ in expected_tabs[name]], impact
            cli('snapshot', '--space', name, error='invalid_proxy')
            cli('open', base, '--space', name, error='invalid_proxy')
            cli('space', 'resume', name, error='invalid_proxy')
            assert cli('space', 'info', name)['liveWebViews'] == 0
            assert cli('space', 'delete', name)['websiteDataRemoved']
        report = dict(passed=True, failedNavigationKeepsDocumentIdentity=True,
                      spaURLUpdatesAfterFailedNavigation=True, failedRestoreReportsActualBlankDocument=True,
                      cancelledRestoreTokenCannotAliasNewNavigation=True,
                      restoreURLSurvivesFailureAndRestart=True, pageErrorsRemainJavascriptErrors=True,
                      genuineStaleReferenceRejected=True, invalidActiveAndSuspendedConfigurationIsolated=True,
                      invalidConfigurationPreservesTabs=True, invalidConfigurationShutdownImpactComplete=True, noProxyFallback=True)
    finally:
        original_failure = sys.exc_info()[0] is not None
        cleanup_errors = []
        if not running:
            try:
                start(); running = True
            except Exception as error:
                cleanup_errors.append(str(error))
        if running:
            try:
                remaining = {space['id'] for space in cli('space', 'list')}
            except Exception as error:
                cleanup_errors.append(str(error))
                remaining = {space['id'] for space in created}
            for space in created:
                if space['id'] in remaining:
                    try:
                        assert cli('space', 'delete', space['id'])['websiteDataRemoved']
                    except Exception as error:
                        cleanup_errors.append(f"{space['name']}: {error}")
        if cleanup_errors:
            (out / 'state-integrity-cleanup-errors.json').write_text(json.dumps(cleanup_errors, indent=2))
            if not original_failure:
                raise AssertionError(f'State integrity cleanup failed: {cleanup_errors}')
    (out / 'state-integrity.json').write_text(json.dumps(report, indent=2))
    return report
