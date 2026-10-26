"""Real WKWebView A/B/C/D acceptance. Run in a logged-in macOS desktop session."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import traceback

from fixtures import Events, origin
from whistle_fixture import WhistleFixture
from tls_cases import verify_tls_cases
from network_cases import verify_network_cases
from direct_conflict_cases import prepare_proxy_settings, verify_direct_conflicts
from popup_cases import verify_popups
from independent_proxy_cases import verify_proxy_arguments, verify_independent_proxies

ROOT = Path(__file__).resolve().parents[1]


def processes():
    rows = []
    text = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss=,pcpu=,time=,comm='], text=True)
    for line in text.splitlines():
        parts = line.split(None, 5)
        if len(parts) == 6:
            cpu = 0.0
            for component in parts[4].split(':'):
                cpu = cpu * 60 + float(component)
            rows.append(dict(pid=int(parts[0]), ppid=int(parts[1]), rssKiB=int(parts[2]), cpuPercent=float(parts[3]), cpuSeconds=cpu, command=parts[5]))
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', default=str(ROOT / '.artifacts' / time.strftime('%Y%m%d-%H%M%S')))
    parser.add_argument('--whistle-existing', '--whistle', action='store_true', help='Use existing Whistle with example.com mapped to --origin-port and HTTPS capture enabled; do not change its configuration')
    parser.add_argument('--origin-port', type=int, default=0)
    parser.add_argument('--whistle-port', type=int, help='Proxy port; defaults to a free port, or 8899 with --whistle-existing')
    parser.add_argument('--independent-proxies-only', action='store_true', help='Run argument and two-Whistle isolation/restart/failure checks only')
    parser.add_argument('--direct-conflicts', action='store_true', help='Add process-local CFNetwork conflict/recovery cases without modifying OS proxies')
    args = parser.parse_args()
    if args.independent_proxies_only and args.whistle_existing:
        parser.error('--independent-proxies-only requires test-owned Whistles')
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    state = Path(tempfile.mkdtemp(prefix='awk-'))
    binary = ROOT / '.build/debug/browser'
    app_binary = ROOT / '.build/Agent WebKit.app/Contents/MacOS/browser'
    env = dict(os.environ, BROWSER_DATA_DIR=str(state), BROWSER_SOCKET=str(state / 'browser.sock'))
    daemon_env = env.copy()
    if args.direct_conflicts:
        proxy_settings, injection = prepare_proxy_settings(out)
        daemon_env.update(injection)
    report = {'out': str(out), 'stateDirectory': str(state), 'tests': {}, 'resources': {}, 'proxyKind': 'real local Whistle', 'loopbackProxyInScope': False}
    daemon = None
    logs = []
    site, site_events = origin(args.origin_port, events=Events(out / 'origin.jsonl'))
    port = site.server_address[1]
    base = f'http://127.0.0.1:{port}/index.html'
    whistle = WhistleFixture(out, port, existing=args.whistle_existing, port=args.whistle_port)
    baseline = {p['pid'] for p in processes()}
    launch_focus = int(subprocess.check_output(['osascript', '-l', 'JavaScript', '-e',
        'ObjC.import("AppKit"); $.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier'], text=True).strip())

    def cli(*arguments, ok=True):
        result = subprocess.run([str(binary), *arguments], env=env, capture_output=True, text=True, timeout=80)
        try:
            data = json.loads(result.stdout)
        except Exception:
            raise AssertionError((arguments, result.returncode, result.stdout, result.stderr))
        with open(out / 'commands.jsonl', 'a') as stream:
            stream.write(json.dumps({'args': arguments, 'response': data}, ensure_ascii=False) + '\n')
        if ok is None:
            return data
        if ok:
            assert result.returncode == 0 and data['ok'], (arguments, data)
            return data['result']
        assert result.returncode != 0 and not data['ok'], (arguments, data)
        return data['error']

    def start():
        nonlocal daemon
        log = open(out / f'daemon-{len(logs)}.log', 'w')
        logs.append(log)
        daemon = subprocess.Popen([str(app_binary), 'daemon'], env=daemon_env, stdout=log, stderr=log)
        for _ in range(150):
            if daemon.poll() is not None:
                raise AssertionError(f'Daemon exited: {daemon.returncode}; inspect {log.name}')
            if (state / 'browser.sock').exists():
                try:
                    if cli('status')['ready']:
                        return
                except AssertionError:
                    pass
            time.sleep(.1)
        raise AssertionError('Daemon startup timeout')

    def stop():
        cli('shutdown')
        daemon.wait(timeout=15)
        assert daemon.returncode == 0

    def evaluate(space, script, tab=None):
        extra = ['--tab', tab] if tab else []
        return cli('evaluate', script, '--space', space, *extra)['value']

    def sample(label):
        rows = processes()
        ids = {daemon.pid}
        while True:
            children = {p['pid'] for p in rows if p['ppid'] in ids}
            if children <= ids:
                break
            ids |= children
        related = [p for p in rows if p['pid'] in ids or (p['pid'] not in baseline and 'WebKit' in p['command'])]
        began = time.monotonic()
        time.sleep(2)
        second = {p['pid']: p for p in processes()}
        elapsed = time.monotonic() - began
        cpu = sum(max(0, second[p['pid']]['cpuSeconds'] - p['cpuSeconds']) for p in related if p['pid'] in second) / elapsed * 100
        report['resources'][label] = {'processes': related, 'sumRSSMiB': round(sum(p['rssKiB'] for p in related) / 1024, 2),
                                      'sumCpuPercent': round(sum(p['cpuPercent'] for p in related), 2),
                                      'intervalCpuPercent': round(cpu, 2), 'cpuWindowSeconds': round(elapsed, 3),
                                      'note': 'RSS sum double-counts shared pages. intervalCpuPercent uses CPU-time deltas; 100% is one core. Newly appearing WebKit processes are attributed to this test; other apps may affect attribution.'}
        (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))

    try:
        whistle.start()
        report['proxyURL'] = whistle.url
        report['whistleRules'] = whistle.rules
        start()
        report['tests']['proxyArguments'] = verify_proxy_arguments(cli)
        if args.independent_proxies_only:
            report['tests']['independentProxies'] = verify_independent_proxies(
                out, cli, lambda: (stop(), start()), whistle, site, site_events)
            report['passed'] = True
            return 0
        focus_before = cli('status')['frontmostPid']
        sample('empty')
        if args.direct_conflicts:
            report['tests']['directConflicts'] = verify_direct_conflicts(
                cli, start, stop, proxy_settings, base,
                f'https://example.com/?conflict={site.fixture_nonce}', site.fixture_nonce, whistle, site_events)
        report['launchFocus'] = {'before': launch_focus, 'after': focus_before, 'unchanged': launch_focus == focus_before}
        report['system'] = subprocess.check_output(['sw_vers'], text=True)
        report['systemProxy'] = cli('status')['systemProxy']
        report['tests']['popups'] = verify_popups(cli, 'https://example.com', lambda: (stop(), start()),
                                                  proxy=whistle.url, whistle=whistle)
        assert cli('snapshot', ok=False)['code'] == 'space_required'
        assert cli('space', 'create', 'invalid', '--proxy', 'direct', '--ca-cert', str(whistle.ca_path), '--ignore-certificate-errors', ok=False)['code'] == 'invalid_arguments'
        a = cli('space', 'create', 'admin', '--proxy', whistle.url, '--ignore-certificate-errors')
        b = cli('space', 'create', 'user', '--proxy', 'direct')
        assert a['id'] != b['id'] and a['dataStoreId'] != b['dataStoreId']
        assert cli('state', '--space', 'admin', '--tab', b['defaultTabId'], ok=False)['code'] == 'tab_not_found'
        # B: real domain, same URL, real Whistle maps only the proxied Space to the local origin.
        target = f'https://example.com/?agent_webkit={site.fixture_nonce}'
        cli('space', 'create', 'strict', '--proxy', whistle.url)
        strict_before = cli('open', target, '--space', 'strict', ok=None)
        if not args.whistle_existing:
            assert strict_before['ok'] is False, 'A fresh, untrusted Whistle CA must be rejected by system policy'
        cli('space', 'create', 'whistle-ca', '--proxy', whistle.url, '--ca-cert', str(whistle.ca_path))
        ca_result = cli('open', target, '--space', 'whistle-ca', ok=None)
        cli('space', 'delete', 'whistle-ca')
        proxied = cli('open', target, '--space', 'admin')
        observed = evaluate('admin', '({title:document.title,nonce:window.fixtureNonce,url:location.href})')
        assert observed == {'title': 'Agent WebKit Fixture', 'nonce': site.fixture_nonce, 'url': target}, observed
        assert proxied['page']['lastTLSChallenge']['accepted'] is True, proxied
        assert cli('snapshot', '--space', 'admin')['value']['elements']
        cli('screenshot', '--space', 'admin', '--out', str(out / 'b-proxied.png'))

        def mapped_sessions():
            return [item for item in whistle.sessions() if item.get('url') == target and item.get('req', {}).get('method') == 'GET']

        before_direct = mapped_sessions()
        assert before_direct, 'Whistle must contain the actual HTTPS GET, not just a successful configuration'
        cli('open', target, '--space', 'user')
        direct = evaluate('user', '({title:document.title,nonce:window.fixtureNonce||null,url:location.href})')
        assert direct == {'title': 'Example Domain', 'nonce': None, 'url': target}, direct
        cli('screenshot', '--space', 'user', '--out', str(out / 'b-direct.png'))
        after_direct = mapped_sessions()
        assert {item['id'] for item in before_direct} == {item['id'] for item in after_direct}, 'direct Space generated a Whistle session'
        local_hits = [event for event in site_events.items if f'agent_webkit={site.fixture_nonce}' in event['path']]
        expected_hits = 1 + int(ca_result['ok']) + int(strict_before['ok'])
        assert len(local_hits) == expected_hits, ('direct Space reached the local origin', local_hits)
        strict_after = cli('open', target, '--space', 'strict', ok=None)
        assert strict_after['ok'] == strict_before['ok'], 'TLS bypass leaked to a system-policy Space'
        cli('space', 'delete', 'strict')
        inherited_tab = cli('tab', 'new', target, '--space', 'admin')['tabId']
        assert evaluate('admin', 'window.fixtureNonce', inherited_tab) == site.fixture_nonce
        cli('tab', 'close', inherited_tab, '--space', 'admin')
        report['tests']['B'] = {'passed': True, 'url': target, 'proxiedPage': observed, 'directPage': direct,
            'localOriginRequest': local_hits[0], 'whistleSessionIds': [item['id'] for item in before_direct],
            'directAddedWhistleSessions': 0, 'systemPolicyBeforeCustomCA': strict_before,
            'systemPolicyAfterCustomCA': strict_after, 'whistleWithCustomCA': ca_result,
            'insecurePolicyIsolated': True, 'newTabInheritsPolicy': True}
        report['tests']['network'] = verify_network_cases(cli, whistle, site, site_events)
        report['tests']['TLS'] = verify_tls_cases(out, cli, lambda: (stop(), start()))
        # Test the same origin with persistent cookies, avoiding session-cookie restart assumptions.
        for name, value in [('admin', 'A'), ('user', 'B')]:
            cli('open', base, '--space', name)
            evaluate(name, f"document.cookie='shared={value}; Max-Age=86400; Path=/; SameSite=Lax';localStorage.setItem('shared','{value}');true")
        read = "({cookie:document.cookie,local:localStorage.getItem('shared')})"
        for name, expected in [('admin', 'A'), ('user', 'B')]:
            value = evaluate(name, read)
            assert value['cookie'] == f'shared={expected}' and value['local'] == expected, value
        # Second tab shares its own Space's store, and survives restart with its stable ID.
        tab = cli('tab', 'new', base, '--space', 'admin')['tabId']
        assert evaluate('admin', read, tab)['local'] == 'A'
        time.sleep(2)  # Allow WebKit's asynchronous storage writes before a graceful application quit.
        stop()
        time.sleep(1)
        start()
        for name, expected in [('admin', 'A'), ('user', 'B')]:
            cli('wait', '--space', name)
            value = evaluate(name, read)
            assert value['cookie'] == f'shared={expected}' and value['local'] == expected, value
        restored = cli('space', 'info', 'admin')
        assert restored['id'] == a['id'] and any(t['tabId'] == tab for t in restored['tabs'])
        assert evaluate('admin', read, tab)['local'] == 'A'
        report['tests']['A'] = {'passed': True, 'persistentCookie': True, 'localStorage': True, 'stableSpaceAndTabIds': True}
        restored_tls = cli('open', target, '--space', 'admin')
        assert restored_tls['page']['tls']['policy'] == a['tls']['policy']
        assert evaluate('admin', 'window.fixtureNonce') == site.fixture_nonce
        report['tests']['B']['tlsPolicyPersistedAfterRestart'] = True
        cli('tab', 'close', tab, '--space', 'admin')
        # Duplicate daemon must fail without unlinking the live socket.
        duplicate = subprocess.run([str(app_binary), 'daemon'], env=env, capture_output=True, text=True, timeout=10)
        assert duplicate.returncode != 0 and cli('status')['pid'] == daemon.pid
        # Independent CLI processes navigate simultaneously; origin has a deterministic 0.8s delay.
        def agent(name, text):
            cli('open', base + '?delay=0.8', '--space', name)
            snapshot = cli('snapshot', '--space', name)['value']
            field = next(el['ref'] for el in snapshot['elements'] if el['tag'] == 'input')
            button = next(el['ref'] for el in snapshot['elements'] if el['tag'] == 'button')
            repeat = cli('snapshot', '--space', name)['value']
            assert [e['ref'] for e in repeat['elements']] == [e['ref'] for e in snapshot['elements']]
            cli('fill', field, text, '--space', name)
            click = cli('click', button, '--space', name)['value']
            assert click['method'] == 'dom' and click['nativeVerified'] is False
            cli('wait', '#later', '--space', name)
            actual = evaluate(name, "({text:document.querySelector('#result').textContent,trusted:window.lastTrusted})")
            assert actual == {'text': text, 'trusted': False}, actual
            cli('screenshot', '--space', name, '--out', str(out / f'{name}.png'))
            cli('open', base, '--space', name)
            assert 'stale_ref' in cli('click', button, '--space', name, ok=False)['message']
            return actual

        began = time.monotonic()
        with ThreadPoolExecutor(2) as pool:
            futures = [pool.submit(agent, 'admin', 'Alpha'), pool.submit(agent, 'user', 'Beta')]
            results = [f.result() for f in futures]
        focus_after = cli('status')['frontmostPid']
        assert focus_before == focus_after, (focus_before, focus_after)
        assert launch_focus == focus_before, ('Application startup stole focus', launch_focus, focus_before)
        # Actual arrival times prove overlapping navigation independently of CLI startup time.
        arrivals = [event['time'] for event in site_events.items if event['path'] == '/index.html?delay=0.8']
        assert len(arrivals) == 2 and abs(arrivals[1] - arrivals[0]) < .7, arrivals
        report['tests']['C'] = {'passed': True, 'results': results, 'elapsedSeconds': round(time.monotonic() - began, 3),
                                 'navigationArrivalGapSeconds': round(abs(arrivals[1] - arrivals[0]), 3),
                                 'frontmostPidBefore': focus_before, 'frontmostPidAfter': focus_after,
                                 'stableRefs': True, 'staleRefsRejected': True}
        # Wait errors must return bounded structured JSON, not block the daemon forever.
        assert cli('wait', '#does-not-exist', '--space', 'user', '--timeout', '200', ok=False)['code'] == 'timeout'
        for i in range(3):
            name = f'load{i}'
            cli('space', 'create', name, '--proxy', 'direct')
            cli('open', base, '--space', name)
        time.sleep(3)
        sample('five_spaces')
        stop()
        time.sleep(2)
        start()
        for name in ('admin', 'user', 'load0', 'load1', 'load2'):
            cli('wait', '--space', name)
        time.sleep(3)
        sample('five_spaces_after_restart')
        for space in cli('space', 'list'):
            deleted = cli('space', 'delete', space['id'])
            assert deleted['websiteDataRemoved']
        time.sleep(3)
        sample('after_delete')
        # Recreating the name gets a fresh store and cannot see the deleted data.
        new = cli('space', 'create', 'admin', '--proxy', 'direct')
        assert new['id'] != a['id']
        cli('open', base, '--space', 'admin')
        assert evaluate('admin', read) == {'cookie': '', 'local': None}
        cli('space', 'delete', 'admin')
        # Stop only our own Whistle process; never interrupt a pre-existing instance.
        if not args.whistle_existing:
            report['tests']['independentProxies'] = verify_independent_proxies(
                out, cli, lambda: (stop(), start()), whistle, site, site_events)
            whistle.close()
            cli('space', 'create', 'offline', '--proxy', whistle.url, '--ignore-certificate-errors')
            error = cli('open', 'https://www.example.com/?must-not-arrive', '--space', 'offline', '--timeout', '3000', ok=False)
            cli('space', 'delete', 'offline')
            report['tests']['B']['whistleOfflineFailsClosed'] = error
        report['tests']['D'] = {'passed': True, 'spaceCount': 5, 'deletionPurgedStores': True}
        stop()
        time.sleep(3)
        sample('after_shutdown')
        report['passed'] = all(test['passed'] for test in report['tests'].values())
    except Exception:
        report['passed'] = False
        report['failure'] = traceback.format_exc()
        print(report['failure'], flush=True)
    finally:
        if daemon and daemon.poll() is None:
            try:
                # Remove test stores through the public WebKit API before stopping.
                for space in cli('space', 'list'):
                    cli('space', 'delete', space['id'])
                stop()
            except Exception:
                daemon.terminate()
                daemon.wait(timeout=15)
        whistle.close()
        site.shutdown(); site.server_close()
        for log in logs:
            log.close()
        (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(json.dumps({'passed': report.get('passed'), 'tests': {name: item['passed'] for name, item in report['tests'].items()}, 'report': str(out / 'report.json')}, ensure_ascii=False), flush=True)
    return 0 if report.get('passed') else 1


if __name__ == '__main__':
    raise SystemExit(main())
