"""Real WKUIDelegate dialogs while the original CLI request owns the Space lock."""
from concurrent.futures import ThreadPoolExecutor
import json
import sys
import time
from urllib.parse import urljoin


def verify_dialogs(cli, base, out):
    name, peer = 'dialogs', 'dialogs-peer'
    work = cli('space', 'create', name, '--proxy', 'direct')
    cli('space', 'create', peer, '--proxy', 'direct')
    tab = work['defaultTabId']
    flags = ('--space', name, '--tab', tab)
    url = urljoin(base, '/dialogs')

    def command(*args, **kwargs):
        return cli(*args, *flags, **kwargs)

    def pending():
        for _ in range(100):
            result = command('dialog', 'list')
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
        after = cli('status')
        assert after['observer'] == before['observer'] and after['frontmostPid'] == before['frontmostPid']
        assert cli('space', 'info', name)['defaultTabId'] == tab
        report = dict(dialogs=True, explicitCases=len(cases), uniqueIDs=len(ids),
                      busyReplyVerified=True, spaceIsolation=True, expiryVerified=True, foregroundUnchanged=True)
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
