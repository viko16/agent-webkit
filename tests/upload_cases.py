"""Background DataTransfer, real multipart bytes and independent host confirmation."""
import base64
import json
import time
from urllib.parse import urljoin


def verify_proxy_uploads(cli, target, out, events, nonce, whistle):
    upload_out = out / 'uploads'
    upload_out.mkdir()
    def upload_cli(*parameters, error=None):
        result = cli(*parameters, ok=error is None)
        if error:
            assert result['code'] == error, result
            return {'error': result}
        return result
    # Keep a real earlier POST, as an existing Whistle can contain task history.
    cli('space', 'create', 'upload-history', '--proxy', whistle.url, '--ignore-certificate-errors')
    try:
        cli('open', target, '--space', 'upload-history')
        cli('evaluate', 'fetch("/upload",{method:"POST",body:new FormData()}).then(r=>r.json())', '--await', '--space', 'upload-history')
    finally:
        cli('space', 'delete', 'upload-history')
    prior = {item.get('id') for item in whistle.sessions()}
    result = verify_uploads(upload_cli, target, upload_out, events, nonce, proxy=whistle.url, insecure=True)
    for _ in range(100):
        posts = [item for item in whistle.sessions() if item.get('url') == 'https://example.com/upload'
                 and item.get('req', {}).get('method') == 'POST' and item.get('id') not in prior]
        if posts:
            break
        time.sleep(.05)
    assert len(posts) == 1, posts
    return dict(passed=True, **result, whistlePostCount=len(posts))


def verify_uploads(cli, base, out, events, nonce, proxy='direct', insecure=False):
    name, peer = 'upload-work', 'upload-peer'
    tls = ('--ignore-certificate-errors',) if insecure else ()
    work = cli('space', 'create', name, '--proxy', proxy, *tls)
    cli('space', 'create', peer, '--proxy', proxy, *tls)
    url = urljoin(base, '/files')
    target = cli('tab', 'new', url, '--space', name)['tabId']
    flags = ('--space', name, '--tab', target)
    folder = out / 'upload-inputs'
    folder.mkdir()
    text, binary, empty = folder / '中文.txt', folder / 'bytes.bin', folder / 'empty.txt'
    text.write_text('真实上传\nUnicode content')
    binary.write_bytes(bytes(range(256)))
    empty.write_bytes(b'')

    def command(*args, **kwargs):
        return cli(*args, *flags, **kwargs)

    def names(selector):
        return command('evaluate', f'Array.from(document.querySelector({json.dumps(selector)}).files,f=>f.name)')['value']

    try:
        cli('open', url, '--space', peer)
        before = cli('status')
        existing = len([e for e in events.items if e['kind'] == 'file-upload'])
        command('upload', '#single', str(text))
        assert names('#single') == [text.name]
        command('upload', '#single', str(text), str(binary), error='upload_multiple_not_allowed')
        command('upload', '#disabled', str(text), error='element_not_actionable')
        command('upload', '#not-file', str(text), error='unsupported_upload_target')
        command('upload', '#single', 'relative.txt', error='invalid_arguments')
        command('upload', '#single', str(folder), error='file_unreadable')
        command('upload', '#single', str(folder / 'missing.txt'), error='file_unreadable')
        denied = folder / 'denied.txt'
        denied.write_text('not readable')
        try:
            denied.chmod(0)
            command('upload', '#single', str(denied), error='file_unreadable')
        finally:
            denied.chmod(0o600)
        large = folder / 'large.bin'
        with large.open('wb') as stream:
            stream.truncate(4 * 1024 * 1024 + 1)
        command('upload', '#single', str(large), error='upload_too_large')
        with large.open('wb') as stream:
            stream.truncate(4 * 1024 * 1024)
        command('upload', '#multiple', str(large), str(text), error='upload_too_large')
        assert names('#single') == [text.name]
        boundary = command('upload', '#single', str(large))['value']
        assert boundary['files'][0]['size'] == 4 * 1024 * 1024
        command('upload', '#multiple', *([str(empty)] * 16))
        assert len(names('#multiple')) == 16
        command('upload', '#multiple', *([str(text)] * 17), error='invalid_arguments')
        snap = command('snapshot')['value']
        ref = next(e['ref'] for e in snap['elements'] if e['name'] == 'Multiple files')
        result = command('upload', ref, str(text), str(binary), str(empty))['value']
        assert result['method'] == 'dom-data-transfer' and result['nativeVerified'] is False
        assert result['requiresForeground'] is False and result['businessOutcomeVerified'] is False
        assert names('#multiple') == [text.name, binary.name, empty.name]
        assert all(not event['trusted'] for event in command('evaluate', 'window.uploadEvents')['value'])
        assert len([e for e in events.items if e['kind'] == 'file-upload']) == existing
        command('click', '#send')
        command('wait', '#result', '--text', nonce)
        command('wait', '#never-confirmed', '--timeout', '100', error='timeout')
        expected = [dict(name=p.name, data=base64.b64encode(p.read_bytes()).decode()) for p in (text, binary, empty)]
        actual = [e for e in events.items if e['kind'] == 'file-upload']
        assert len(actual) == existing + 1 and actual[-1]['files'] == expected, actual
        assert command('evaluate', 'window.uploadResponse')['value'] == dict(nonce=nonce, files=expected)
        assert cli('evaluate', 'document.querySelector("#multiple").files.length', '--space', peer)['value'] == 0
        assert cli('space', 'info', name)['defaultTabId'] == work['defaultTabId']
        command('reload')
        assert names('#multiple') == []
        command('upload', ref, str(empty), error='stale_ref')
        command('evaluate', 'const frame=document.createElement("iframe");frame.id="files-frame";frame.src="/files";document.body.append(frame);const host=document.createElement("div");host.id="file-host";host.attachShadow({mode:"open"}).innerHTML="<input type=file id=shadow-file>";document.body.append(host);true')
        command('wait', '#files-frame >>> #single')
        command('upload', '#files-frame >>> #single', str(text))
        command('upload', '#file-host >>> #shadow-file', str(binary))
        assert command('evaluate', 'document.querySelector("#files-frame").contentDocument.querySelector("#single").files[0].name')['value'] == text.name
        assert command('evaluate', 'document.querySelector("#file-host").shadowRoot.querySelector("input").files[0].size')['value'] == 256
        cli('space', 'suspend', name)
        command('upload', '#multiple', str(empty))
        assert names('#multiple') == [empty.name]
        assert cli('status')['frontmostPid'] == before['frontmostPid']
        report = dict(backgroundUpload=True, realMultipartFiles=3, submissions=1, untrustedEvents=True,
                      limitsAndPermissions=True, targetIsolation=True, reloadClearsFiles=True, resumeUpload=True,
                      foregroundUnchanged=True, nativeVerified=False, proxy=proxy)
        (out / 'uploads.json').write_text(json.dumps(report, indent=2))
        return report
    finally:
        cli('space', 'delete', name)
        cli('space', 'delete', peer)
