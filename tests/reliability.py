"""Exercise bounded WebKit calls, recovery and CLI contracts in a real isolated app."""
from concurrent.futures import ThreadPoolExecutor
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

from fixtures import origin
from popup_cases import verify_popups
from context_cases import verify_contexts
from wait_cases import verify_waits
from form_cases import framework_site, verify_forms
from diagnostic_cases import verify_diagnostics
from detailed_diagnostic_cases import verify_detailed_diagnostics
from store_cleanup_cases import verify_pending_store_only, verify_store_cleanup_failures, verify_delete_persistence_failure
from contract_cases import verify_offline, verify_live_contract
from dialog_cases import verify_dialogs
from lifecycle_cases import verify_lifecycle
from download_cases import verify_downloads
from upload_cases import verify_uploads
from screenshot_cases import verify_screenshots, verify_fullpage
from state_integrity_cases import verify_state_integrity
from direct_conflict_cases import verify_proxy_summary
from capacity_cases import verify_capacity
from snapshot_budget_cases import verify_snapshot_budget
from skill_workflow import cleanup_test_services, verify_cleanup

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--forms', action='store_true', help='Run real React/Vue fixtures (npm ci --prefix tests/forms)')
    parser.add_argument('--integrity-only', action='store_true', help='Run navigation identity, configuration isolation and JavaScript error cases')
    parser.add_argument('--resources-only', action='store_true', help='Run creation, snapshot and download resource boundaries')
    parser.add_argument('--diagnostics-only', action='store_true', help='Run only the diagnostic regression cases')
    parser.add_argument('--cleanup-only', action='store_true', help='Run only pending-store restoration and cleanup failure isolation')
    parser.add_argument('--dialogs-only', action='store_true', help='Run only real JavaScript dialog cases')
    parser.add_argument('--lifecycle-only', action='store_true', help='Run only Space suspend/resume cases')
    parser.add_argument('--downloads-only', action='store_true', help='Run only native file download cases')
    parser.add_argument('--uploads-only', action='store_true', help='Run only real background multipart upload cases')
    parser.add_argument('--screenshots-only', action='store_true', help='Run only real screenshot geometry and pixel cases')
    args = parser.parse_args()
    if sum([args.resources_only, args.integrity_only, args.cleanup_only, args.diagnostics_only, args.dialogs_only, args.lifecycle_only, args.downloads_only, args.uploads_only, args.screenshots_only]) > 1 or (args.forms and (args.resources_only or args.integrity_only or args.cleanup_only or args.dialogs_only or args.lifecycle_only or args.downloads_only or args.uploads_only or args.screenshots_only)):
        parser.error('专项选项不能互相混用；--dialogs-only / --cleanup-only 不与 --forms 混用')
    out = ROOT / '.artifacts' / time.strftime('reliability-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    state = Path(tempfile.mkdtemp(prefix='awr-'))
    env = dict(os.environ, BROWSER_DATA_DIR=str(state), BROWSER_SOCKET=str(state / 'browser.sock'))
    binary = ROOT / '.build/debug/browser'
    app = ROOT / '.build/Agent WebKit.app/Contents/MacOS/browser'
    site, site_events = origin()
    base = f'http://127.0.0.1:{site.server_address[1]}/index.html'
    daemon = None
    logs = []
    checks = []
    report = dict(ok=False, checks=checks, artifacts=str(out))

    def cli(*args, error=None):
        started = time.monotonic()
        p = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=15)
        response = json.loads(p.stdout)
        with (out / 'commands.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(args=args, response=response, elapsed=time.monotonic() - started)) + '\n')
        assert p.returncode == (1 if error else 0), (args, response, p.stderr)
        assert response['ok'] == (error is None), (args, response)
        if error:
            assert response['error']['code'] == error, response
            return response
        return response['result']

    def start(*, executable=app, extra_env=None):
        nonlocal daemon
        log = (out / f'daemon-{len(logs)}.log').open('w')
        logs.append(log)
        daemon = subprocess.Popen([str(executable), 'daemon'], env=dict(env, **(extra_env or {})), stdout=log, stderr=log)
        for _ in range(100):
            assert daemon.poll() is None, f'App exited; see {log.name}'
            if (state / 'browser.sock').exists():
                try:
                    if cli('status')['ready']:
                        return
                except (AssertionError, json.JSONDecodeError):
                    pass
            time.sleep(.1)
        raise AssertionError('Startup timed out')

    def stop():
        before = cli('status')['shutdownImpact']
        result = cli('shutdown', '--all')
        assert result == dict(shutdown=True, shutdownImpact=before), result
        daemon.wait(timeout=15)

    def js(source, **kwargs):
        return cli('evaluate', source, '--space', 'work', **kwargs)

    def interrupt_restart():
        daemon.terminate(); daemon.wait(timeout=15)
        start()

    try:
        verify_offline(cli)
        cli('open', 'https://example.com', '--space', 'work', '--proxy', 'direct', error='invalid_arguments')
        start()
        if args.resources_only:
            checks.append(verify_capacity(cli, base, out, start, stop))
            checks.append(verify_snapshot_budget(cli, base, out))
            report = dict(ok=True, checks=checks, artifacts=str(out))
            return
        if args.integrity_only:
            checks.append(verify_state_integrity(cli, base, out, start, stop, state))
            checks.append(verify_proxy_summary(cli, start, stop, out, base))
            report = dict(ok=True, checks=checks, artifacts=str(out))
            return
        if args.screenshots_only:
            checks.append(verify_screenshots(cli, base, out, lambda: (stop(), start())))
            checks.append(verify_fullpage(cli, base, out, lambda: (stop(), start())))
            report = dict(ok=True, checks=checks, artifacts=str(out))
            return
        if args.uploads_only:
            checks.append(verify_uploads(cli, base, out, site_events, site.fixture_nonce))
            report = dict(ok=True, checks=checks, artifacts=str(out))
            return
        if args.downloads_only:
            checks.append(verify_downloads(cli, base, out, lambda: (stop(), start()), state))
            report = dict(ok=True, checks=checks, artifacts=str(out))
            return
        if args.lifecycle_only:
            checks.append(verify_lifecycle(cli, base, out, lambda: (stop(), start()), state, interrupt_restart, site_events))
            report = dict(ok=True, checks=checks, artifacts=str(out))
            return
        if args.dialogs_only:
            checks.append(verify_dialogs(cli, base, out, lambda: (stop(), start()), state))
            report = dict(ok=True, checks=checks, artifacts=str(out))
            return
        if args.diagnostics_only:
            checks.append(verify_diagnostics(cli, base, out, lambda: (stop(), start())))
            checks.append(verify_detailed_diagnostics(cli, base, out, lambda: (stop(), start()), verify_expiry=True))
            report = dict(ok=True, checks=checks, artifacts=str(out))
            return
        checks.append(verify_pending_store_only(cli, start, stop, state, base))
        checks.append(verify_store_cleanup_failures(cli, start, stop, state, base, out))
        checks.append(verify_delete_persistence_failure(cli, start, stop, state, base))
        if args.cleanup_only:
            report = dict(ok=True, checks=checks, artifacts=str(out))
            return
        checks.append(verify_state_integrity(cli, base, out, start, stop, state))
        checks.append(verify_proxy_summary(cli, start, stop, out, base))
        checks.append(verify_capacity(cli, base, out, start, stop))
        checks.append(verify_snapshot_budget(cli, base, out))
        checks.append(verify_lifecycle(cli, base, out, lambda: (stop(), start()), state, interrupt_restart, site_events))
        checks.append(verify_downloads(cli, base, out, lambda: (stop(), start()), state))
        checks.append(verify_uploads(cli, base, out, site_events, site.fixture_nonce))
        checks.append(verify_screenshots(cli, base, out, lambda: (stop(), start())))
        checks.append(verify_fullpage(cli, base, out, lambda: (stop(), start())))
        work = cli('space', 'create', 'work', '--proxy', 'direct')
        cli('space', 'create', 'other', '--proxy', 'direct')
        cli('open', base, '--space', 'work')
        cli('open', base, '--space', 'other')
        checks.append(verify_live_contract(cli, state / 'browser.sock'))
        focus = cli('status')['frontmostPid']
        assert js('typeof window.__agentWebKit')['value'] == 'undefined'
        cli('open', base + '?poison=1', '--space', 'work')
        for mutation in ['true', 'delete window.__agentWebKit',
                         'window.__agentWebKit={snapshot:()=>({forged:true}),act:()=>false,exists:()=>true}; true']:
            js(mutation)
            snap = cli('snapshot', '--space', 'work')['value']
            assert 'forged' not in snap
            bridge_ref = next(el['ref'] for el in snap['elements'] if el['tag'] == 'button')
            cli('fill', '#message', 'isolated', '--space', 'work')
            cli('click', bridge_ref, '--space', 'work')
            assert js('document.querySelector("#result").textContent')['value'] == 'isolated'
            cli('wait', '#missing', '--space', 'work', '--timeout', '100', error='timeout')
            cli('wait', '#message', '--space', 'work')
        assert cli('evaluate', 'Promise.resolve(window.fixtureNonce)', '--space', 'work', '--await')['value'] == site.fixture_nonce
        js('history.pushState({}, "", "?poison=1&spa=1"); true')
        cli('click', bridge_ref, '--space', 'work')
        js('document.querySelector("#save").replaceWith(document.querySelector("#save").cloneNode(true)); true')
        cli('click', bridge_ref, '--space', 'work', error='stale_ref')
        cli('reload', '--space', 'work')
        cli('click', bridge_ref, '--space', 'work', error='stale_ref')
        stop(); start()
        cli('wait', '#message', '--space', 'work')
        assert cli('snapshot', '--space', 'work')['value']['elements']
        assert js('window.__agentWebKit.snapshot().forged')['value'] is True
        cli('screenshot', '--space', 'work', '--out', str(out / 'isolated-bridge.png'))
        assert cli('status')['frontmostPid'] == focus
        cli('open', base, '--space', 'work')
        checks.append('isolated bridge resists page overwrite/delete; page evaluate and Promise; SPA/ref invalidation; reload/restart; background screenshot and unchanged foreground')
        def popup_cli(*args, ok=True):
            if ok:
                return cli(*args)
            # Share the existing CLI log and retain the expected structured failure contract.
            code = 'invalid_arguments' if '--wait-for-navigation' in args else 'unsupported_navigation' if '#external' in args else 'popup_not_opened'
            return cli(*args, error=code)['error']
        checks.append(verify_popups(popup_cli, base, lambda: (stop(), start())))
        checks.append(verify_contexts(cli, base))
        checks.append(verify_waits(cli, base))
        checks.append(verify_dialogs(cli, base, out, lambda: (stop(), start()), state))
        checks.append(verify_diagnostics(cli, base, out, lambda: (stop(), start())))
        checks.append(verify_detailed_diagnostics(cli, base, out, lambda: (stop(), start())))
        if args.forms:
            with framework_site(out) as (form_url, nonce):
                checks.append(verify_forms(cli, form_url, nonce, out))
        # Raw IPC gets the same validation as the CLI parser.
        with socket.socket(socket.AF_UNIX) as client:
            client.connect(str(state / 'browser.sock'))
            client.sendall(json.dumps(dict(command='snapshot', args=[], options={'space': 'work', 'proxy': 'direct'})).encode() + b'\n')
            response = json.loads(client.makefile('rb').readline())
            assert response['error']['code'] == 'invalid_arguments', response
        checks.append('CLI and raw IPC reject unsupported options; offline help/version')
        cli('fill', '--space', 'work', '--', '#message', '--literal-value')
        assert js('document.querySelector("#message").value')['value'] == '--literal-value'
        cli('wait', '[', '--space', 'work', error='invalid_selector')
        cli('wait', 'p', '--space', 'work', error='selector_count')
        js('document.querySelector("#message").style.visibility="hidden"')
        cli('wait', '#message', '--space', 'work', '--timeout', '120', error='timeout')
        js('document.querySelector("#message").style.visibility="visible"')
        cli('wait', '#message', '--space', 'work')
        cli('open', base + '?delay=1', '--space', 'work', '--timeout', '100', error='timeout')
        cli('open', base, '--space', 'work', '--timeout', '3000')
        assert cli('state', '--space', 'work')['page']['lastError'] is None
        js('document.body.insertAdjacentHTML("beforeend", `<fieldset disabled><input id="disabled"></fieldset><select id="choice"><option value="a">Alpha</option><option value="b" disabled>Beta</option></select><input type="password" id="password" value="secret">`)')
        cli('fill', '#disabled', 'x', '--space', 'work', error='element_not_actionable')
        cli('fill', '#choice', 'b', '--space', 'work', error='invalid_option')
        assert js('document.querySelector("#choice").value')['value'] == 'a'
        snapshot = cli('snapshot', '--space', 'work')['value']
        assert any(el['value'] == '[redacted]' for el in snapshot['elements'])
        assert 'secret' not in json.dumps(snapshot)
        ref = next(el['ref'] for el in snapshot['elements'] if el['tag'] == 'button')
        checks.append('literal CLI values; visible waits; selector errors; disabled fields; select validation; password redaction')

        assert cli('evaluate', 'Promise.resolve({answer:42})', '--space', 'work', '--await')['value'] == {'answer': 42}
        cli('evaluate', 'Promise.reject(new Error("expected rejection"))', '--space', 'work', '--await', error='javascript_error')
        with ThreadPoolExecutor(1) as pool:
            future = pool.submit(cli, 'evaluate', 'new Promise(resolve=>setTimeout(()=>resolve(1),1200))', '--space', 'work', '--await')
            # Observe actual busy state, not an arbitrary sleep before the concurrent checks.
            for _ in range(50):
                if cli('space', 'info', 'work')['busy']:
                    break
                time.sleep(.02)
            else:
                raise AssertionError('Never saw in-flight command')
            assert cli('state', '--space', 'work')['busy']
            cli('tab', 'list', '--space', 'work')
            cli('fill', '#message', 'no', '--space', 'work', error='space_busy')
            cli('shutdown', '--all', error='space_busy')
            assert len(cli('status')['shutdownImpact']['spaces']) == 2
            assert cli('evaluate', 'document.title', '--space', 'other')['value'] == 'Agent WebKit Fixture'
            assert future.result()['value'] == 1
        checks.append('Promise resolution/rejection; read-only state during a command; Space concurrency')

        second = cli('tab', 'new', base + '?second=1', '--space', 'work')
        cli('tab', 'default', second['tabId'], '--space', 'work')
        assert cli('state', '--space', 'work')['page']['tabId'] == second['tabId']
        js('history.pushState({}, "", "?spa=1"); localStorage.setItem("persistent","yes"); true')
        time.sleep(.2)
        stop(); start()
        cli('wait', '--space', 'work')
        assert cli('space', 'info', 'work')['defaultTabId'] == second['tabId']
        assert '?spa=1' in cli('state', '--space', 'work')['page']['url']
        assert js('localStorage.getItem("persistent")')['value'] == 'yes'
        cli('click', ref, '--space', 'work', '--tab', work['defaultTabId'], error='stale_ref')
        checks.append('explicit default tab; SPA URL and storage restore; stale refs after restart')

        # A real infinite JS loop must return a bounded error without blocking another Space.
        began = time.monotonic()
        cli('evaluate', 'localStorage.setItem("beforeHang","saved"); while(true) {}', '--space', 'work', '--timeout', '250', error='timeout')
        assert time.monotonic() - began < 3
        page = cli('state', '--space', 'work')['page']
        assert page['unresponsive'] and not cli('space', 'info', 'work')['busy']
        cli('snapshot', '--space', 'work', error='web_content_unresponsive')
        assert cli('evaluate', 'document.title', '--space', 'other')['value'] == 'Agent WebKit Fixture'
        cli('reload', '--space', 'work', '--timeout', '5000')
        assert cli('state', '--space', 'work')['page']['tabId'] == second['tabId']
        assert js('localStorage.getItem("beforeHang")')['value'] == 'saved'
        cli('snapshot', '--space', 'work')
        checks.append('real infinite JS deadline; released Space lock; other Space unaffected; explicit recovery preserves Tab ID and storage')

        cli('evaluate', 'new Promise(()=>{})', '--space', 'work', '--await', '--timeout', '150', error='timeout')
        cli('open', base, '--space', 'work', '--timeout', '5000')
        cli('screenshot', '--space', 'work', '--out', str(out / 'recovered.png'))
        assert (out / 'recovered.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
        cli('tab', 'close', second['tabId'], '--space', 'work')
        assert cli('space', 'info', 'work')['defaultTabId'] == work['defaultTabId']
        checks.append('never-settling Promise deadline; open recovery; real PNG; default fallback on tab close')
        subprocess.run(['python3', str(ROOT / 'tests/timing.py'), '--socket', str(state / 'browser.sock')], check=True, timeout=90)
        checks.append('existing timing regression suite')
        # Clear real data immediately even if WebKit retains an empty network session.
        cli('evaluate', 'while(true) {}', '--space', 'work', '--timeout', '100', error='timeout')
        cli('reload', '--space', 'work', '--timeout', '5000')
        deleted = cli('space', 'delete', 'work')
        assert deleted['websiteDataRemoved']
        assert cli('space', 'delete', 'other')['websiteDataRemoved']
        assert cli('space', 'list') == []
        recreated = cli('space', 'create', 'work', '--proxy', 'direct')
        assert recreated['id'] != work['id']
        cli('open', base, '--space', 'work')
        assert js('localStorage.getItem("beforeHang")')['value'] is None
        stop(); start()
        assert cli('status')['pendingStoreCleanup'] == 0
        assert not any(r['id'] == work['id'] for r in json.loads((state / 'spaces.json').read_text()))
        assert cli('space', 'delete', 'work')['websiteDataRemoved']
        assert json.loads((state / 'spaces.json').read_text()) == []
        checks.append('deletion after recovery clears data; same-name recreation is isolated; restart completes deferred container cleanup')
        report = {'ok': True, 'checks': checks, 'artifacts': str(out)}
    finally:
        original_error = sys.exc_info()[1]
        cleanup_errors = cleanup_test_services(cli, daemon, site)
        registry = state / 'spaces.json'
        if not cleanup_errors and daemon is not None:
            try:
                if registry.exists() and json.loads(registry.read_text()):
                    # A clean shutdown releases deferred empty Store containers.
                    start()
                    cleanup_errors.extend(cleanup_test_services(cli, daemon, site))
                if not cleanup_errors:
                    verify_cleanup(state)
            except Exception as error:
                cleanup_errors.append(error)
                cleanup_errors.extend(cleanup_test_services(cli, daemon, site))
        for log in logs:
            try:
                log.close()
            except Exception as error:
                cleanup_errors.append(error)
        if original_error is not None:
            report['ok'] = False
            report['error'] = dict(type=type(original_error).__name__, message=str(original_error))
        if cleanup_errors:
            report['ok'] = False
            report['cleanupErrors'] = [dict(type=type(error).__name__, message=str(error)) for error in cleanup_errors]
            (out / 'cleanup-errors.json').write_text(json.dumps(report['cleanupErrors'], indent=2))
        (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(json.dumps(report, ensure_ascii=False))
        if cleanup_errors and original_error is None:
            raise RuntimeError(f'Test cleanup failed; see {out / "cleanup-errors.json"}') from cleanup_errors[0]


if __name__ == '__main__':
    main()
