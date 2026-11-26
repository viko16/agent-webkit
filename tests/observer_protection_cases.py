"""Observer actions run in the fixture app; Agent requests go through the actual CLI."""
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
import time
from urllib.parse import urljoin


def verify_observer_protection(cli, native, binary, env, base, events):
    name = 'observer-work'
    space = cli('space', 'create', name, '--proxy', 'direct')
    first = space['tabs'][0]['tabId']
    second = cli('tab', 'new', '--space', name)['tabId']
    native(name, 'choose')

    def cmd(tab, *args):
        return cli(*args, '--space', name, '--tab', tab)

    def error(tab, expected, *args):
        run = subprocess.run([str(binary), *args, '--space', name, '--tab', tab],
                             env=env, capture_output=True, text=True, timeout=12)
        assert run.returncode == 1 and json.loads(run.stdout)['error']['code'] == expected, (args, run.stdout)

    def probe(action='inspect', tab=None, **options):
        return native(name, action, tab=tab or first, **options)

    def click(action, tab=None, **options):
        result = probe(action, tab, **options)
        assert result['probe']['dispatched'], (action, result)
        return result

    def sheet(button):
        return click('sheet', button=button)

    def until(get):
        for _ in range(80):
            value = get()
            if value:
                return value
            time.sleep(.03)
        raise AssertionError('Expected fixture state was never observed')

    def dialogs(tab):
        return cmd(tab, 'dialog', 'list')['value']['dialogs']

    def poll():
        for args in [('state',), ('dialog', 'list'), ('download', 'list'), ('diagnostics',),
                     ('viewport', 'get'), ('frame', 'list'), ('snapshot',), ('wait',)]:
            cmd(first, *args)

    for args in [('state',), ('dialog', 'list'), ('download', 'list'), ('diagnostics',)]:
        cmd(first, *args)
    assert probe()['probe']['finished'] is None
    error(first, 'dialog_not_found', 'dialog', 'respond', 'missing', 'accept')
    error(first, 'download_not_found', 'download', 'cancel', 'missing')
    assert probe()['probe']['finished'] is None
    cmd(first, 'open', base)
    finished = probe()['probe']['finished']
    assert finished is not None
    poll()
    assert probe()['probe']['finished'] == finished
    with ThreadPoolExecutor(1) as pool:
        waiting = pool.submit(error, second, 'timeout', 'wait', '#never-created', '--timeout', '1600')
        until(lambda: cli('space', 'info', name)['busy'])
        assert probe(tab=second)['probe']['executing'] == 1
        error(first, 'space_busy', 'evaluate', '42')
        error(first, 'space_busy', 'diagnostics', '--detail', 'on')
        assert probe()['probe']['finished'] == finished
        waiting.result(timeout=5)
    probe('expire-history')
    poll()
    assert not probe()['probe']['recent']

    # An Agent popup stays with its opener. Only the native view action selects the child.
    click('pick', second)
    cmd(first, 'open', urljoin(base, '/popups'))
    child = cmd(first, 'click', '#blank', '--wait-for-popup')['value']['newTabId']
    background = probe()
    assert background['displayedTabId'] == second and background['probe']['popupNoticeTabId'] is None, background
    parent = click('pick', first)
    assert parent['displayedTabId'] == first and parent['probe']['popupNoticeTabId'] == child, parent
    assert click('view-popup')['displayedTabId'] == child
    assert click('pick', first)['probe']['popupNoticeTabId'] is None
    cmd(child, 'tab', 'close')
    cmd(first, 'open', base)

    # An interrupted GET leaves its old document intact. The banner and toolbar have different targets.
    click('pick', first)
    failed_path = '/diagnostic-drop?observer-retry'
    failed_url = urljoin(base, failed_path)
    cmd(first, 'evaluate', f'setTimeout(()=>location.assign({json.dumps(failed_url)}),50);true')
    until(lambda: failed_url in probe()['probe']['bannerText'])
    def failed_requests():
        return sum(row.get('path') == failed_path for row in events.items)
    before_retry = failed_requests()
    click('retry-navigation')
    until(lambda: failed_requests() > before_retry)
    until(lambda: not cli('space', 'info', name)['busy'])
    retried = probe()
    if retried['errorSheet']:
        sheet(retried['probe']['buttons'][0])
    click('reload')
    until(lambda: cmd(first, 'state')['page']['requestedURL'] == base)
    cmd(first, 'wait', '#message')

    # A failed form submission can already have changed server state.
    cmd(first, 'evaluate', f"""const f=document.createElement('form'); f.method='POST';
        f.action={json.dumps(failed_url)}; document.body.append(f); setTimeout(()=>f.submit(),50);true""")
    until(lambda: failed_url in probe()['probe']['bannerText'])
    assert not probe()['probe']['retryVisible']
    click('reload')
    cmd(first, 'wait', '#message')

    # A waiting page stays in its own tab; ordinary observer refreshes keep the user's reply.
    click('pick', second)
    cmd(first, 'evaluate', 'setTimeout(()=>window.nativeReply=prompt("问题\\n".repeat(100),"default"),50);true')
    prompt_id = until(lambda: dialogs(first))[0]['id']
    background = probe()
    assert background['displayedTabId'] == second and background['probe']['tabWaiting']
    assert background['probe']['dialogID'] is None
    prompt = click('pick', first)['probe']
    assert prompt['dialogID'] == prompt_id and prompt['promptText'] == 'default'
    probe('edit-prompt', text='用户输入')
    assert probe()['probe']['promptText'] == '用户输入'
    click('answer-dialog', button='确定')
    assert cmd(first, 'evaluate', 'window.nativeReply')['value'] == '用户输入'
    assert probe()['probe']['dialogID'] is None

    cmd(first, 'evaluate', 'setTimeout(()=>window.nativeReply=prompt("long default","x".repeat(5000)),50);true')
    until(lambda: dialogs(first))
    assert len(probe()['probe']['promptText']) == 4096
    click('answer-dialog', button='确定')
    assert cmd(first, 'evaluate', 'window.nativeReply.length')['value'] == 5000

    cmd(first, 'fill', '#message', 'keep this draft')
    assert '未提交的表单' in click('suspend')['probe']['sheetText']
    sheet('取消')
    assert cmd(first, 'evaluate', "document.querySelector('#message').value")['value'] == 'keep this draft'

    # A generic deletion sheet cannot authorize a dialog that arrives later.
    assert click('delete')['errorSheet']
    cmd(first, 'evaluate', 'setTimeout(()=>{confirm("one"); confirm("two")}, 50);true')
    initial = until(lambda: dialogs(first))[0]['id']
    changed = sheet('删除 Space')
    assert '对话框' in changed['probe']['sheetText'], changed
    sheet('取消')
    assert dialogs(first)[0]['id'] == initial
    probe('expire-history')
    warning = click('close')
    assert '对话框' in warning['probe']['sheetText'] and '5 分钟' not in warning['probe']['sheetText'], warning
    assert 'Agent WebKit Fixture' in warning['probe']['sheetText'] and '127.0.0.1' in warning['probe']['sheetText'], warning
    cmd(first, 'dialog', 'respond', initial, 'dismiss')
    successor = until(lambda: dialogs(first))[0]['id']
    assert successor != initial
    probe('expire-history')  # Only the dialog ID differs from the confirmed impact.
    warning = sheet('关闭标签页')
    assert '对话框' in warning['probe']['sheetText'] and dialogs(first)[0]['id'] == successor
    sheet('取消')
    click('pick', first)
    assert '对话框' in click('reload')['probe']['sheetText']
    sheet('取消')
    assert '对话框' in click('suspend')['probe']['sheetText']
    sheet('取消')
    assert dialogs(first)[0]['id'] == successor
    click('suspend')
    sheet('休眠 Space')
    sleeping = cli('space', 'info', name)
    assert sleeping['lifecycle'] == 'suspended' and sleeping['liveWebViews'] == 0
    cli('space', 'resume', name)

    # A delayed GUI confirmation must not wake a Space put to sleep by the Agent.
    cmd(first, 'wait', '#message')
    cmd(first, 'evaluate', 'setTimeout(()=>confirm("navigation"), 50);true')
    until(lambda: dialogs(first))
    assert '对话框' in click('reload')['probe']['sheetText']
    cli('space', 'suspend', name)
    stale = sheet('重新加载页面')
    assert not stale['errorSheet'] and cli('space', 'info', name)['liveWebViews'] == 0, stale
    cli('space', 'resume', name)

    cmd(first, 'open', urljoin(base, '/files'))
    cmd(first, 'evaluate', 'document.querySelector("#slow").href="/download?mode=held";true')
    cmd(first, 'click', '#slow')

    def downloads():
        return cmd(first, 'download', 'list')['value']['downloads']
    cancelled = until(downloads)[0]['id']
    click('pick', second)
    blocked = click('suspend')
    assert '管理下载' in blocked['probe']['buttons'], blocked
    manager = sheet('管理下载')
    assert manager['probe']['downloadsSpaceId'] == space['id'] and manager['displayedTabId'] == second, manager
    probe('dismiss-downloads')
    click('pick', first)
    probe('expire-history')
    assert cmd(first, 'download', 'cancel', cancelled)['value']['status'] == 'cancelled'
    finished = probe()['probe']['finished']
    assert probe()['probe']['recent']
    cmd(first, 'download', 'cancel', cancelled)
    cmd(first, 'download', 'wait', cancelled)
    assert probe()['probe']['finished'] == finished
    cmd(first, 'click', '#slow')
    download = until(lambda: next((item['id'] for item in downloads() if item['id'] != cancelled), None))
    expired = probe('expire-history')['probe']['finished']
    with ThreadPoolExecutor(1) as pool:
        waiting = pool.submit(error, first, 'timeout', 'download', 'wait', download, '--timeout', '1400')
        until(lambda: probe()['probe']['executing'])
        assert not probe('close')['probe']['dispatched']
        waiting.result(timeout=5)
    assert probe()['probe']['finished'] == expired
    warning = click('close')
    assert '下载' in warning['probe']['sheetText'] and '5 分钟' not in warning['probe']['sheetText'], warning
    sheet('取消')
    assert any(item['id'] == download and item['status'] == 'running' for item in downloads())
    assert '下载' in click('quit')['probe']['sheetText']
    sheet('取消')
    assert cli('status')['ready']
    assert '下载' in click('delete')['probe']['sheetText']
    sheet('取消')
    click('close')
    sheet('关闭标签页')
    assert [t['tabId'] for t in cli('tab', 'list', '--space', name)] == [second]
    cli('space', 'delete', name)

    name = 'observer-neighbors'
    first = cli('space', 'create', name, '--proxy', 'direct')['tabs'][0]['tabId']
    native(name, 'choose')
    def new_tab():
        return cli('tab', 'new', '--space', name)['tabId']
    middle, right = new_tab(), new_tab()
    assert click('pick', middle)['displayedTabId'] == middle
    probe('expire-history', middle)
    result = click('cmd-w', middle)
    assert result['displayedTabId'] == right and not result['errorSheet'], result
    assert click('cmd-w', right)['errorSheet']
    sheet('取消')
    assert probe()['displayedTabId'] == right
    click('cmd-w', right)
    assert sheet('关闭标签页')['displayedTabId'] == first
    last = probe('close', first)['probe']
    assert not last['dispatched'] and '至少保留一个标签页' in last['lastTabHelp'], last
    assert last['tabButtonWidth'] >= 140, last
    middle, right = new_tab(), new_tab()
    assert click('pick', middle)['displayedTabId'] == middle
    cmd(middle, 'tab', 'close')
    assert probe()['displayedTabId'] == right
    assert click('close', right)['errorSheet']
    click('pick', first)
    assert sheet('关闭标签页')['displayedTabId'] == first
    middle = new_tab()
    click('close', middle)
    # A concurrent Agent close makes the pending target the final Tab.
    cmd(first, 'tab', 'close')
    guarded = sheet('关闭标签页')
    assert '最后' in guarded['message'] and guarded['displayedTabId'] == middle, guarded
    native(name)  # dismiss fixture error sheet
    first = new_tab()
    click('close', first)
    cmd(first, 'tab', 'close')
    guarded = sheet('关闭标签页')
    assert '不存在' in guarded['message'] and guarded['displayedTabId'] == middle, guarded
    native(name)
    first = new_tab()
    click('close', first)
    with ThreadPoolExecutor(1) as pool:
        waiting = pool.submit(error, middle, 'timeout', 'wait', '#never-created', '--timeout', '1600')
        until(lambda: cli('space', 'info', name)['busy'])
        guarded = sheet('关闭标签页')
        assert '操作' in guarded['message'], guarded
        waiting.result(timeout=5)
    native(name)
    probe('expire-history', first)
    assert click('close', first)['displayedTabId'] == middle
    before = cli('status')
    assert not click('shift-cmd-w', middle)['probe']['visible']
    after = cli('status')
    assert before['pid'] == after['pid'] and not after['observer']['visible']
