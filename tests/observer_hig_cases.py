"""Drive observer menu items, native fields and error disclosure in the isolated AppKit fixture."""
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urljoin
import json
import time


def verify_observer_hig(cli, native, base):
    name, peer = 'hig-main', 'hig-peer'
    space = cli('space', 'create', name, '--proxy', 'direct')
    tab = space['tabs'][0]['tabId']
    other = cli('space', 'create', peer, '--proxy', 'direct')['tabs'][0]['tabId']
    def op(*args):
        return cli(*args, '--space', name, '--tab', tab)

    def probe(action='inspect-hig', **options):
        return native('', action, **options)['probe']

    def menu(section, selector, run='no'):
        item = probe('hig-menu', section=section, selector=selector, run=run)
        assert not item.get('missing'), (section, selector)
        return item

    def wait_for(read):
        for _ in range(80):
            result = read()
            if result:
                return result
            time.sleep(.04)
        raise AssertionError('Observer state did not converge')

    native(name, 'choose')
    assert probe()['title'] == name + ' — Agent WebKit'
    full = base + '?editing=yes#section'
    op('open', full)
    fullscreen = menu('显示', 'toggleFullScreen:')
    assert fullscreen['key'] == 'f' and fullscreen['matchingKeys'] == 1, fullscreen
    assert probe('tab-list-menu') == dict(listed=1, enabled=1)
    assert menu('文件', 'createSpace', 'yes')['dispatched']
    assert probe('tab-list-menu') == dict(listed=1, enabled=0)
    assert probe('create-form-input', key='escape')['handled']
    assert probe('tab-list-menu') == dict(listed=1, enabled=1)
    menu('文件', 'createSpace', 'yes')
    assert probe('create-form-input', name=name, key='return')['handled']
    def form_error():
        result = probe('create-form-input')
        return result if result.get('error') else None
    failed = wait_for(form_error)
    assert failed['enabled'] and failed['name'] == name and failed['tls'] == 0, failed
    assert probe('create-form-input', name='hig-form', key='return')['handled']
    wait_for(lambda: probe()['title'] == 'hig-form — Agent WebKit')
    cli('space', 'delete', 'hig-form')
    native(name, 'choose')
    assert menu('Space', 'copyCurrentSpaceID', 'yes')['copied'] == space['id']
    copied = menu('文件', 'copyCommand', 'yes')['copied']
    assert space['id'] in copied and tab in copied
    assert not menu('文件', 'closeOtherTabs:')['enabled']
    assert menu('文件', 'closeCurrentTab:')['title'] == '隐藏观察窗口'

    short = base.rsplit('/', 1)[0]
    idle = probe()
    assert idle['address'] == idle['axValue'] == short and idle['axTitle'] == name + ' — Agent WebKit', idle
    assert native('', 'cmd-l')['probe']['dispatched']
    field = probe()
    assert field['editing'] and field['address'] == full and field['ring'] and field['axLabel'] == '页面地址', field
    assert field['axRole'] == 'AXTextField' and field['axElement'] and field['axValue'] == full, field
    probe('address-escape')
    assert not probe()['editing'] and probe()['address'] == short
    click = probe('address-mouse')
    assert click['hitField'], click
    after_click = probe()
    assert after_click['editing'] and after_click['editor'] == full, after_click
    for appearance in ['NSAppearanceNameAqua', 'NSAppearanceNameDarkAqua',
                       'NSAppearanceNameAccessibilityAqua', 'NSAppearanceNameAccessibilityDarkAqua']:
        appearance_state = probe('address-appearance', appearance=appearance)
        # Toolbar fields may inherit the corresponding vibrant AppKit appearance.
        effective = appearance_state['appearance']
        assert ('Dark' in effective) == ('Dark' in appearance), appearance_state
        # AppKit can resolve accessibility variants to Aqua when system contrast is unchanged.
        assert appearance_state['ring'] and appearance_state['bezeled'] and appearance_state['editor'] == full, appearance_state
    probe('address-appearance')
    composed = probe('address-text-system')
    assert composed['copied'] and composed['pasted'] and composed['marked'] and composed['committed'] == '拼音', composed
    probe('address-escape')
    probe('address-key-loop')
    assert probe()['editing'] and probe()['address'] == full
    probe('address-key-loop', reverse='yes')
    assert not probe()['editing'] and probe()['address'] == short
    menu('文件', 'focusAddress:', 'yes')
    probe('address-key-loop')
    assert not probe()['editing']
    assert probe('address-backtab-entry')['entered'] and probe()['editor'] == full
    probe('address-escape')
    def check_popovers(host=False):
        for section, selector, key in [('Space', 'showDetails:', 'details'), ('窗口', 'showDownloads', 'downloads')]:
            assert menu(section, selector, 'yes')['dispatched']
            def visible():
                state = menu(section, selector)
                return state if state[key + 'Visible'] else None
            shown = wait_for(visible)
            if host:
                assert shown[key + 'HostRect'], shown
            menu(section, selector, 'yes')
            wait_for(lambda: not menu(section, selector)[key])

    wide = probe('hig-toolbar')
    narrow = probe('hig-toolbar', width='760')
    assert narrow['width'] == 760 and narrow['toolbarVisible'], narrow
    popover_items = {'observer.details', 'observer.downloads'}
    assert popover_items.isdisjoint(wide['overflow']) and popover_items.issubset(narrow['overflow']), (wide, narrow)
    assert 'observer.address' not in narrow['overflow'], narrow
    check_popovers()
    missing = probe('hig-toolbar', hidden='yes')
    assert not missing['toolbarVisible'] and not missing['sidebarCollapsed'], missing
    check_popovers()
    assert menu('显示', 'toggleSidebar:', 'yes')['dispatched']
    wait_for(lambda: probe('hig-toolbar')['sidebarCollapsed'])
    check_popovers(host=True)
    assert menu('显示', 'toggleSidebar:', 'yes')['dispatched']
    probe('hig-toolbar', width=str(wide['width']), hidden='no')
    wait_for(lambda: probe('hig-toolbar')['toolbarVisible'])
    assert not probe('hig-toolbar')['sidebarCollapsed']

    assert probe('cmd-equals')['dispatched'] and probe()['zoom'] > 1
    zoom = probe()['zoom']
    with ThreadPoolExecutor(1) as pool:
        future = pool.submit(op, 'evaluate', 'confirm("hold navigation layout")')
        dialog = wait_for(lambda: op('dialog', 'list')['value']['dialogs'])[0]
        for selector in ['zoomIn:', 'zoomOut:', 'resetZoom:']:
            item = menu('显示', selector, 'force')
            assert not item['enabled'] and item['zoom'] == zoom, item
        for key in ('cmd-plus', 'cmd-equals', 'cmd-minus', 'cmd-zero'):
            probe(key)
            assert probe()['zoom'] == zoom, key
        before = cli('status')['pid']
        assert native('', 'cmd-w')['probe']['dispatched']
        assert not probe()['visible'] and cli('status')['pid'] == before
        probe('reopen-background')
        assert native('', 'inspect-hig')['displayedTabId'] == tab
        assert op('state')['page']['url'] == full
        native(peer, 'choose')
        assert menu('显示', 'zoomIn:', 'yes')['zoom'] > 1
        op('dialog', 'respond', dialog['id'], 'accept')
        assert future.result(timeout=8)['value'] is True
    native(name, 'choose')
    assert probe('cmd-plus')['dispatched'] and probe()['zoom'] > zoom
    assert probe('cmd-minus')['dispatched'] and probe()['zoom'] == zoom
    assert probe('cmd-zero')['dispatched'] and probe()['zoom'] == 1
    second = cli('tab', 'new', '--space', name)['tabId']
    with ThreadPoolExecutor(1) as pool:
        future = pool.submit(op, 'evaluate', 'confirm("hold current tab")')
        dialog = wait_for(lambda: op('dialog', 'list')['value']['dialogs'])[0]
        try:
            pressed = native('', 'cmd-w')
            assert pressed['probe']['visible'] and pressed['displayedTabId'] == tab and not pressed['errorSheet'], pressed
            assert [t['tabId'] for t in cli('tab', 'list', '--space', name)] == [tab, second]
            assert not future.done()
        finally:
            op('dialog', 'respond', dialog['id'], 'accept')
        assert future.result(timeout=8)['value'] is True
    assert menu('文件', 'closeCurrentTab:')['title'] == '关闭当前标签页'
    assert menu('文件', 'closeOtherTabs:', 'yes')['dispatched']
    assert native('', 'sheet', button='取消')['probe']['dispatched']
    bad = urljoin(base, '/diagnostic-drop?long=' + '0123456789' * 90)
    op('evaluate', f'setTimeout(()=>location.assign({json.dumps(bad)}),80); true')
    wait_for(lambda: probe()['expandable'])
    assert probe('expand-error')['dispatched']
    opened = probe()
    assert opened['expanded'] and bad in opened['fullError'] and opened['selectable'] and opened['bounded'], opened
    assert probe('focus-error-text')['focused']
    assert probe('error-key') == dict(dispatched=True, menuConflict=False)
    collapsed = probe()
    assert not collapsed['expanded'] and not collapsed['errorTextFocused'], collapsed
    probe('expand-error')
    native('', 'pick', tab=second)
    assert not probe()['expanded'] and not probe()['fullError']
    native('', 'pick', tab=tab)
    assert not probe()['expanded']
    op('open', full)
    assert not probe()['expandable']
    assert menu('Space', 'toggleSpaceSuspension:', 'yes')['title'] == '休眠 Space…'
    assert native('', 'sheet', button='休眠 Space')['probe']['dispatched']
    assert cli('space', 'info', name)['lifecycle'] == 'suspended'
    assert probe()['title'] == name + ' — Agent WebKit'
    assert menu('Space', 'toggleSpaceSuspension:', 'yes')['title'] == '恢复 Space'
    assert cli('space', 'info', name)['lifecycle'] == 'active'
    assert menu('Space', 'deleteCurrentSpace:', 'yes')['dispatched']
    assert native('', 'sheet', button='删除 Space')['probe']['dispatched']
    wait_for(lambda: name not in [s['name'] for s in cli('space', 'list')])
    assert probe()['title'] != name + ' — Agent WebKit'
    assert cli('tab', 'list', '--space', peer)[0]['tabId'] == other
    cli('space', 'delete', peer)
    if not cli('space', 'list'):
        assert probe()['title'] == 'Agent WebKit'
