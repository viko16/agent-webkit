"""Verify native TLS labels across Space switches and daemon restart; no trust-store changes."""
import hashlib
import json
import platform
import subprocess
import time

from runtime_checks import ROOT, Runtime, build_host


def main():
    out = ROOT / '.artifacts' / time.strftime('gui-security-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    runtime = Runtime(out, ROOT / '.build/Agent WebKit.app/Contents/MacOS/awb')
    report = dict(ok=False, checks=[], macOS=platform.mac_ver()[0],
                  commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                  sourceSHA256={name: hashlib.sha256((ROOT / 'Sources/Browser' / name).read_bytes()).hexdigest()
                                for name in ['Browser.swift', 'Window.swift', 'TLS.swift']})
    try:
        host = build_host(out)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=Agent WebKit GUI Test CA', '-keyout', str(out / 'ca.key'),
                        '-out', str(out / 'ca.pem')], check=True, capture_output=True, timeout=15)
        runtime.start(host, str(runtime.state), str(out))
        cases = {
            'system': ((), '直连 · 系统证书校验', False),
            'custom-ca': (('--ca-cert', str(out / 'ca.pem')), '直连 · 自定义 CA', False),
            'insecure': (('--ignore-certificate-errors',), '直连 · 未校验证书', True),
        }
        created = {}
        for name, (options, _, _) in cases.items():
            created[name] = runtime.command('space', 'create', name, '--proxy', 'direct', *options)
            runtime.page(name, created[name]['defaultTabId'], 'open', runtime.base)

        def check(name, phase, select=True):
            current = runtime.command('space', 'info', name)
            assert current['tls']['policy'] == name and current['id'] == created[name]['id'], current
            assert current['defaultTabId'] == created[name]['defaultTabId'], current
            gui = runtime.gui('select', space=name, capture='true') if select else runtime.gui(capture='true')
            assert gui['observer']['spaceId'] == current['id'], gui
            assert gui['observer']['tabId'] == current['defaultTabId'], gui
            assert gui['security'] == cases[name][1] and gui['securityWarning'] == cases[name][2], gui
            report['checks'].append(dict(phase=phase, policy=name, gui=gui, image=f'gui-{gui["id"]}.png'))

        for name in ['system', 'custom-ca', 'insecure', 'system', 'insecure']:
            check(name, 'switch')
        runtime.command('shutdown', '--all')
        runtime.daemon.wait(timeout=15)
        runtime.start(host, str(runtime.state), str(out))
        check('insecure', 'restored-selection', select=False)
        for name in ['custom-ca', 'system', 'insecure']:
            check(name, 'after-restart')
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
