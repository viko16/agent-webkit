"""Exercise real daemon recovery with process-local CFNetwork settings, never global proxies."""
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def prepare_proxy_settings(out):
    library = out / 'proxy-settings.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'Foundation',
                    '-framework', 'CFNetwork', str(ROOT / 'tests/proxy_settings.m'),
                    '-o', str(library)], check=True, capture_output=True, text=True)
    path = out / 'proxy-settings.json'
    path.write_text('{}')
    return path, dict(DYLD_INSERT_LIBRARIES=str(library), AW_TEST_PROXY_SETTINGS=str(path))


def verify_proxy_summary(cli, start, stop, out, base):
    settings, extra_env = prepare_proxy_settings(out)
    stop()
    settings.write_text(json.dumps({'ProxyAutoConfigEnable': 1,
                                   'HTTPProxy': 'internal-sensitive-host',
                                   'ProxyAutoConfigURLString': 'http://pac.internal/config?token=proxy-secret'}))
    start(extra_env=extra_env)
    try:
        status = cli('status')
        assert status['systemProxy'] == dict(enabled=True, enabledTypes=['ProxyAutoConfigEnable']), status
        encoded = json.dumps(status)
        assert all(secret not in encoded for secret in ('internal-sensitive-host', 'pac.internal', 'proxy-secret'))
        cli('space', 'create', 'summary-direct', '--proxy', 'direct')
        cli('open', base, '--space', 'summary-direct', error='direct_system_proxy_conflict')
        settings.write_text('{}')
        cli('open', base, '--space', 'summary-direct')
        assert cli('evaluate', 'location.href', '--space', 'summary-direct')['value'] == base
    finally:
        settings.write_text('{}')
        remaining = cli('space', 'list')
        if any(space['name'] == 'summary-direct' for space in remaining):
            cli('space', 'delete', 'summary-direct')
        stop(); start()
    return dict(passed=True, systemProxySummaryRedacted=True, directConflictStillEnforced=True)


def verify_direct_conflicts(cli, start, stop, settings, base, target, nonce, whistle, events):
    def set_settings(value):
        temporary = settings.with_suffix('.tmp')
        temporary.write_text(json.dumps(value))
        os.replace(temporary, settings)

    # Persist both routes and data before introducing a conflict at the CFNetwork boundary.
    cli('space', 'create', 'conflict-direct', '--proxy', 'direct')
    cli('space', 'create', 'conflict-proxy', '--proxy', whistle.url, '--ignore-certificate-errors')
    cli('open', base, '--space', 'conflict-direct')
    cli('open', target, '--space', 'conflict-proxy')
    cli('evaluate', 'localStorage.setItem("conflict","saved"); document.cookie="conflict=kept; max-age=3600; path=/"', '--space', 'conflict-direct')
    original = cli('state', '--space', 'conflict-direct')['page']
    checks = []
    try:
        for key in ['HTTPEnable', 'HTTPSEnable', 'SOCKSEnable', 'ProxyAutoConfigEnable', 'ProxyAutoDiscoveryEnable']:
            stop()
            # Nested scopes must also be detected (e.g. per-interface proxy settings).
            value = {'__SCOPED__': {'test-interface': {key: 1}}} if key == 'SOCKSEnable' else {key: 1}
            value.update(HTTPProxy='internal-sensitive-host', ProxyAutoConfigURLString='http://pac.internal/config?token=proxy-secret')
            set_settings(value)
            before = len(events.items)
            start()
            status = cli('status')
            assert status['ready'] and status['systemProxy'] == dict(enabled=True, enabledTypes=[key])
            assert 'internal-sensitive-host' not in json.dumps(status)
            assert 'proxy-secret' not in json.dumps(status)
            info = cli('space', 'info', 'conflict-direct')
            assert info['id'] in status['blockedSpaces'] and info['network']['blocked']
            assert info['network']['error']['code'] == 'direct_system_proxy_conflict'
            diagnostics = cli('diagnostics', '--space', 'conflict-direct')
            assert diagnostics['networkBlocked'] and diagnostics['networkErrorCode'] == 'direct_system_proxy_conflict'
            assert any(s['name'] == 'conflict-proxy' for s in cli('space', 'list'))
            page = cli('state', '--space', 'conflict-direct')['page']
            assert page['tabId'] == original['tabId'] and page['restoreURL'] == original['url']
            assert page['url'] == 'about:blank'
            for command in [('reload',), ('open', base), ('evaluate', 'document.title')]:
                assert cli(*command, '--space', 'conflict-direct', ok=False)['code'] == 'direct_system_proxy_conflict'
            assert not any(e.get('path') == '/index.html' for e in events.items[before:]), 'Blocked Direct restoration sent a request'
            cli('open', target, '--space', 'conflict-proxy')
            assert cli('evaluate', 'window.fixtureNonce', '--space', 'conflict-proxy')['value'] == nonce
            assert any(s.get('url') == target for s in whistle.sessions())
            set_settings({})
            assert not cli('space', 'info', 'conflict-direct')['network']['blocked']
            cli('reload', '--space', 'conflict-direct')
            restored = cli('evaluate', '({saved:localStorage.getItem("conflict"),cookie:document.cookie})', '--space', 'conflict-direct')
            assert restored['page']['tabId'] == original['tabId']
            assert restored['value']['saved'] == 'saved' and 'conflict=kept' in restored['value']['cookie']
            # Page-initiated navigation is checked too, even without a new CLI navigation command.
            cli('evaluate', 'setTimeout(()=>location.href="/blocked-navigation",500); true', '--space', 'conflict-direct')
            set_settings(value)
            for _ in range(50):
                error = cli('state', '--space', 'conflict-direct')['page']['lastError']
                if error and error['code'] == 'direct_system_proxy_conflict':
                    break
                time.sleep(.05)
            else:
                raise AssertionError('Page navigation was not rejected')
            assert not any(e.get('path') == '/blocked-navigation' for e in events.items)
            set_settings({})
            cli('reload', '--space', 'conflict-direct')
            checks.append(key)
        return {'passed': True, 'settings': checks,
                'method': 'process-local CFNetwork interpose + real WKWebView and Whistle; no OS proxy settings changed',
                'realSystemProxyToggleTested': False}
    finally:
        set_settings({})
        cli('space', 'delete', 'conflict-direct')
        cli('space', 'delete', 'conflict-proxy')
