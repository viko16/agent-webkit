"""Wait for observable outcomes without client-side sleeps or action replay."""
from urllib.parse import urljoin
import time


def verify_waits(cli, base):
    name = 'conditions'
    cli('space', 'create', name, '--proxy', 'direct')

    def command(*args, **kwargs):
        return cli(*args, '--space', name, **kwargs)

    def js(source):
        return command('evaluate', source)['value']

    try:
        command('open', base)
        for args in [('--state', 'enabled'), ('#message', '--state', 'unknown'),
                     ('#message', '--url', base), ('--text', ''), ('--url', ''),
                     ('#message', '--text', 'a', '--state', 'visible')]:
            command('wait', *args, error='invalid_arguments')
        js('document.body.insertAdjacentHTML("beforeend", `<button id="pending" disabled>Working</button><output id="outcome"></output>`); true')
        command('wait', '#pending', '--state', 'disabled')
        js('setTimeout(()=>{document.querySelector("#pending").disabled=false; document.querySelector("#outcome").textContent="保存成功 ✓"},150); true')
        command('wait', '#pending', '--state', 'enabled')
        command('wait', '#outcome', '--text', '保存成功 ✓')
        command('wait', '--text', '保存成功')
        command('wait', '#outcome', '--text', '未出现', '--timeout', '120', error='timeout')
        js('document.querySelector("#outcome").hidden=true; true')
        command('wait', '#outcome', '--state', 'attached')
        command('wait', '#outcome', '--state', 'hidden')
        command('wait', '#outcome', '--text', '保存成功', '--timeout', '120', error='timeout')
        js('setTimeout(()=>document.querySelector("#outcome").remove(),150); true')
        command('wait', '#outcome', '--state', 'detached')
        command('wait', '#outcome', '--state', 'hidden')
        command('wait', '#outcome', '--state', 'disabled', '--timeout', '120', error='timeout')
        ref = next(el['ref'] for el in command('snapshot')['value']['elements'] if el['name'] == 'Working')
        js('document.querySelector("#pending").remove(); true')
        command('wait', ref, '--state', 'detached', error='stale_ref')
        command('wait', 'p', '--state', 'attached', error='selector_count')
        command('wait', '[', '--state', 'hidden', error='invalid_selector')
        destination = base + '?completed=1#done'
        js('setTimeout(()=>history.pushState({},"", "?completed=1#done"),150); true')
        command('wait', '--url', destination)
        command('wait', '--url-pattern', base + '*#done', '--stable-for', '100')
        command('wait', '--url-pattern', base + '*#missing', '--timeout', '120', error='timeout')
        js('window.readyForTest=true; setTimeout(()=>readyForTest=false,130); true')
        command('wait', '--fn', '() => window.readyForTest', '--stable-for', '220', '--timeout', '350', error='timeout')
        js('fetch("/resource?delay=0.2").then(r=>r.json()).then(r=>{window.readyForTest=!!r.nonce}); true')
        started = time.monotonic()
        command('wait', '--fn', '() => window.readyForTest', '--stable-for', '200')
        assert time.monotonic() - started >= .3, 'Wait returned before the API and stability interval'
        command('wait', '--fn', 'async () => true', error='javascript_error')
        command('wait', '#message', '--fn', '() => true', error='invalid_arguments')
        command('wait', '--stable-for', '200', '--timeout', '100', error='invalid_arguments')
        command('wait', '--url', base, '--timeout', '120', error='timeout')
        js('setTimeout(()=>location.href="?navigation=1",150); true')
        command('wait', '--url', base + '?navigation=1')
        command('wait')  # URL matching does not promise a fully loaded document.
        command('open', urljoin(base, '/contexts'))
        command('fill', '#frame >>> #same', 'frame result')
        command('click', '#frame >>> #save')
        command('wait', '#frame >>> #result', '--text', 'frame result')
        tab_id = command('state')['page']['tabId']
        frames = command('frame', 'list', '--tab', tab_id)['value']['frames']
        same_frame = next(frame['frameId'] for frame in frames if '/context-frame' in frame['url'] and frame['url'].startswith(base.split('/index.html')[0]))
        command('wait', '--tab', tab_id, '--frame', same_frame, '--fn', '() => document.querySelector("#result").textContent === "frame result"')
        command('fill', '#host >>> input', 'shadow result')
        command('click', '#host >>> button')
        command('wait', '#host >>> output', '--text', 'shadow result')
        command('wait', '#cross >>> input', '--state', 'hidden', error='unsupported_context')
        return 'bounded URL/text/DOM-state waits; SPA and document navigation; absent/hidden/multiple/stale targets; frame/shadow scopes; invalid combinations'
    finally:
        cli('space', 'delete', name)
