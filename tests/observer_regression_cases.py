"""Exercise observer controls against real CLI operations in the isolated AppKit fixture."""
import time


def verify_observer_regressions(cli, native, base):
    name, peer = 'test-batch', 'test-batch-peer'
    first = cli('space', 'create', name, '--proxy', 'direct')['tabs'][0]['tabId']
    peer_id = cli('space', 'create', peer, '--proxy', 'direct')['tabs'][0]['tabId']
    native(name, 'choose')

    def command(tab, *args):
        return cli(*args, '--space', name, '--tab', tab)

    def action(kind, **opts):
        result = native(name, kind, **opts)
        assert result['probe']['dispatched'], (kind, result)
        return result

    def wait_for(read):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            value = read()
            if value:
                return value
            time.sleep(.025)
        raise AssertionError(f'Condition timed out: {read}')

    def confirm(button):
        return action('sheet', button=button)

    def new():
        return cli('tab', 'new', '--space', name)['tabId']

    def tabs(space=name):
        return [row['tabId'] for row in cli('tab', 'list', '--space', space)]

    second, keep = new(), new()
    action('pick', tab=first)
    action('details')
    def details(tab):
        data = native(name, 'inspect-details')['probe']
        return data.get('visible') and data['tabID'] == tab
    wait_for(lambda: details(first))
    action('pick', tab=second)
    wait_for(lambda: details(second))
    action('details')

    # Stop an in-flight provisional load, then overlap another stop with a replacement navigation.
    command(second, 'open', base)
    def start_slow():
        command(second, 'evaluate', 'setTimeout(()=>location.assign("?delay=3"),100);true')
        wait_for(lambda: command(second, 'state')['page']['loading'])
    start_slow()
    action('stop')
    def stopped():
        page = command(second, 'state')['page']
        return page if not page['loading'] and page['navigationPhase'] == 'provisional-failure' else None
    page = wait_for(stopped)
    assert page['url'] == page['committedDocumentURL'] == base and page['lastError'] is None, page
    start_slow()
    old_id = command(second, 'state')['page']['navigationId']
    action('stop-delay-callback')
    def held():
        probe = native(name, 'inspect-cancellation')['probe']
        return probe if probe['held'] else None
    pending = wait_for(held)['pending']
    page = command(second, 'state')['page']
    assert (page['loading'], page['navigationPhase'], pending) == (False, 'provisional-failure', False), (page, pending)
    assert page['url'] == page['committedDocumentURL'] == base and page['lastError'] is None, page
    replacement = base + '?replacement'
    command(second, 'open', replacement)
    replacement_id = command(second, 'state')['page']['navigationId']
    action('release-cancellation')
    page = command(second, 'state')['page']
    assert old_id != replacement_id == page['navigationId']
    events = command(second, 'diagnostics')['value']['events']
    assert not any(e['kind'] == 'navigation-failed' and e.get('navigationId') == old_id for e in events), events
    assert page['url'] == replacement and page['navigationPhase'] == 'finished' and page['lastError'] is None, page

    # A subresource started by a finished document has no new main navigation to cancel.
    command(second, 'evaluate', """window.testImage = new Image();
        testImage.src = '/resource?delay=3&image'; !testImage.complete""")
    assert command(second, 'evaluate', '!testImage.complete')['value'] is True
    action('stop-subresources')
    page = command(second, 'state')['page']
    assert (page['navigationId'], page['navigationPhase'], page['url'], page['lastError']) == (
        replacement_id, 'finished', replacement, None), page

    # A new dialog while the second sheet is open must require another, specific confirmation.
    assert action('close-others', tab=keep)['errorSheet']
    command(first, 'evaluate', '1')
    assert confirm('关闭其他标签页')['errorSheet']
    command(first, 'evaluate', 'setTimeout(()=>confirm("batch"),10);true')
    wait_for(lambda: command(first, 'dialog', 'list')['value']['dialogs'])
    again = confirm('关闭并继续')
    assert again['errorSheet'] and '对话框' in again['probe']['sheetText'] and tabs() == [first, second, keep], again
    confirm('关闭并继续')
    assert tabs() == [keep]

    # Only the second original candidate changes. The first stays closed on cancel.
    for cancel in [True, False]:
        first, second = new(), new()
        assert action('close-others', tab=keep)['errorSheet']
        command(second, 'evaluate', '2')
        assert confirm('关闭其他标签页')['errorSheet'] and tabs() == [keep, second]
        added = new()
        confirm('取消' if cancel else '关闭并继续')
        assert tabs() == ([keep, second, added] if cancel else [keep, added])
        if cancel:
            command(second, 'tab', 'close')
        command(added, 'tab', 'close')

    # The kept UUID disappears while the reconfirmation sheet is open.
    first, second = new(), new()
    assert action('close-others', tab=keep)['errorSheet']
    command(first, 'evaluate', '3')
    assert confirm('关闭其他标签页')['errorSheet']
    command(keep, 'tab', 'close')
    halted = confirm('关闭并继续')
    assert '已停止' in halted['probe']['sheetText'] and tabs() == [first, second], halted
    native(name)  # Dismiss the error sheet.
    assert tabs(peer) == [peer_id]
    for space in (peer, name):
        cli('space', 'delete', space)
