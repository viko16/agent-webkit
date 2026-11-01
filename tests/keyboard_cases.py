"""Real production focus/key effects, explicit targets and lifecycle boundaries."""
import json
from pathlib import Path
import plistlib
import subprocess
import time
from urllib.parse import urljoin


def verify_keyboard(cli, base, out, restart, site_events, nonce):
    work = cli('space', 'create', 'keyboard-work', '--proxy', 'direct')
    peer = cli('space', 'create', 'keyboard-peer', '--proxy', 'direct')
    tab, peer_tab = work['defaultTabId'], peer['defaultTabId']
    page = urljoin(base, '/keyboard')
    evidence = []

    def command(*args, target=tab, space='keyboard-work', **kwargs):
        return cli(*args, '--space', space, '--tab', target, **kwargs)

    def js(source, **kwargs):
        return command('evaluate', source, **kwargs)['value']

    def read(**kwargs):
        return js('window.inputRead()', **kwargs)

    def prepare(**kwargs):
        command('focus', '#first', **kwargs)
        js("document.querySelector('#first').setSelectionRange(10,10);true", **kwargs)

    try:
        command('open', page)
        command('open', page, target=peer_tab, space='keyboard-peer')
        other = cli('tab', 'new', page, '--space', 'keyboard-work')['tabId']
        initial = cli('status')
        command('key', 'Enter', error='input_focus_required')
        cli('focus', '#first', '--space', 'keyboard-work', error='invalid_arguments')
        command('key', 'Command+A', error='unsupported_key')
        command('key', 'Shift+X', '--frame', 'unknown', error='invalid_arguments')
        for selector, error in [('#disabled', 'element_not_actionable'), ('#plain', 'input_focus_failed'),
                                ('#missing', 'selector_count'), ('#frame', 'unsupported_context'),
                                ('#frame >>> input', 'unsupported_context')]:
            command('focus', selector, error=error)
        # Whole-document editors and tabindex regions are legitimate explicit focus targets.
        js("document.body.replaceChildren(document.createTextNode('editable-body'));document.body.contentEditable='true';true")
        command('focus', 'body')
        command('key', 'Shift+X')
        assert 'X' in js('document.body.innerText')
        for invalid_tabindex in ['', 'invalid']:
            command('reload')
            js(f"document.body.setAttribute('tabindex',{json.dumps(invalid_tabindex)});true")
            command('focus', 'body', error='input_focus_failed')
        for root, tabindex in [('body', 0), ('body', -1), ('html', 0), ('html', -1)]:
            command('reload')
            command('focus', 'body', error='input_focus_failed')
            js(f"document.querySelector('{root}').tabIndex={tabindex};window.rootKeys=[];document.addEventListener('keydown',e=>rootKeys.push({{tag:e.target.localName,key:e.key,trusted:e.isTrusted}}));true")
            command('focus', root)
            command('key', 'Shift+X')
            assert js('window.rootKeys') == [dict(tag=root, key='X', trusted=True)]
        for key, selection, value in [('ArrowLeft', [9, 9], 'alpha beta'),
                                      ('Shift+ArrowLeft', [9, 10], 'alpha beta'),
                                      ('Option+ArrowLeft', [6, 6], 'alpha beta'),
                                      ('Control+B', [9, 9], 'alpha beta'),
                                      ('Shift+X', [11, 11], 'alpha betaX')]:
            command('reload')
            prepare()
            result = command('key', key)['value']
            actual = read()
            assert actual['selection'] == selection and actual['value'] == value, (key, actual)
            keys = [e for e in actual['events'] if e['type'] in ['keydown', 'keyup']]
            assert len(keys) == 2 and all(e['trusted'] for e in keys), (key, actual)
            assert result['dispatched'] and not result['physicalInput'] and not result['businessOutcomeVerified']
            evidence.append(dict(key=key, result=result, observed=actual))
        command('reload')
        prepare()
        command('key', 'Tab')
        assert read()['active'] == 'second'
        command('open', page + '?mode=cancel-tab')
        prepare()
        command('key', 'Tab')
        assert read()['active'] == 'first'
        command('click', '#open-modal')
        command('focus', '#inside')
        command('key', 'Escape')
        assert not read()['modal']
        command('focus', '#host >>> #shadow')
        command('key', 'Shift+X')
        assert read()['shadowActive'] == 'shadow'
        assert js("document.querySelector('#host').shadowRoot.querySelector('input').value") == 'X'
        for target, space in [(other, 'keyboard-work'), (peer_tab, 'keyboard-peer')]:
            command('key', 'Shift+X', target=target, space=space, error='input_focus_required')
            assert read(target=target, space=space)['value'] == 'alpha beta'
            prepare(target=target, space=space)
            command('key', 'Shift+X', target=target, space=space)
            assert read(target=target, space=space)['value'] == 'alpha betaX'
        # One genuine form submission per Space; correlate each page epoch with server evidence.
        for target, space in [(tab, 'keyboard-work'), (peer_tab, 'keyboard-peer')]:
            prepare(target=target, space=space)
            before = read(target=target, space=space)
            command('key', 'Enter', target=target, space=space)
            command('wait', '#ack', '--text', nonce, target=target, space=space)
            posts = [e for e in site_events.items if e['kind'] == 'keyboard-save' and e['epoch'] == before['epoch']]
            assert len(posts) == 1 and posts[0]['value'] == before['value'] and posts[0]['nonce'] == nonce
        ref = next(e['ref'] for e in command('snapshot')['value']['elements'] if e['tag'] == 'input')
        command('reload')
        command('focus', ref, error='stale_ref')
        command('key', 'Shift+X', error='input_target_changed')
        prepare()
        restart()
        command('key', 'Shift+X', error='input_focus_required')
        command('wait', '#first')
        prepare()
        cli('space', 'suspend', 'keyboard-work')
        command('key', 'Shift+X', error='input_focus_required')
        prepare()
        command('key', 'Shift+X')
        command('open', page + '?mode=hang')
        prepare()
        began = time.monotonic()
        command('key', 'Shift+X', '--timeout', '150', error='timeout')
        assert time.monotonic() - began < 3
        command('state')
        command('focus', '#first', error='web_content_unresponsive')
        prepare(target=peer_tab, space='keyboard-peer')
        command('key', 'ArrowLeft', target=peer_tab, space='keyboard-peer')
        command('reload')
        command('key', 'Enter', error='input_focus_required')
        cli('tab', 'close', other, '--space', 'keyboard-work')
        command('key', 'Enter', target=other, error='tab_not_found')
        after = cli('status')
        assert after['frontmostPid'] == initial['frontmostPid']
        assert after['observer'] == initial['observer']
        assert len([e for e in site_events.items if e['kind'] == 'keyboard-save']) == 2
        # Exercise the real observer's address editor; this cannot be faked with page JS.
        root = Path(__file__).resolve().parents[1]
        app = out / 'Input Host Probe.app'
        executable = app / 'Contents/MacOS/input-host'
        executable.parent.mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier='local.agent-webkit.input-host-probe', CFBundleExecutable='input-host',
            CFBundlePackageType='APPL', NSAppTransportSecurity=dict(NSAllowsArbitraryLoadsInWebContent=True))))
        sources = sorted(p for p in (root / 'Sources/Browser').glob('*.swift') if p.name != 'main.swift')
        build = subprocess.run(['swiftc', '-parse-as-library', *map(str, sources), str(root / 'tests/input_host_probe.swift'),
                                '-o', str(executable)], capture_output=True, text=True, timeout=90)
        (out / 'input-host-build.log').write_text(build.stdout + build.stderr)
        assert build.returncode == 0, 'See input-host-build.log'
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        host_report = out / 'input-host.json'
        with (out / 'input-host.log').open('w') as log:
            host = subprocess.run([str(executable), page, str(host_report)], stdout=log, stderr=log, timeout=30)
        assert host.returncode == 0 and json.loads(host_report.read_text())['ok'], host_report
        (out / 'keyboard.json').write_text(json.dumps(evidence, indent=2))
    finally:
        for space in ['keyboard-work', 'keyboard-peer']:
            cli('space', 'delete', space)
    return 'directed focus/key defaults, trusted page events distinct from physical input/business; main/open-shadow targets, preventDefault, 2 POSTs, multi-Space/Tab, stale/reload/restart/suspend/hang recovery and unchanged foreground'
