"""Real WKUIDelegate dialogs while the original CLI request owns the Space lock."""
from concurrent.futures import ThreadPoolExecutor
import json
import sys
import time
from urllib.parse import urljoin


def verify_dialogs(cli, base, out, restart, state):
    name, peer = 'dialogs', 'dialogs-peer'
    work = cli('space', 'create', name, '--proxy', 'direct')
    cli('space', 'create', peer, '--proxy', 'direct')
    tab = work['defaultTabId']
    flags = ('--space', name, '--tab', tab)
    url = urljoin(base, '/dialogs')

    def command(*args, **kwargs):
        return cli(*args, *flags, **kwargs)

    def pending(target=tab):
        for _ in range(100):
            result = cli('dialog', 'list', '--space', name, '--tab', target)
            if result['value']['dialogs']:
                return result, result['value']['dialogs'][0]
            time.sleep(.02)
        raise AssertionError('No pending dialog')

    try:
        command('open', url)
        cli('open', url, '--space', peer)
        before = cli('status')
        command('dialog', 'respond', 'unknown', 'yes', error='invalid_arguments')
        command('dialog', 'list', '--text', 'wrong', error='invalid_arguments')
        command('dialog', 'respond', 'unknown', 'accept', error='dialog_not_found')
        cases = [('alert', 'accept', None, 'alert-continued'), ('alert', 'dismiss', None, 'alert-continued'),
                 ('confirm', 'accept', None, True), ('confirm', 'dismiss', None, False),
                 ('prompt', 'accept', '你好\nquoted "value"', '你好\nquoted "value"'),
                 ('prompt', 'accept', '', ''), ('prompt', 'accept', None, 'default value'),
                 ('prompt', 'dismiss', None, None)]
        ids = []
        with ThreadPoolExecutor(2) as pool:
            for kind, action, text, expected in cases:
                future = pool.submit(command, 'click', '#' + kind, '--timeout', '5000')
                envelope, dialog = pending()
                assert envelope['busy'] and dialog['type'] == kind and not dialog['requiresForeground']
                assert dialog['message'] and dialog['mainFrame']
                assert dialog['defaultText'] == ('default value' if kind == 'prompt' else None)
                assert command('state')['page']['pendingDialogs'] == 1
                assert command('diagnostics')['busy']
                assert not future.done(), 'Dialog was silently handled'
                command('snapshot', error='space_busy')
                cli('dialog', 'respond', dialog['id'], 'accept', '--space', peer, error='dialog_not_found')
                assert cli('evaluate', 'document.title', '--space', peer)['value'] == 'JavaScript dialog fixture'
                if kind == 'confirm':
                    command('dialog', 'respond', dialog['id'], 'accept', '--text', 'invalid', error='invalid_arguments')
                args = ('--text', text) if text is not None else ()
                response = command('dialog', 'respond', dialog['id'], action, *args)
                assert response['value']['handled'] and response['value']['businessOutcomeVerified'] is False
                assert future.result(timeout=8)['value']['nativeVerified'] is False
                command('wait', '#result', '--text', json.dumps(expected, ensure_ascii=False, separators=(',', ':')))
                assert command('evaluate', 'window.dialogResults.at(-1)')['value'] == expected
                command('dialog', 'respond', dialog['id'], action, error='dialog_already_handled')
                ids.append(dialog['id'])
            # Both Spaces can wait for their own dialogs without routing replies across them.
            first = pool.submit(command, 'click', '#confirm', '--timeout', '5000')
            _, a = pending()
            second = pool.submit(cli, 'click', '#confirm', '--space', peer, '--timeout', '5000')
            for _ in range(100):
                dialogs = cli('dialog', 'list', '--space', peer)['value']['dialogs']
                if dialogs:
                    break
                time.sleep(.02)
            else:
                raise AssertionError('No peer dialog')
            cli('dialog', 'respond', dialogs[0]['id'], 'dismiss', '--space', peer)
            command('dialog', 'respond', a['id'], 'accept')
            first.result(timeout=8); second.result(timeout=8)
            assert cli('evaluate', 'window.dialogResults.at(-1)', '--space', peer)['value'] is False
            assert command('evaluate', 'window.dialogResults.at(-1)')['value'] is True
            # A modal wait expiring is not evidence that the content process is hung.
            expired = pool.submit(command, 'click', '#confirm', '--timeout', '400', error='timeout')
            _, dialog = pending()
            expired.result(timeout=4)
            command('dialog', 'respond', dialog['id'], 'accept', error='dialog_expired')
            assert not command('state')['page']['unresponsive']
            assert command('evaluate', 'window.dialogResults.at(-1)')['value'] is False
        assert len(set(ids)) == len(cases)
        assert command('evaluate', 'window.dialogCalls')['value'] == len(cases) + 2
        assert command('dialog', 'list')['value']['dialogs'] == []
        with ThreadPoolExecutor(1) as pool:
            chain = pool.submit(command, 'click', '#chain', '--timeout', '5000')
            _, first = pending()
            command('dialog', 'respond', first['id'], 'accept')
            _, second = pending()
            assert first['id'] != second['id'] and second['type'] == 'prompt'
            command('dialog', 'respond', first['id'], 'accept', error='dialog_already_handled')
            command('dialog', 'respond', second['id'], 'accept', '--text', 'chain value')
            chain.result(timeout=8)
            assert command('evaluate', 'window.dialogResults.at(-1)')['value'] == [True, 'chain value']
            # A full document navigation can itself be waiting for the new page's dialog.
            opening = pool.submit(command, 'open', url + '?initial=1', '--timeout', '5000')
            envelope, initial = pending()
            assert envelope['busy'] and initial['message'] == 'Initial navigation'
            command('dialog', 'respond', initial['id'], 'dismiss')
            opening.result(timeout=8)
            assert command('evaluate', 'window.dialogResults.at(-1)')['value'] is False
            # Dialogs from a frame belong to its host Tab, with their own origin/frame metadata.
            command('evaluate', 'new Promise(resolve=>{const frame=document.createElement("iframe"); frame.src="/dialogs"; frame.onload=()=>resolve(true); document.body.append(frame)})', '--await')
            framed = pool.submit(command, 'evaluate', 'document.querySelector("iframe").contentWindow.confirm("Frame confirm")', '--timeout', '5000')
            _, frame = pending()
            assert not frame['mainFrame'] and frame['origin'] == urljoin(base, '/').rstrip('/')
            command('dialog', 'respond', frame['id'], 'accept')
            assert framed.result(timeout=8)['value'] is True
            command('evaluate', 'Boolean(window.open("/dialogs"))')
            child = next(item['tabId'] for item in cli('tab', 'list', '--space', name) if item['tabId'] != tab)
            cli('wait', '--space', name, '--tab', child)
            popup = pool.submit(cli, 'click', '#prompt', '--space', name, '--tab', child, '--timeout', '5000')
            _, popup_dialog = pending(child)
            assert command('dialog', 'list')['value']['dialogs'] == []
            command('dialog', 'respond', popup_dialog['id'], 'accept', error='dialog_not_found')
            cli('dialog', 'respond', popup_dialog['id'], 'accept', '--text', 'popup value', '--space', name, '--tab', child)
            popup.result(timeout=8)
            assert cli('evaluate', 'window.dialogResults.at(-1)', '--space', name, '--tab', child)['value'] == 'popup value'
            cli('tab', 'close', child, '--space', name)
        command('evaluate', 'setTimeout(()=>confirm("Navigation cancellation"),0); true')
        _, obsolete = pending()
        assert not cli('space', 'info', name)['busy']
        command('open', url)
        command('dialog', 'respond', obsolete['id'], 'accept', error='dialog_cancelled')
        assert command('dialog', 'list')['value']['dialogs'] == []
        assert command('evaluate', 'window.dialogCalls')['value'] == 0
        closing = cli('tab', 'new', url, '--space', name)['tabId']
        cli('evaluate', 'setTimeout(()=>{confirm("Close cancellation");alert("Late close callback")},0); true', '--space', name, '--tab', closing)
        pending(closing)
        cli('tab', 'close', closing, '--space', name)
        cli('dialog', 'list', '--space', name, '--tab', closing, error='tab_not_found')
        # A failed shutdown must leave a live service able to handle subsequent dialogs.
        permissions = state.stat().st_mode & 0o777
        try:
            state.chmod(0o500)
            cli('shutdown', error='operation_failed')
        finally:
            state.chmod(permissions)
        assert cli('status')['ready']
        command('evaluate', 'setTimeout(()=>window.afterFailedShutdown=confirm("After failed shutdown"),0); true')
        _, recovered = pending()
        command('dialog', 'respond', recovered['id'], 'accept')
        assert command('evaluate', 'window.afterFailedShutdown')['value'] is True
        command('evaluate', 'setTimeout(()=>prompt("Restart cancellation","old default"),0); true')
        _, obsolete = pending()
        restart()
        command('wait')
        assert command('dialog', 'list')['value']['dialogs'] == []
        command('dialog', 'respond', obsolete['id'], 'accept', error='dialog_not_found')
        command('evaluate', 'setTimeout(()=>window.backgroundAnswer=confirm("Background expiry"),0); true')
        envelope, background = pending()
        assert not envelope['busy'] and 14000 < background['expiresAtMs'] - time.time() * 1000 <= 15000
        end = time.monotonic() + 17
        while command('dialog', 'list')['value']['dialogs'] and time.monotonic() < end:
            time.sleep(.1)
        command('dialog', 'respond', background['id'], 'accept', error='dialog_expired')
        assert command('evaluate', 'window.backgroundAnswer')['value'] is False
        assert not command('state')['page']['unresponsive']
        after = cli('status')
        assert after['observer'] == before['observer'] and after['frontmostPid'] == before['frontmostPid']
        assert cli('space', 'info', name)['defaultTabId'] == tab
        report = dict(dialogs=True, explicitCases=len(cases), uniqueIDs=len(ids),
                      busyReplyVerified=True, spaceIsolation=True, expiryVerified=True, foregroundUnchanged=True,
                      lifecycle=['chained dialogs', 'initial navigation', 'frame and popup ownership', 'navigation cancellation', 'close with late callback', 'failed shutdown remains usable', 'restart resets pending IDs', 'real 15s autonomous expiry'])
        (out / 'dialogs.json').write_text(json.dumps(report, indent=2))
        return report
    finally:
        failed = sys.exc_info()[0] is not None
        errors = []
        for target in (name, peer):
            try:
                cli('space', 'delete', target)
            except Exception as error:
                errors.append(str(error))
        if errors:
            (out / 'dialog-cleanup-errors.json').write_text(json.dumps(errors, indent=2))
            if not failed:
                raise AssertionError(errors)
