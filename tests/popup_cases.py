"""Real WebKit popup, opener, lifecycle and synthetic-activation regressions."""
from concurrent.futures import ThreadPoolExecutor
import time
from urllib.parse import urljoin


def verify_popups(cli, base, restart, proxy='direct', whistle=None):
    names = ['popup-a', 'popup-b']
    parents = {}
    url = urljoin(base, '/popups')

    def js(name, source, tab=None):
        return cli('evaluate', source, '--space', name, *(['--tab', tab] if tab else []))['value']

    def wait_until(predicate):
        for _ in range(100):
            if predicate():
                return
            time.sleep(.03)
        raise AssertionError('Popup condition did not settle')

    focus = cli('status')['frontmostPid']
    try:
        for name in names:
            extra = ['--ignore-certificate-errors'] if proxy != 'direct' else []
            parents[name] = cli('space', 'create', name, '--proxy', proxy, *extra)['defaultTabId']
            cli('open', url, '--space', name)
            js(name, f'localStorage.setItem("popup-value","{name}"); document.cookie="popup={name}; max-age=3600; path=/"')
        with ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda name: cli('click', '#blank', '--space', name, '--wait-for-popup'), names))
        for name, result in zip(names, results):
            child = result['value']['newTabId']
            assert result['value']['nativeVerified'] is False and result['value']['businessOutcomeVerified'] is False
            assert cli('space', 'info', name)['defaultTabId'] == parents[name]
            cli('wait', '--space', name, '--tab', child)
            state = cli('state', '--space', name, '--tab', child)
            assert state['page']['openerTabId'] == parents[name]
            assert state['page']['url'] == url + '?mode=child'
            assert state['proxy'] == proxy
            assert state['page']['tls']['policy'] == ('system' if proxy == 'direct' else 'insecure')
            assert js(name, 'Boolean(window.opener)', child)
            assert js(name, 'localStorage.getItem("popup-value")', child) == name
            cli('snapshot', '--space', name, '--tab', child)
            cli('click', '#callback', '--space', name, '--tab', child)
            wait_until(lambda: len(cli('tab', 'list', '--space', name)) == 1)
            assert js(name, 'window.popupResult.value') == name
            assert f'popup={name}' in js(name, 'window.popupResult.cookie')
            assert '#callback' in cli('state', '--space', name)['page']['url']
            assert js(name, 'window.openReturned') is None
            scripted = cli('click', '#scripted', '--space', name, '--wait-for-popup')['value']['newTabId']
            cli('wait', '--space', name, '--tab', scripted)
            assert js(name, 'window.openReturned') is True
            assert js(name, 'window.lastTrusted') is False
            # A named window reuses the existing child and must not create an orphan.
            cli('click', '#scripted', '--space', name)
            assert len(cli('tab', 'list', '--space', name)) == 2
            cli('tab', 'close', scripted, '--space', name)
            assert cli('click', '#trusted', '--space', name, '--wait-for-popup', '--timeout', '200', ok=False)['code'] == 'popup_not_opened'
            assert len(cli('tab', 'list', '--space', name)) == 1
            assert cli('click', '#external', '--space', name, '--wait-for-popup', '--timeout', '500', ok=False)['code'] == 'unsupported_navigation'
            assert len(cli('tab', 'list', '--space', name)) == 1
            assert cli('state', '--space', name)['page']['lastNavigationRejection']['code'] == 'unsupported_navigation'
            assert cli('click', '#blank', '--space', name, '--wait-for-popup', '--wait-for-navigation', ok=False)['code'] == 'invalid_arguments'
            child = cli('click', '#blank', '--space', name, '--wait-for-popup')['value']['newTabId']
            cli('wait', '--space', name, '--tab', child)
        before = {name: [(t['tabId'], t['url']) for t in cli('tab', 'list', '--space', name)] for name in names}
        restart()
        for name in names:
            for tab, old_url in before[name]:
                cli('wait', '--space', name, '--tab', tab)
                assert cli('state', '--space', name, '--tab', tab)['page']['url'] == old_url
            assert cli('space', 'info', name)['defaultTabId'] == parents[name]
            assert js(name, 'localStorage.getItem("popup-value")') == name
            # Closing the opener does not orphan its child; script-close of the final tab
            # leaves one ordinary blank tab and a valid default, within the same Space.
            child = cli('click', '#blank', '--space', name, '--wait-for-popup')['value']['newTabId']
            cli('wait', '--space', name, '--tab', child)
            for tab in cli('tab', 'list', '--space', name):
                if tab['tabId'] != child:
                    cli('tab', 'close', tab['tabId'], '--space', name)
            js(name, 'setTimeout(()=>window.close(),100); true', child)
            wait_until(lambda: all(t['tabId'] != child for t in cli('tab', 'list', '--space', name)))
            remaining = cli('tab', 'list', '--space', name)
            assert len(remaining) == 1 and remaining[0]['url'] == 'about:blank'
            assert cli('space', 'info', name)['defaultTabId'] == remaining[0]['tabId']
        if whistle:
            assert any('/popup-redirect' in s.get('url', '') for s in whistle.sessions())
            assert any('/popups?mode=child' in s.get('url', '') for s in whistle.sessions())
        assert cli('status')['frontmostPid'] == focus
        return {'passed': True, 'proxy': proxy, 'checks': ['target blank', 'window.open', 'redirect',
                'opener postMessage and callback navigation', 'window.close', 'named window reuse',
                'explicit tab control and fixed CLI default', 'per-space cookies and storage',
                'synthetic activation rejection', 'external scheme rejection', 'restart IDs/URLs', 'foreground unchanged']}
    finally:
        for name in names:
            assert cli('space', 'delete', name)['websiteDataRemoved']
