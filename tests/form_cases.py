"""Real React/Vue state, server submissions and basic rich-text replacement."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


@contextmanager
def framework_site(out):
    fixture = ROOT / 'tests/forms'
    assert (fixture / 'node_modules/vite').is_dir(), 'Run npm ci --prefix tests/forms first'
    log_path = out / 'forms-server.log'
    with log_path.open('w') as log:
        process = subprocess.Popen(['node', str(fixture / 'server.mjs')], cwd=fixture,
                                   env=dict(os.environ, FORM_LOG=str(out / 'submissions.jsonl')),
                                   stdout=log, stderr=log)
        try:
            for _ in range(150):
                assert process.poll() is None, log_path.read_text()
                urls = [line.removeprefix('FORM_URL=') for line in log_path.read_text().splitlines()
                        if line.startswith('FORM_URL=')]
                if urls:
                    base = urls[0]
                    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                    with opener.open(base + 'api/health', timeout=5) as response:
                        nonce = json.load(response)['nonce']
                    yield base, nonce
                    break
                time.sleep(.1)
            else:
                raise AssertionError(f'Vite startup timed out: {log_path.read_text()}')
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=5)


def verify_forms(cli, base, nonce, out):
    name = 'forms'
    cli('space', 'create', name, '--proxy', 'direct')

    def command(*args, **kwargs):
        if args[0] == 'wait' and '--timeout' not in args:
            args = (*args, '--timeout', '5000')
        return cli(*args, '--space', name, **kwargs)

    def js(source):
        return command('evaluate', source)['value']

    def action(*args):
        result = command(*args)['value']
        assert result['method'] == 'dom'
        assert result['nativeVerified'] is False and result['businessOutcomeVerified'] is False
        return result

    expected = []
    try:
        focus = cli('status')['frontmostPid']
        command('open', base)
        command('wait', '#react-text')
        command('wait', '#vue-text')
        versions = js('window.frameworkVersions')
        packages = json.loads((ROOT / 'tests/forms/package-lock.json').read_text())['packages']
        expected_versions = {name: packages[f'node_modules/{name}']['version'] for name in ('react', 'vue')}
        assert versions == expected_versions, (versions, expected_versions)
        for framework in ['react', 'vue']:
            prefix = '#' + framework
            command('wait', prefix + '-submit', '--state', 'disabled')
            command('click', prefix + '-submit', error='element_not_actionable')
            for suffix, error in [('-readonly', 'element_readonly'), ('-disabled', 'element_not_actionable')]:
                command('fill', prefix + suffix, 'must not change', error=error)
                assert js(f'document.querySelector("{prefix + suffix}").value') == 'locked'
            action('click', prefix + '-accepted')
            command('wait', prefix + '-submit', '--state', 'enabled')
            for index in range(2):
                text = f'{framework} 中文 ✓ {index}'
                note = f'first line {index}\n第二行'
                choice = 'b' if index == 0 else 'a'
                action('fill', prefix + '-text', text)
                action('fill', prefix + '-note', note)
                action('fill', prefix + '-choice', choice)
                command('wait', prefix + '-state', '--text', text)
                old_ref = next(el['ref'] for el in command('snapshot')['value']['elements']
                               if el['name'] == framework.capitalize() + ' text')
                action('click', prefix + '-replace')
                command('wait', prefix + '-state', '--text', f'"generation":{index + 1}')
                command('fill', old_ref, 'stale', error='stale_ref')
                assert js(f'document.querySelector("{prefix}-text").value') == text
                action('click', prefix + '-submit')
                command('wait', prefix + '-result', '--text', text)
                command('wait', prefix + '-submit', '--state', 'enabled')
                fields = dict(framework=framework, text=text, note=note, choice=choice, accepted=True)
                record = dict(nonce=nonce, fields=fields, accepted=True)
                actual = js(f'JSON.parse(document.querySelector("{prefix}-result").textContent.slice(7))')
                assert actual == record, actual
                expected.append(record)
            action('fill', prefix + '-text', '')
            command('wait', prefix + '-state', '--text', '"text":""')
            action('fill', prefix + '-text', 'reject')
            action('click', prefix + '-submit')
            command('wait', prefix + '-result', '--text', 'Rejected by server')
            command('wait', prefix + '-result', '--text', 'Saved:', '--timeout', '120', error='timeout')
            expected.append(dict(nonce=nonce, fields=dict(framework=framework, text='reject',
                                                        note=note, choice=choice, accepted=True), accepted=False))
        received = [json.loads(line) for line in (out / 'submissions.jsonl').read_text().splitlines()]
        assert received == expected, received  # Actual POST payloads, no duplicate submission/retry.
        rich = 'plain <b>text</b>\n中文 ✓'
        action('fill', '#rich', rich)
        assert js('document.querySelector("#rich").textContent') == rich
        assert js('document.querySelector("#rich").children.length') == 0
        command('wait', '#rich-result', '--text', rich)
        events = js('window.formEvents')
        # WebKit may mark the checkbox's derived input event trusted; its DOM click is still untrusted.
        filled_events = [event for event in events if not event['id'].endswith('-accepted')]
        assert filled_events and all(event['trusted'] is False for event in filled_events), events
        assert js('window.checkboxClicks') == [{'id': framework + '-accepted', 'trusted': False}
                                              for framework in ['react', 'vue']]
        assert all(event['inputEvent'] and event['inputType'] == 'insertReplacementText'
                   for event in events if event['id'] in ['react-text', 'vue-text', 'rich']), events
        command('fill', '#rich-readonly', 'must not change', error='element_readonly')
        assert js('document.querySelector("#rich-readonly").textContent') == 'Read only rich text'
        command('fill', '#aria-disabled', 'must not change', error='element_not_actionable')
        snapshot = command('snapshot')['value']
        assert next(el for el in snapshot['elements'] if el['name'] == 'Read only rich text')['readOnly']
        command('screenshot', '--out', str(out / 'forms.png'))
        (out / 'form-events.json').write_text(json.dumps(events, indent=2))
        assert cli('status')['frontmostPid'] == focus
        return dict(frameworks=versions, submissions=len(received), checks=[
            'controlled input/textarea/select/checkbox; empty and Unicode values',
            'keyed rerender preserves framework state and invalidates old refs',
            'real POST payloads and rejected business outcome; no replay',
            'readonly/disabled/aria restrictions; plain-text contenteditable replacement',
            'untrusted InputEvent; bounded result waits; background screenshot and unchanged foreground'])
    finally:
        cli('space', 'delete', name)
