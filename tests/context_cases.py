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


def verify_scoped_actions(command, js):
    js('''document.body.insertAdjacentHTML('afterbegin', `
      <section id="work">
        <p>Inside scope</p><div role="status">Status</div>
        <button class="action" aria-label="Save form">Apply</button>
        <button disabled>Unavailable</button>
        <input id="opt-in" type="checkbox">
        <select id="color"><option value="red">Red</option><option value="blue">Blue</option>
          <optgroup disabled><option value="blocked">Blocked</option></optgroup></select>
      </section>
      <button class="action" aria-label="Save form">Other</button>
      <dialog id="cover"><p>Modal</p></dialog>
      <div id="clip" style="position:relative;overflow:clip;height:10px"><button id="clipped" style="position:absolute;top:40px">Clipped</button></div>
      <div style="height:1200px"></div><button id="after-scroll">After scroll</button>`);
      window.actions=[];
      for(const [selector,types] of [['#work .action',['click']],['#after-scroll',['click']],['#opt-in',['click','input','change']],['#color',['input','change']]])
        for(const type of types) document.querySelector(selector).addEventListener(type,e=>actions.push([selector,e.type]));
      true''')
    full = command('snapshot')['value']
    old = next(e['ref'] for e in full['elements'] if e['name'] == 'Main button')
    scoped = command('snapshot', '--scope', '#work')['value']
    assert scoped['scopeTarget'] == '#work' and scoped['textScope'] == 'selected-subtree'
    assert 'Inside scope' in scoped['text'] and 'Other' not in scoped['text']
    assert 0 < scoped['scannedNodes'] < full['scannedNodes'] <= scoped['scanBudget'] == 10000
    command('click', old, error='stale_ref')
    brief = command('snapshot', '--scope', '#work', '--interactive')['value']
    assert brief['interactive'] and brief['text'] == '' and not brief['truncated']
    assert len(brief['elements']) == 3 and not any(e['disabled'] or e['role'] == 'status' for e in brief['elements'])
    js('document.querySelector("#work").insertAdjacentHTML("beforeend", `<div aria-hidden="true"><button>Save form</button></div>`);true')
    command('snapshot', '--role', 'button', '--name', 'Save form', error='selector_count')
    ref = command('snapshot', '--scope', '#work', '--role', 'button', '--name', 'Save form')['value']['elements'][0]['ref']
    js('document.querySelector("#cover").showModal();true')
    command('click', ref, error='element_not_actionable')
    js('document.querySelector("#cover").close(); document.body.insertAdjacentHTML("beforeend", `<div id="clear-overlay" style="position:fixed;inset:0;opacity:0;z-index:99"></div>`);true')
    for target in (ref, '#compat-shadow >>> #visible', '#frame >>> #compat-frame-visible'):
        command('click', target, error='element_not_actionable')
    js('document.querySelector("#clear-overlay").remove();true')
    command('click', '#clipped', error='element_not_actionable')
    command('click', '#work button[disabled]', error='element_not_actionable')
    clicked = command('click', ref)['value']
    assert clicked['hitTest']['scope'] == 'through-same-origin-ancestors' and not clicked['nativeVerified']
    command('click', '#after-scroll')
    assert js('scrollY') > 0
    assert command('scroll', '0', '-100000')['value']['after']['y'] == 0
    assert command('scroll', '0', '50')['value']['after']['y'] == 50
    assert command('check', '#opt-in')['value']['changed']
    assert not command('check', '#opt-in')['value']['changed']
    assert command('uncheck', '#opt-in')['value']['changed']
    assert not command('uncheck', '#opt-in')['value']['changed']
    command('check', '#color', error='unsupported_checkbox_target')
    changed = command('select', '#color', 'blue')['value']
    assert changed['selectedValue'] == 'blue' and changed['events'] == ['input', 'change']
    assert not command('select', '#color', 'blue')['value']['changed']
    command('select', '#color', 'blocked', error='invalid_option')
    assert js('document.querySelector("#color").value') == 'blue'
    js('const select=document.querySelector("#color");select.setAttribute("aria-label","Color");for(let i=0;i<101;i++)select.add(new Option(String(i),String(i)));true')
    located = command('snapshot', '--scope', '#color', '--role', 'combobox', '--name', 'Color')['value']
    assert located['truncated'] and len(located['elements']) == 1 and len(located['elements'][0]['options']) == 100
    js('document.querySelector("#color").add(new Option("Alternate blue","blue",false,true));true')
    assert not command('select', '#color', 'blue')['value']['changed']
    assert js('document.querySelector("#color").selectedOptions[0].textContent') == 'Alternate blue'
    assert js('actions') == [['#work .action', 'click'], ['#after-scroll', 'click']] + [
        ['#opt-in', event] for event in ('click', 'input', 'change') * 2] + [
        ['#color', 'input'], ['#color', 'change']]
    js('document.querySelector("#opt-in").onclick=e=>e.preventDefault();true')
    command('check', '#opt-in', error='dom_state_mismatch')
    assert not js('document.querySelector("#opt-in").checked')
    js('document.querySelector("#color").onchange=e=>e.target.value="blue";true')
    command('select', '#color', 'red', error='dom_state_mismatch')
    assert js('document.querySelector("#color").value') == 'blue'
    js('document.body.insertAdjacentHTML("afterbegin", `<button name="internal"></button><input type="search" aria-label="Search"><a href="/help"><img alt="Help" width="40" height="20"></a>`);true')
    command('snapshot', '--role', 'button', '--name', 'internal', error='selector_count')
    assert command('snapshot', '--role', 'searchbox', '--name', 'Search')['value']['elements'][0]['tag'] == 'input'
    assert command('snapshot', '--role', 'link', '--name', 'Help')['value']['elements'][0]['tag'] == 'a'
    js('document.body.insertAdjacentHTML("afterbegin", `<span id="labelled-save">Save draft<span aria-hidden="true">Icon</span></span><button aria-labelledby="labelled-save">Save</button>`);true')
    assert command('snapshot', '--role', 'button', '--name', 'Save draft')['value']['elements'][0]['tag'] == 'button'
    js('document.querySelector("#color").onchange=e=>e.target.insertBefore(new Option("Prompt",""),e.target.firstChild);true')
    assert command('select', '#color', 'red')['value']['selectedValue'] == 'red'


def verify_contexts(cli, base):
    name = 'contexts'
    tab = cli('space', 'create', name, '--proxy', 'direct')['defaultTabId']

    def command(*args, **kwargs):
        return cli(*args, '--space', name, '--tab', tab, **kwargs)

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
        verify_scoped_actions(command, js)
        return 'frame/shadow scopes and stale refs; scoped and unique role/name snapshots; SVG/HTML DOM clicks, modal/transparent/frame/shadow obstruction and scroll; idempotent select/check/uncheck with event counts'
    finally:
        cli('space', 'delete', name)
