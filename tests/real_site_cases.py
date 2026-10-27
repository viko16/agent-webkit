"""Opt-in public-site regressions. Never replace an unavailable site with a fixture."""
from concurrent.futures import ThreadPoolExecutor
import json
import plistlib
import shutil
import subprocess
import time

VUE = 'https://vuejs.org'
INTRO = VUE + '/guide/introduction.html'
REACTIVITY = VUE + '/guide/essentials/reactivity-fundamentals.html'
COMPUTED = VUE + '/guide/essentials/computed.html'
INTERNET = 'https://the-internet.herokuapp.com'


def prepare_site_gui(out, app):
    """A separate test app, with explicit operator checkpoints for native UI actions."""
    copied = out / 'Agent WebKit Site Test.app'
    shutil.copytree(app, copied)
    info = copied / 'Contents/Info.plist'
    plist = plistlib.loads(info.read_bytes())
    plist.update(CFBundleIdentifier='local.agent-webkit.site-test',
                 CFBundleName='Agent WebKit Site Test', CFBundleDisplayName='Agent WebKit Site Test')
    info.write_bytes(plistlib.dumps(plist))
    subprocess.run(['codesign', '--force', '--sign', '-', str(copied)], check=True)

    def observe(phase, expected):
        checkpoint = dict(phase=phase, expected=expected, app=str(copied), requiresForeground=True)
        print(json.dumps(checkpoint), flush=True)
        answer = input('Perform and verify the native UI checkpoint, then type confirmed: ')
        assert answer.strip() == 'confirmed', 'GUI checkpoint was not confirmed; do not mark GUI verified'
        with (out / 'gui-checkpoints.jsonl').open('a') as log:
            log.write(json.dumps(dict(checkpoint, operatorConfirmed=True)) + '\n')

    return copied / 'Contents/MacOS/browser', observe


def site_gui_checks(cli, created, report, observe):
    def checkpoint(phase, **expected):
        if observe:
            observe(phase, expected)

    def observer(name, tab, visible=True):
        actual = cli('status')['observer']
        assert actual == dict(spaceId=created[name]['id'], tabId=tab, visible=visible), actual
        report.setdefault('observerChecks', []).append(actual)

    return checkpoint, observer


def verify_real_spa(cli, out, observe=None):
    names = ('site-spa-a', 'site-spa-b')
    created = {}
    report = {'passed': False, 'site': INTRO, 'rounds': [], 'guiVerified': False}
    checkpoint, observer = site_gui_checks(cli, created, report, observe)

    def command(name, *args, **kwargs):
        return cli(*args, '--space', name, '--tab', created[name]['defaultTabId'], **kwargs)

    def js(name, source):
        return command(name, 'evaluate', source)['value']

    def state(name):
        return js(name, '({url:location.href,heading:document.querySelector("h1").textContent.trim(),'
                       'documentId:window.__awbRegressionDocumentId||null,documentTimeOrigin:performance.timeOrigin})')

    def reference(name, label, role):
        matches = [e['ref'] for e in command(name, 'snapshot')['value']['elements']
                   if e['name'] == label and e['role'] == role]
        assert len(matches) == 1, (label, matches)
        return matches[0]

    def route(name, label, url):
        before = state(name)
        result = command(name, 'click', reference(name, label, 'link'))['value']
        assert result['method'] == 'dom' and result['nativeVerified'] is False
        command(name, 'wait', '--url', url, '--timeout', '15000')
        command(name, 'wait', 'h1', '--text', label, '--timeout', '15000')
        after = state(name)
        assert after['documentId'] == before['documentId'] and after['documentId'], (before, after)
        return after

    try:
        focus = cli('status')['frontmostPid']
        for name in names:
            created[name] = cli('space', 'create', name, '--proxy', 'direct')
        with ThreadPoolExecutor(2) as pool:
            list(pool.map(lambda name: command(name, 'open', INTRO), names))
        initial = {}
        for name in names:
            command(name, 'wait', 'h1', '--text', 'Introduction')
            # VitePress is server-rendered; wait for the real app to finish hydration.
            for _ in range(100):
                if js(name, 'Boolean(document.querySelector("#app").__vue_app__)'):
                    break
                time.sleep(.1)
            else:
                raise AssertionError('Vue documentation did not hydrate')
            # Observe document identity without changing the site's DOM or application state.
            js(name, 'window.__awbRegressionDocumentId=crypto.randomUUID()')
            initial[name] = state(name)
        spare = cli('tab', 'new', REACTIVITY, '--space', names[0])['tabId']
        cli('wait', 'h1', '--text', 'Reactivity Fundamentals', '--space', names[0], '--tab', spare)
        checkpoint('spa-select-other-tab', space=names[0], tab=spare, heading='Reactivity Fundamentals')
        if observe:
            observer(names[0], spare)
        focus = cli('status')['frontmostPid'] if observe else focus
        for count, name in enumerate(names, 1):
            for index in range(count):
                button = reference(name, f'Count is: {index}', 'button')
                command(name, 'click', button)
                command(name, 'wait', button, '--text', f'Count is: {index + 1}')
            report.setdefault('counts', {})[name] = count
        assert cli('status')['frontmostPid'] == focus
        if observe:
            observer(names[0], spare)
        checkpoint('spa-verify-and-select-b', beforeSpace=names[0], beforeTab=spare,
                   beforeHeading='Reactivity Fundamentals', selectSpace=names[1], heading='Introduction')
        if observe:
            observer(names[1], created[names[1]]['defaultTabId'])
        focus = cli('status')['frontmostPid'] if observe else focus
        with ThreadPoolExecutor(2) as pool:
            futures = [pool.submit(route, names[0], 'Reactivity Fundamentals', REACTIVITY),
                       pool.submit(route, names[1], 'Computed Properties', COMPUTED)]
            report['rounds'].append([f.result() for f in futures])
        assert cli('status')['frontmostPid'] == focus
        if observe:
            observer(names[1], created[names[1]]['defaultTabId'])
        checkpoint('spa-verify-and-close', space=names[1], heading='Computed Properties', closeWindow=True)
        if observe:
            observer(names[1], created[names[1]]['defaultTabId'], visible=False)
        focus = cli('status')['frontmostPid'] if observe else focus
        with ThreadPoolExecutor(2) as pool:
            futures = [pool.submit(route, names[0], 'Computed Properties', COMPUTED),
                       pool.submit(route, names[1], 'Reactivity Fundamentals', REACTIVITY)]
            report['rounds'].append([f.result() for f in futures])
        for name in names:
            route(name, 'Introduction', INTRO)
            assert state(name)['documentId'] == initial[name]['documentId']
            button = reference(name, 'Count is: 0', 'button')
            command(name, 'click', button)
            command(name, 'wait', button, '--text', 'Count is: 1')
            assert command(name, 'wait', '#awb-nonexistent', '--timeout', '100', ok=False)['code'] == 'timeout'
            assert js(name, 'document.querySelector("h1").textContent.trim()').startswith('Introduction')
            command(name, 'screenshot', '--out', str(out / f'{name}-background.png'))
            assert cli('space', 'info', name)['defaultTabId'] == created[name]['defaultTabId']
        assert cli('status')['frontmostPid'] == focus
        if observe:
            observer(names[1], created[names[1]]['defaultTabId'], visible=False)
        report.update(guiVerified=observe is not None,
                      initial=initial, explicitTabs=True, syntheticInput=True)
    except Exception as error:
        report['failure'] = str(error)
        raise
    finally:
        try:
            for name in created:
                cli('space', 'delete', name)
        finally:
            (out / 'spa-report.json').write_text(json.dumps(report, indent=2))
    report['passed'] = True
    (out / 'spa-report.json').write_text(json.dumps(report, indent=2))
    return report


