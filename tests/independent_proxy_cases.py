"""Real per-Space routing through two isolated Whistles, including restart and failure."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import json
import time
import urllib.parse
import uuid

from fixtures import Events, origin
from whistle_fixture import WhistleFixture


def verify_proxy_arguments(cli):
    accepted = ['direct'] + [f'http://127.0.0.1:{port}' for port in (1, 1234, 8899, 65535)]
    rejected = [
        'http://127.0.0.1', 'http://127.0.0.1:', 'http://127.0.0.1:0',
        'http://127.0.0.1:65536', 'http://127.0.0.1:-1', 'http://127.0.0.1:abc',
        'https://127.0.0.1:1234', 'socks5://127.0.0.1:1234',
        'http://localhost:1234', 'http://192.0.2.1:1234', 'http://[::1]:1234',
        'http://user:password@127.0.0.1:1234', 'http://127.0.0.1:1234/path',
        'http://127.0.0.1:1234?query', 'http://127.0.0.1:1234#fragment',
    ]
    for proxy in accepted:
        created = cli('space', 'create', 'proxy-argument', '--proxy', proxy)
        assert created['proxy'] == proxy
        cli('space', 'delete', 'proxy-argument')
    for proxy in rejected:
        assert cli('space', 'create', 'proxy-argument', '--proxy', proxy, ok=False)['code'] == 'invalid_proxy', proxy
    return {'passed': True, 'acceptedWithoutNavigation': accepted, 'rejected': rejected}


def verify_independent_proxies(out, cli, restart, whistle_a, site_a, events_a):
    directory = out / 'independent-proxies'
    directory.mkdir()
    site_b, events_b = origin(events=Events(directory / 'origin-b.jsonl'))
    whistle_b = WhistleFixture(directory, site_b.server_address[1])
    routes = [('proxy-a', whistle_a, site_a, events_a), ('proxy-b', whistle_b, site_b, events_b)]
    token = uuid.uuid4().hex
    report = {'passed': False, 'rounds': {}, 'token': token}
    created = {}

    def evaluate(name, script):
        return cli('evaluate', script, '--space', name)['value']

    def evidence(route, url):
        name, whistle, site, events = route
        path = urllib.parse.urlsplit(url)
        hits = [e for e in events.items if e['path'] == path.path + '?' + path.query]
        sessions = [s for s in whistle.sessions() if s.get('url') == url and s.get('req', {}).get('method') == 'GET']
        assert hits and sessions, (name, url, hits, sessions)
        expected = f'http://127.0.0.1:{site.server_address[1]}'
        for session in sessions:
            assert session.get('realUrl', '').startswith(expected + '/'), session
            assert session['res']['statusCode'] == 200 and session.get('endTime'), session
            assert int(session['res']['port']) == site.server_address[1], session
            assert session['rules']['rule']['matcher'] == expected, session
        return {'origin': hits, 'whistle': [{
            'id': s['id'], 'url': s['url'], 'realUrl': s.get('realUrl'),
            'status': s['res']['statusCode'], 'port': s['res']['port'],
            'rules': s.get('rules'), 'complete': bool(s.get('endTime')),
        } for s in sessions]}

    def round_trip(phase):
        url = f'https://example.com/?independent={token}&phase={phase}&delay=0.8'

        def visit(route):
            name, whistle, site, _ = route
            cli('open', url, '--space', name)
            page = evaluate(name, '({nonce:window.fixtureNonce,url:location.href})')
            assert page == {'nonce': site.fixture_nonce, 'url': url}, page
            cli('fill', '#message', name, '--space', name)
            cli('click', '#save', '--space', name)
            actual = evaluate(name, 'document.querySelector("#result").textContent')
            assert actual == name, actual
            resource = f'https://example.com/resource?independent={token}&phase={phase}'
            response = cli('evaluate', f'fetch({json.dumps(resource)}).then(r=>r.json())',
                           '--await', '--space', name)['value']
            assert response['nonce'] == site.fixture_nonce, response
            cli('screenshot', '--space', name, '--out', str(directory / f'{phase}-{name}.png'))
            return {'page': page, 'interaction': actual, 'resource': response,
                    'navigationEvidence': evidence(route, url), 'resourceEvidence': evidence(route, resource)}

        with ThreadPoolExecutor(2) as pool:
            results = list(pool.map(visit, routes))
        arrivals = [r['navigationEvidence']['origin'][-1]['time'] for r in results]
        assert abs(arrivals[0] - arrivals[1]) < .7, arrivals
        report['rounds'][phase] = {'url': url, 'arrivalGapSeconds': abs(arrivals[0] - arrivals[1]),
                                   'spaces': dict(zip([r[0] for r in routes], results))}
        return url

    try:
        whistle_b.start()
        assert whistle_a.port != whistle_b.port and whistle_a.state != whistle_b.state
        assert whistle_a.ca_path.read_bytes() != whistle_b.ca_path.read_bytes()
        report['routes'] = {name: {'proxy': whistle.url, 'originPort': site.server_address[1],
                                 'nonce': site.fixture_nonce, 'rules': whistle.rules,
                                 'state': str(whistle.state), 'pid': whistle.process.pid}
                            for name, whistle, site, _ in routes}
        for name, whistle, _, _ in routes:
            created[name] = cli('space', 'create', name, '--proxy', whistle.url, '--ignore-certificate-errors')
        assert created['proxy-a']['dataStoreId'] != created['proxy-b']['dataStoreId']
        round_trip('concurrent')
        for name, _, _, _ in routes:
            evaluate(name, f'document.cookie="route={name}; Max-Age=3600; Path=/";localStorage.setItem("route","{name}");true')
        read_storage = '({cookie:document.cookie,local:localStorage.getItem("route")})'
        for name, _, _, _ in routes:
            assert evaluate(name, read_storage) == {'cookie': f'route={name}', 'local': name}
        time.sleep(2)  # Let WebKit flush persistent cookies before the graceful shutdown.
        restart()
        report['restored'] = {}
        for route in routes:
            name, whistle, site, _ = route
            info = cli('space', 'info', name)
            assert info['proxy'] == whistle.url and info['id'] == created[name]['id']
            assert info['dataStoreId'] == created[name]['dataStoreId']
            assert info['defaultTabId'] == created[name]['defaultTabId']
            assert info['tls'] == created[name]['tls']
            cli('wait', '--space', name)
            assert evaluate(name, 'window.fixtureNonce') == site.fixture_nonce
            storage = evaluate(name, read_storage)
            assert storage == {'cookie': f'route={name}', 'local': name}, storage
            report['restored'][name] = {'info': info, 'storage': storage}
        round_trip('after-restart')

        # A direct control loads the same public URL successfully, making an offline
        # proxy error meaningful rather than a consequence of an unreachable origin.
        offline_url = f'https://example.com/?independent={token}&phase=offline'
        cli('space', 'create', 'proxy-direct-control', '--proxy', 'direct')
        cli('open', offline_url, '--space', 'proxy-direct-control')
        direct = evaluate('proxy-direct-control', '({title:document.title,nonce:window.fixtureNonce||null})')
        assert direct == {'title': 'Example Domain', 'nonce': None}, direct
        before_a = len(events_a.items)
        before_b = len(events_b.items)
        whistle_a.sessions()
        whistle_a.close()
        with ThreadPoolExecutor(2) as pool:
            failed = pool.submit(cli, 'open', offline_url, '--space', 'proxy-a', '--timeout', '5000', ok=False)
            healthy = pool.submit(cli, 'open', offline_url, '--space', 'proxy-b')
            error, _ = failed.result(), healthy.result()
        assert error['code'] == 'operation_failed', error
        diagnostics = cli('diagnostics', '--space', 'proxy-a')['value']['events']
        assert any(e.get('reason') == 'connection_failed' and e['source'] == 'webkit' for e in diagnostics), diagnostics
        assert len(events_a.items) == before_a, events_a.items[before_a:]
        hits_b = events_b.items[before_b:]
        assert len([e for e in hits_b if 'phase=offline' in e['path']]) == 1, hits_b
        assert evaluate('proxy-b', 'window.fixtureNonce') == site_b.fixture_nonce
        assert cli('space', 'info', 'proxy-a')['proxy'] == whistle_a.url
        report['offline'] = {'directControl': direct, 'errorA': error, 'diagnosticsA': diagnostics, 'originAAddedRequests': 0,
                             'healthyB': evidence(routes[1], offline_url)}
        report['passed'] = True
        return report
    finally:
        try:
            # Release process resources even if browser IPC or another cleanup fails.
            with ExitStack() as cleanup:
                cleanup.callback(site_b.server_close)
                cleanup.callback(site_b.shutdown)
                cleanup.callback(whistle_b.close)
                for name in (*created, 'proxy-direct-control'):
                    if any(s['name'] == name for s in cli('space', 'list')):
                        cli('space', 'delete', name)
        except Exception:
            report['passed'] = False
            raise
        finally:
            report['proxyBStopped'] = whistle_b.process is None or whistle_b.process.poll() is not None
            (directory / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
