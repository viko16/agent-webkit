"""Real HTTPS negative cases, using temporary certificates without touching a keychain."""
import ssl
import json
import subprocess
from fixtures import Events, origin


def verify_tls_cases(out, cli, restart):
    directory = out / 'tls-fixtures'
    directory.mkdir(mode=0o700)

    def openssl(*args):
        result = subprocess.run(['openssl', *args], cwd=directory, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr

    openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '2',
            '-subj', '/CN=Agent WebKit Test CA', '-keyout', 'ca.key', '-out', 'ca.pem',
            '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign')
    servers = []
    results = {}
    try:
        cli('space', 'create', 'tls-local', '--proxy', 'direct', '--ca-cert', str(directory / 'ca.pem'))
        cli('space', 'create', 'tls-other-ca', '--proxy', 'direct', '--ca-cert', str(out / 'whistle-ca.pem'))
        cli('space', 'create', 'tls-insecure', '--proxy', 'direct', '--ignore-certificate-errors')
        for name, san, days in [('valid', 'IP:127.0.0.1', '2'), ('wrong-host', 'DNS:wrong.example', '2'), ('expired', 'IP:127.0.0.1', '-1')]:
            (directory / f'{name}.ext').write_text(f'subjectAltName={san}\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n')
            openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-subj', '/CN=Agent WebKit TLS Fixture', '-keyout', f'{name}.key', '-out', f'{name}.csr')
            if name == 'expired':
                (directory / 'index.txt').write_text('')
                (directory / 'serial').write_text('1000\n')
                (directory / 'ca.cnf').write_text('[ca]\ndefault_ca=fixture\n[fixture]\ndatabase=index.txt\nnew_certs_dir=.\nserial=serial\ncertificate=ca.pem\nprivate_key=ca.key\ndefault_md=sha256\npolicy=names\n[names]\ncommonName=supplied\n')
                openssl('ca', '-batch', '-config', 'ca.cnf', '-in', f'{name}.csr', '-out', f'{name}.pem',
                        '-startdate', '20000101000000Z', '-enddate', '20010101000000Z', '-extfile', f'{name}.ext', '-notext')
            else:
                openssl('x509', '-req', '-in', f'{name}.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', '-days', days, '-sha256', '-extfile', f'{name}.ext', '-out', f'{name}.pem')
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(directory / f'{name}.pem', directory / f'{name}.key')
            server, _ = origin(events=Events(out / 'tls-origin.jsonl'), tls_context=context)
            servers.append(server)
            url = f'https://127.0.0.1:{server.server_address[1]}/'
            if name == 'valid':
                page = cli('open', url, '--space', 'tls-local')
                assert page['page']['lastTLSChallenge']['accepted'] is True
                results['matchingCAAccepted'] = True
                results['unrelatedCARejected'] = cli('open', url, '--space', 'tls-other-ca', ok=False)
                assert results['unrelatedCARejected']['code'] == 'certificate_rejected'
                # Persisted trust is certificate data, not a dependency on the original file path.
                (directory / 'ca.pem').rename(directory / 'ca-renamed.pem')
                restart()
                restored = cli('open', url, '--space', 'tls-local')
                assert restored['page']['tls']['policy'] == 'custom-ca'
                assert cli('evaluate', 'window.fixtureNonce', '--space', 'tls-local')['value'] == server.fixture_nonce
                results['caPersistedWithoutSourceFile'] = True
                (directory / 'ca-renamed.pem').rename(directory / 'ca.pem')
            else:
                error = cli('open', url, '--space', 'tls-local', ok=False)
                assert error['code'] == 'certificate_rejected', error
                results[name] = error
                insecure = cli('open', url, '--space', 'tls-insecure')
                assert insecure['page']['lastTLSChallenge']['certificateErrorsIgnored'] is True
                assert cli('open', url, '--space', 'tls-local', ok=False)['code'] == 'certificate_rejected'
                results[name + 'AcceptedOnlyWithInsecureFlag'] = True
            # The exact WebKit-provided popup configuration must retain the Space's TLS policy.
            parent = cli('space', 'info', 'tls-local')['defaultTabId']
            before = {t['tabId'] for t in cli('tab', 'list', '--space', 'tls-local')}
            assert cli('evaluate', f'Boolean(window.open({json.dumps(url)}))', '--space', 'tls-local')['value'] is True
            tabs = cli('tab', 'list', '--space', 'tls-local')
            popup = next(t['tabId'] for t in tabs if t['tabId'] not in before)
            if name == 'valid':
                accepted = cli('wait', '--space', 'tls-local', '--tab', popup)
                assert accepted['page']['lastTLSChallenge']['accepted'] is True
                assert accepted['page']['tls']['policy'] == 'custom-ca'
            else:
                assert cli('wait', '--space', 'tls-local', '--tab', popup, ok=False)['code'] == 'certificate_rejected'
            assert cli('space', 'info', 'tls-local')['defaultTabId'] == parent
            cli('tab', 'close', popup, '--space', 'tls-local')
            results[name + 'PopupInheritsTLS'] = True
        results['passed'] = True
        return results
    finally:
        for name in ('tls-local', 'tls-other-ca', 'tls-insecure'):
            cli('space', 'delete', name)
        for server in servers:
            server.shutdown(); server.server_close()
