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


def verify_real_spa(cli, out, observe=None):
    names = ('site-spa-a', 'site-spa-b')
    created = {}
    report = {'passed': False, 'site': INTRO, 'rounds': [], 'guiVerified': False}

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

    def checkpoint(phase, **expected):
        if observe:
            observe(phase, expected)

    def observer(space, tab, visible=True):
        actual = cli('status')['observer']
        assert actual == dict(spaceId=created[space]['id'], tabId=tab, visible=visible), actual
        report.setdefault('observerChecks', []).append(actual)

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