def verify_real_login(cli, out, restart, observe=None):
    """Use the site's published demo account, never user credentials or saved sessions."""
    names = ('site-login-a', 'site-login-b')
    created = {}
    report = {'passed': False, 'site': INTERNET, 'guiVerified': False,
              'credentialSource': INTERNET + '/login', 'thirdPartyOAuthTested': False}
    checkpoint, observer = site_gui_checks(cli, created, report, observe)

    def command(name, *args, tab=None, **kwargs):
        return cli(*args, '--space', name, '--tab', tab or created[name]['defaultTabId'], **kwargs)

    def page(name, path, text, tab=None):
        command(name, 'wait', '--url', INTERNET + path, '--timeout', '15000', tab=tab)
        command(name, 'wait', 'body', '--text', text, '--timeout', '15000', tab=tab)
        return command(name, 'state', tab=tab)['page']

    def login(name, valid):
        command(name, 'fill', '#username', 'tomsmith')
        command(name, 'fill', '#password', 'SuperSecretPassword!' if valid else 'invalid-demo-password')
        fields = command(name, 'snapshot')['value']['elements']
        assert next(e for e in fields if e['name'] == 'Password')['value'] == '[redacted]'
        result = command(name, 'click', '#login button', '--wait-for-navigation', '--timeout', '20000')['value']
        assert result['method'] == 'dom' and result['nativeVerified'] is False
        assert result['businessOutcomeVerified'] is False
        return page(name, '/secure' if valid else '/login',
                    'Secure Area' if valid else 'Your password is invalid!')

    def logout(name, tab=None):
        command(name, 'click', 'a[href="/logout"]', '--wait-for-navigation', '--timeout', '20000', tab=tab)
        return page(name, '/login', 'You logged out of the secure area!', tab=tab)

    try:
        focus = cli('status')['frontmostPid']
        for name in names:
            created[name] = cli('space', 'create', name, '--proxy', 'direct')
            command(name, 'open', INTERNET + '/secure')
            page(name, '/login', 'You must login to view the secure area!')
        checkpoint('login-select-b', space=names[1], tab=created[names[1]]['defaultTabId'], heading='Login Page')
        if observe:
            observer(names[1], created[names[1]]['defaultTabId'])
        focus = cli('status')['frontmostPid'] if observe else focus
        with ThreadPoolExecutor(2) as pool:
            valid = pool.submit(login, names[0], True)
            invalid = pool.submit(login, names[1], False)
            report['initialLogin'] = dict(valid=valid.result()['url'], invalid=invalid.result()['url'])
        command(names[1], 'open', INTERNET + '/secure')
        page(names[1], '/login', 'You must login to view the secure area!')
        parent = cli('tab', 'new', INTERNET + '/windows', '--space', names[0])['tabId']
        command(names[0], 'wait', '.example a[target="_blank"]', tab=parent)
        link = command(names[0], 'evaluate', '(() => {const a=document.querySelector(".example a");'
                       'return {target:a.target,rel:a.rel}})()', tab=parent)['value']
        assert link['target'] == '_blank' and 'opener' not in link['rel'].split(), link
        result = command(names[0], 'click', '.example a[target="_blank"]', '--wait-for-popup',
                         '--timeout', '15000', tab=parent)['value']
        assert result['nativeVerified'] is False
        child = result['newTabId']
        popup = page(names[0], '/windows/new', 'New Window', tab=child)
        assert popup['openerTabId'] == parent and popup['tls']['policy'] == 'system'
        assert cli('space', 'info', names[0])['defaultTabId'] == created[names[0]]['defaultTabId']
        command(names[0], 'open', INTERNET + '/secure', tab=child)
        page(names[0], '/secure', 'Secure Area', tab=child)
        # This public site's _blank link uses HTML's implicit noopener behavior.
        assert command(names[0], 'evaluate', 'window.opener === null', tab=child)['value'] is True
        report['openerPolicy'] = 'implicit-noopener; host openerTabId does not imply a JS opener'
        assert cli('status')['frontmostPid'] == focus
        if observe:
            observer(names[1], created[names[1]]['defaultTabId'])
        checkpoint('login-select-child-and-close', beforeSpace=names[1], beforeHeading='Login Page',
                   selectSpace=names[0], selectTab=child, heading='Secure Area', closeWindow=True)
        if observe:
            observer(names[0], child, visible=False)
        focus = cli('status')['frontmostPid'] if observe else focus
        with ThreadPoolExecutor(2) as pool:
            signed_out = pool.submit(logout, names[0], child)
            signed_in = pool.submit(login, names[1], True)
            signed_out.result(); signed_in.result()
        command(names[0], 'reload')
        page(names[0], '/login', 'You must login to view the secure area!')
        page(names[1], '/secure', 'Secure Area')
        assert command(names[0], 'wait', '#content', '--text', 'never-published-result',
                       '--timeout', '100', ok=False)['code'] == 'timeout'
        page(names[0], '/login', 'You must login to view the secure area!')
        for name, tab in ((names[0], child), (names[1], None)):
            command(name, 'screenshot', '--out', str(out / f'{name}-background.png'), tab=tab)
        assert cli('status')['frontmostPid'] == focus
        if observe:
            observer(names[0], child, visible=False)
        # Reverse the authenticated Space, demonstrating logout did not affect its peer.
        with ThreadPoolExecutor(2) as pool:
            signed_in = pool.submit(login, names[0], True)
            signed_out = pool.submit(logout, names[1])
            signed_in.result(); signed_out.result()
        cli('tab', 'close', child, '--space', names[0])
        assert command(names[0], 'state', tab=child, ok=False)['code'] == 'tab_not_found'
        assert cli('space', 'info', names[0])['defaultTabId'] == created[names[0]]['defaultTabId']
        before = {name: cli('space', 'info', name) for name in names}
        restart()
        report['restart'] = {}
        for name in names:
            restored = cli('space', 'info', name)
            for key in ('id', 'dataStoreId', 'defaultTabId', 'proxy', 'tls'):
                assert restored[key] == before[name][key], (key, restored)
            assert {t['tabId'] for t in restored['tabs']} == {t['tabId'] for t in before[name]['tabs']}
            command(name, 'wait')
            # Session cookies follow WebKit/server lifetime, not an application promise.
            path = command(name, 'evaluate', 'location.pathname')['value']
            assert path in ('/secure', '/login'), path
            page(name, path, 'Secure Area' if path == '/secure' else 'Login Page')
            if name == names[1]:
                assert path == '/login', 'The signed-out Space gained a session after restart'
            report['restart'][name] = dict(path=path, authenticated=path == '/secure')
        assert cli('status')['frontmostPid'] == focus
        report.update(guiVerified=observe is not None, sessionIsolation=True,
                      popupInheritedSession=True, logoutSharedAcrossTabs=True, childClosed=True,
                      syntheticInput=True, parentTab=parent, childTab=child)
    except Exception as error:
        report['failure'] = str(error)
        report['failureObservations'] = {}
        for name in created:
            try:
                report['failureObservations'][name] = command(name, 'snapshot')['value']
            except Exception as observation_error:
                report['failureObservations'][name] = {'error': str(observation_error)}
        raise
    finally:
        try:
            for name in created:
                cli('space', 'delete', name)
        finally:
            (out / 'login-report.json').write_text(json.dumps(report, indent=2))
    report['passed'] = True
    (out / 'login-report.json').write_text(json.dumps(report, indent=2))
    return report
