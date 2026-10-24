"""Scoped locators and stale frame/shadow references in a real WKWebView."""
from urllib.parse import urljoin


def verify_contexts(cli, base):
    name = 'contexts'
    cli('space', 'create', name, '--proxy', 'direct')

    def command(*args, **kwargs):
        return cli(*args, '--space', name, **kwargs)

    def js(source):
        return command('evaluate', source)['value']

    try:
        command('open', urljoin(base, '/contexts'))
        command('wait', '#frame >>> #inner >>> input')
        snap = command('snapshot')['value']
        def ref(label):
            return next(el['ref'] for el in snap['elements'] if el['name'] == label)
        assert len({el['ref'] for el in snap['elements']}) == len(snap['elements'])
        assert next(el for el in snap['elements'] if el['name'] == 'Main input')['context'] == []
        assert [c['kind'] for c in next(el for el in snap['elements'] if el['name'] == 'Frame shadow input')['context']] == ['frame', 'shadow']
        assert snap['unsupported'][0]['code'] == 'unsupported_context'
        for target, value in [(ref('Shadow input'), 'shadow'), ('#frame >>> #same', 'frame'),
                              ('#host >>> #nested >>> input', 'nested'), (ref('Frame shadow input'), 'inner')]:
            command('fill', target, value)
            command('wait', target)
        command('click', ref('Shadow button'))
        command('click', '#frame >>> #save')
        assert js('document.querySelector("#host").shadowRoot.querySelector("output").textContent') == 'shadow'
        assert js('document.querySelector("#frame").contentDocument.querySelector("#result").textContent') == 'frame'
        assert js('document.querySelector("#frame").contentWindow.frameInputEvents') == [{'type': 'input', 'trusted': False}]
        assert js('document.querySelector("#same").value') == ''
        js('document.querySelector("#host").style.display="contents"; true')
        assert any(el['name'] == 'Shadow input' for el in command('snapshot')['value']['elements'])
        command('fill', '#frame >>> #choice', 'b')
        assert js('document.querySelector("#frame").contentDocument.querySelector("#choice").value') == 'b'
        for target in ['#cross >>> input', '#closed >>> input']:
            command('wait', target, error='unsupported_context')
            command('click', target, error='unsupported_context')
            command('fill', target, 'no', error='unsupported_context')
        command('click', 'iframe >>> input', error='selector_count')
        command('wait', '#frame >>> [', error='invalid_selector')
        js('document.querySelector("#host").hidden=true; true')
        command('click', ref('Shadow button'), error='element_not_actionable')
        command('wait', ref('Shadow input'), '--timeout', '100', error='timeout')
        js('document.querySelector("#host").hidden=false; document.querySelector("#frame").hidden=true; true')
        command('click', ref('Frame button'), error='element_not_actionable')
        js('document.querySelector("#frame").hidden=false; true')
        command('evaluate', 'new Promise(resolve=>{const f=document.querySelector("#frame"); f.onload=()=>resolve(true); f.src="/context-frame?new=1"})', '--await')
        command('click', ref('Frame button'), error='stale_ref')
        command('fill', ref('Frame shadow input'), 'no', error='stale_ref')
        command('wait', '#frame >>> #same')
        current = command('snapshot')['value']
        current_frame_ref = next(el['ref'] for el in current['elements'] if el['name'] == 'Frame button')
        command('evaluate', 'new Promise(resolve=>{const f=document.querySelector("#frame"); f.onload=()=>resolve(true); f.src=location.origin.replace("127.0.0.1","localhost")+"/context-frame"})', '--await')
        command('click', current_frame_ref, error='stale_ref')
        assert command('snapshot')['value']['unsupported']
        js('document.querySelector("#host").replaceWith(document.querySelector("#host").cloneNode()); true')
        command('fill', ref('Shadow input'), 'no', error='stale_ref')
        command('reload')
        command('click', ref('Main button'), error='stale_ref')
        assert command('snapshot')['value']['elements']
        return 'open/nested shadow and same-origin frame scopes; cross-origin/closed rejection; frame realm input events; hidden ancestors; refs invalidated on frame navigation, host replacement and reload'
    finally:
        cli('space', 'delete', name)
