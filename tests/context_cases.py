"""Scoped locators and stale frame/shadow references in a real WKWebView."""
from urllib.parse import urljoin


def verify_visibility_and_clicks(command, js):
    js('''(()=>{
        const frame=document.querySelector('#frame'), wrapper=document.createElement('div');
        wrapper.style.visibility='hidden'; frame.before(wrapper); wrapper.append(frame); frame.style.visibility='visible'; return true;
    })()''')
    # Moving an iframe reloads its document; populate only the replacement.
    command('wait', '#frame >>> #same')
    js('''(()=>{
        document.body.insertAdjacentHTML('beforeend', `
          <section id="compat">
            <div style="visibility:hidden">Inherited hidden text
              <button id="compat-visible" style="visibility:visible">Visibility override button</button>
              <button id="compat-inherited">Inherited hidden button</button>
              <span style="visibility:visible">Visibility override text</span>
            </div>
            <div style="display:none"><button id="compat-display" style="visibility:visible">Display blocked button</button></div>
            <div style="opacity:0"><button id="compat-opacity" style="visibility:visible">Opacity blocked button</button></div>
            <div inert><button id="compat-inert" style="visibility:visible">Inert blocked button</button></div>
            <div hidden><button id="compat-hidden" style="visibility:visible">Hidden blocked button</button></div>
            <div id="compat-shadow" style="visibility:hidden"></div>
            <svg id="compat-svg" role="button" aria-label="Main SVG button" width="80" height="40"><rect width="80" height="40" /></svg>
            <input id="compat-checkbox" type="checkbox" aria-label="Native checkbox">
            <label id="compat-label" for="compat-checkbox">Native checkbox label</label>
          </section>`);
        const shadow=document.querySelector('#compat-shadow').attachShadow({mode:'open'});
        shadow.innerHTML=`<button id="visible" style="visibility:visible">Shadow override button</button>
          <button id="inherited">Shadow inherited button</button>
          <svg id="compat-shadow-svg" style="visibility:visible" role="button" aria-label="Shadow SVG button" width="80" height="40"><rect width="80" height="40" /></svg>`;
        const frame=document.querySelector('#frame'), doc=frame.contentDocument, view=doc.defaultView;
        doc.body.insertAdjacentHTML('beforeend', `
          <div style="visibility:hidden"><button id="compat-frame-visible" style="visibility:visible">Frame override button</button>
            <button id="compat-frame-inherited">Frame inherited button</button></div>
          <svg id="compat-frame-svg" role="button" aria-label="Frame SVG button" width="80" height="40"><rect width="80" height="40" /></svg>`);
        window.compatClicks=[]; window.compatSVG=[]; window.compatCheckboxClicks=0; window.compatShadowBubbles=0;
        for(const button of [document.querySelector('#compat-visible'),shadow.querySelector('#visible'),doc.querySelector('#compat-frame-visible')])
          button.addEventListener('click',()=>window.compatClicks.push(button.id));
        document.querySelector('#compat-checkbox').addEventListener('click',()=>window.compatCheckboxClicks++);
        for(const [svg,realm] of [[document.querySelector('#compat-svg'),window],[shadow.querySelector('svg'),window],[doc.querySelector('svg'),view]])
          svg.addEventListener('click',event=>{
            event.preventDefault();
            window.compatSVG.push({id:svg.id,trusted:event.isTrusted,mouse:event instanceof realm.MouseEvent,
              view:event.view===realm,bubbles:event.bubbles,cancelable:event.cancelable,composed:event.composed,cancelled:event.defaultPrevented});
          });
        document.querySelector('#compat-shadow').addEventListener('click',event=>{
          if(event.composedPath().some(node=>node.id==='compat-shadow-svg')) window.compatShadowBubbles++;
        });
        return true;
    })()''')
    snap = command('snapshot')['value']
    elements = {el['name']: el for el in snap['elements']}
    for label in ['Visibility override button', 'Shadow override button', 'Frame override button']:
        assert label in elements, (label, snap)
        command('wait', elements[label]['ref'])
        command('click', elements[label]['ref'])
    assert js('window.compatClicks') == ['compat-visible', 'visible', 'compat-frame-visible']
    assert 'Visibility override text' in snap['text'] and 'Visibility override button' in snap['text'], snap
    for label in ['Inherited hidden text', 'Inherited hidden button', 'Shadow inherited button', 'Frame inherited button',
                  'Display blocked button', 'Opacity blocked button', 'Inert blocked button', 'Hidden blocked button']:
        assert label not in elements and label not in snap['text'], (label, snap)
    for target in ['#compat-inherited', '#compat-display', '#compat-opacity', '#compat-inert', '#compat-hidden',
                   '#compat-shadow >>> #inherited', '#frame >>> #compat-frame-inherited']:
        command('wait', target, '--state', 'hidden')
        command('click', target, error='element_not_actionable')

    for label in ['Main SVG button', 'Shadow SVG button', 'Frame SVG button']:
        assert elements[label]['tag'] == 'svg' and elements[label]['role'] == 'button', elements[label]
        result = command('click', elements[label]['ref'])['value']
        assert result['method'] == 'dom' and result['nativeVerified'] is False and result['businessOutcomeVerified'] is False, result
    assert js('window.compatSVG') == [dict(id=target, trusted=False, mouse=True, view=True, bubbles=True,
                                         cancelable=True, composed=True, cancelled=True)
                                     for target in ['compat-svg', 'compat-shadow-svg', 'compat-frame-svg']]
    assert js('window.compatShadowBubbles') == 1
    command('click', '#compat-checkbox')
    assert js('({checked:document.querySelector("#compat-checkbox").checked,count:window.compatCheckboxClicks})') == dict(checked=True, count=1)
    command('click', '#compat-label')
    assert js('({checked:document.querySelector("#compat-checkbox").checked,count:window.compatCheckboxClicks})') == dict(checked=False, count=2)

    for hidden_style in ['visibility:hidden', 'display:none', 'opacity:0', 'width:0;border:0']:
        js(f'document.querySelector("#frame").style.cssText={("visibility:visible;" + hidden_style)!r}; true')
        hidden = command('snapshot')['value']['elements']
        assert not any(el['name'] in ['Frame override button', 'Frame SVG button'] for el in hidden), (hidden_style, hidden)
        command('wait', '#frame >>> #compat-frame-visible', '--state', 'hidden')
        command('click', '#frame >>> #compat-frame-visible', error='element_not_actionable')
    js('document.querySelector("#frame").style.cssText="visibility:visible"; true')
    command('wait', '#frame >>> #compat-frame-visible')


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
        verify_visibility_and_clicks(command, js)
        return 'open/nested shadow and same-origin frame scopes; cross-origin/closed rejection; frame realm events; visibility overrides and hidden frame boundaries; SVG single synthetic clicks and native HTML activation; refs invalidated on frame navigation, host replacement and reload'
    finally:
        cli('space', 'delete', name)
