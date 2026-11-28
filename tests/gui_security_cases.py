"""Verify native TLS labels across Space switches and daemon restart; no trust-store changes."""
import hashlib
import json
import platform
import ssl
import subprocess
import time

from runtime_checks import ROOT, Runtime, build_host
from fixtures import origin


def main():
    out = ROOT / '.artifacts' / time.strftime('gui-security-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    runtime = Runtime(out, ROOT / '.build/Agent WebKit.app/Contents/MacOS/awb')
    report = dict(ok=False, checks=[], macOS=platform.mac_ver()[0],
                  commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                  sourceSHA256={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in sorted((ROOT / 'Sources/Browser').glob('*.swift'))})
    try:
        host = build_host(out)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=Agent WebKit GUI Test CA', '-keyout', str(out / 'ca.key'),
                        '-out', str(out / 'ca.pem')], check=True, capture_output=True, timeout=15)
        runtime.start(host, str(runtime.state), str(out))
        cases = {
            'system': ((), '系统证书校验'),
            'custom-ca': (('--ca-cert', str(out / 'ca.pem')), '系统证书及自定义 CA'),
            'insecure': (('--ignore-certificate-errors',), '忽略证书错误'),
        }
        created = {}
        for name, (options, _) in cases.items():
            created[name] = runtime.command('space', 'create', name, '--proxy', 'direct', *options)
            runtime.page(name, created[name]['tabs'][0]['tabId'], 'open', runtime.base)

        def check(name, phase, select=True, https=False):
            current = runtime.command('space', 'info', name)
            assert current['tls']['policy'] == name and current['id'] == created[name]['id'], current
            assert current['tabs'][0]['tabId'] == created[name]['tabs'][0]['tabId'], current
            # A restored URL is not the current connection until WebKit commits it.
            runtime.page(name, current['tabs'][0]['tabId'], 'wait', '#message')
            gui = runtime.gui('select', space=name, capture='true') if select else runtime.gui(capture='true')
            assert gui['observer']['spaceId'] == current['id'], gui
            assert gui['observer']['tabId'] == current['tabs'][0]['tabId'], gui
            assert gui['security'] == ('HTTPS · 允许证书错误' if https else 'HTTP（未加密）'), gui
            assert gui['securityWarning'] == https and cases[name][1] in gui['securityHelp'], gui
            report['checks'].append(dict(phase=phase, policy=name, gui=gui, image=f'gui-{gui["id"]}.png'))

        for name in ['system', 'custom-ca', 'insecure', 'system', 'insecure']:
            check(name, 'switch')
        runtime.command('shutdown', '--all')
        runtime.daemon.wait(timeout=15)
        runtime.start(host, str(runtime.state), str(out))
        check('insecure', 'restored-selection', select=False)
        for name in ['custom-ca', 'system', 'insecure']:
            check(name, 'after-restart')
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(out / 'ca.pem', out / 'ca.key')
        secure_site, _ = origin(tls_context=context)
        try:
            runtime.page('insecure', created['insecure']['tabs'][0]['tabId'], 'open',
                         f'https://127.0.0.1:{secure_site.server_address[1]}/index.html')
            check('insecure', 'https', https=True)
        finally:
            secure_site.shutdown(); secure_site.server_close()
        report['runtimePassed'] = True
    except BaseException as error:
        report['error'] = repr(error)
        raise
    finally:
        try:
            runtime.close()
            report['cleanupVerified'] = True
        except BaseException as error:
            report['cleanupError'] = repr(error)
            raise
        finally:
            report['ok'] = report.get('runtimePassed', False) and 'cleanupError' not in report
            report['scope'] = 'Automated native GUI TLS labels/color, Space routing, selection/policy restoration and foreground checks; not TLS network trust validation or manual interaction.'
            (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
            print(json.dumps(dict(ok=report['ok'], report=str(out / 'report.json'))), flush=True)


if __name__ == '__main__':
    main()
