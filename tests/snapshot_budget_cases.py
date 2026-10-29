"""Exercise bounded snapshots against large real documents and scope boundaries."""
import json
import sys


def verify_snapshot_budget(cli, base, out):
    names = ('snapshot-budget', 'snapshot-budget-peer')
    created = []
    cases = []
    try:
        for name in names:
            cli('space', 'create', name, '--proxy', 'direct')
            created.append(name)
            cli('open', base, '--space', name)
        flags = ('--space', names[0])

        def evaluate(source, await_result=False):
            return cli('evaluate', source, *(['--await'] if await_result else []), '--timeout', '10000', *flags)['value']

        def snapshot(name, truncated):
            response = cli('snapshot', *flags)
            value = response['value']
            size = len(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode())
            assert size <= value['outputBudgetBytes'] == 1024 * 1024, (name, size)
            assert value['truncated'] is truncated, (name, value)
            assert len(value['text']) <= 20000 and len(value['elements']) <= 1000
            for element in value['elements']:
                assert all(len(element[field]) <= 200 for field in ('name', 'value', 'role', 'tag')), element
                assert len(element.get('options', [])) <= 100
                for option in element.get('options', []):
                    assert len(option['value']) <= 200 and len(option['label']) <= 200, option
            assert cli('evaluate', 'document.title', '--space', names[1])['value'] == 'Agent WebKit Fixture'
            cases.append(dict(case=name, bytes=size, elements=len(value['elements']), truncated=value['truncated']))
            return value

        ordinary = snapshot('ordinary', False)
        save = next(element for element in ordinary['elements'] if element['name'] == 'Save message')
        cli('fill', '#message', 'ordinary still works', *flags)
        cli('click', save['ref'], *flags)
        assert evaluate('document.querySelector("#result").textContent') == 'ordinary still works'

        evaluate('''new Promise(resolve=>{
          document.body.replaceChildren();
          const host=document.createElement('div');host.id='budget-shadow';document.body.append(host);
          host.attachShadow({mode:'open'}).innerHTML='<button>Shadow budget button</button>';
          const frame=document.createElement('iframe');frame.id='budget-frame';
          frame.onload=()=>resolve(true);frame.src='/context-frame';
          document.body.append(frame);
        })''', await_result=True)
        scoped = snapshot('shadow-and-frame', False)
        assert next(element for element in scoped['elements'] if element['name'] == 'Shadow budget button')['context'][0]['kind'] == 'shadow'
        assert next(element for element in scoped['elements'] if element['name'] == 'Frame button')['context'][0]['kind'] == 'frame'

        evaluate('''(()=>{
          document.body.innerHTML='<label for="contents-input" style="display:contents">Word<span>join</span> label</label><input id="contents-input"><button>Inline<span>word</span></button><span id="hidden-label" hidden>Hidden accessible label</span><input aria-labelledby="hidden-label">';
          return true;
        })()''')
        text_names = snapshot('bounded-name-semantics', False)
        assert any(element['name'] == 'Wordjoin label' for element in text_names['elements']), text_names
        assert any(element['name'] == 'Inlineword' for element in text_names['elements']), text_names
        assert any(element['name'] == 'Hidden accessible label' for element in text_names['elements']), text_names

        evaluate('''(()=>{
          document.body.replaceChildren();
          const text=document.createElement('p');text.textContent='x'.repeat(19999)+'🙂tail';
          const input=document.createElement('input');input.value='v'.repeat(199)+'🙂tail';
          input.setAttribute('aria-label','n'.repeat(199)+'🙂tail');
          const select=document.createElement('select'), option=document.createElement('option');
          option.value='o'.repeat(199)+'🙂tail';option.label='l'.repeat(199)+'🙂tail';
          select.append(option);document.body.append(input,select,text);return true;
        })()''')
        unicode_snapshot = snapshot('emoji-at-truncation-boundary', True)
        unicode_input = next(element for element in unicode_snapshot['elements'] if element['tag'] == 'input')
        assert unicode_input['name'] == 'n' * 199 and unicode_input['value'] == 'v' * 199, unicode_input
        unicode_option = next(element for element in unicode_snapshot['elements'] if element['tag'] == 'select')['options'][0]
        assert unicode_option['value'] == 'o' * 199 and unicode_option['label'] == 'l' * 199, unicode_option
        assert unicode_snapshot['text'] == 'x' * 19999, unicode_snapshot['text'][-20:]

        evaluate('''(()=>{
          document.body.replaceChildren();
          const select=document.createElement('select');select.id='large-select';
          for(let i=0;i<3000;i++) {
            const option=document.createElement('option');
            option.value=String(i)+'v'.repeat(4096);option.textContent='选项🙂'.repeat(512);
            select.append(option);
          }
          document.body.append(select);return true;
        })()''')
        large_select = snapshot('large-select', True)
        assert len(next(element for element in large_select['elements'] if element['tag'] == 'select')['options']) == 100
        evaluate('''(()=>{
          const select=document.querySelector('#large-select');select.replaceChildren();
          const option=document.createElement('option');option.textContent='implicit value '.repeat(100000);
          select.append(option);return true;
        })()''')
        implicit = snapshot('large-option-without-value', True)
        option = next(element for element in implicit['elements'] if element['tag'] == 'select')['options'][0]
        assert option['value'] == option['label'] and option['value']

        evaluate('''(()=>{
          document.body.replaceChildren();
          const label=document.createElement('label');label.id='huge-label';label.htmlFor='labelled-input';
          label.textContent='Large label text '.repeat(100000);
          const input=document.createElement('input');input.id='labelled-input';input.setAttribute('aria-labelledby','huge-label '.repeat(10000));
          document.body.append(input,label);return true;
        })()''')
        large_text = snapshot('large-text-and-labels', True)
        assert next(element for element in large_text['elements'] if element['tag'] == 'input')['name']

        evaluate('''(()=>{
          document.body.replaceChildren();
          const first=document.createElement('button');first.textContent='Partial result preserved';document.body.append(first);
          const fragment=document.createDocumentFragment();
          for(let i=0;i<15000;i++) fragment.append(document.createElement('div'));
          document.body.append(fragment);return true;
        })()''')
        many_nodes = snapshot('many-nodes', True)
        assert any(element['name'] == 'Partial result preserved' for element in many_nodes['elements'])

        evaluate('''(()=>{
          document.body.replaceChildren();
          const fragment=document.createDocumentFragment();
          for(let i=0;i<80;i++) {
            const select=document.createElement('select');select.setAttribute('aria-label','Budget '+i);
            for(let j=0;j<100;j++) {
              const option=document.createElement('option');
              option.value='汉'.repeat(200);option.label='汉'.repeat(200);select.append(option);
            }
            fragment.append(select);
          }
          document.body.append(fragment);return true;
        })()''')
        budget = snapshot('global-output-budget', True)
        assert 0 < len(budget['elements']) < 80
    finally:
        original_failure = sys.exc_info()[0] is not None
        cleanup_errors = []
        for name in created:
            try:
                assert cli('space', 'delete', name)['websiteDataRemoved']
            except Exception as error:
                cleanup_errors.append(f'{name}: {error}')
        if cleanup_errors:
            (out / 'snapshot-budget-cleanup-errors.json').write_text(json.dumps(cleanup_errors, indent=2))
            if not original_failure:
                raise AssertionError(f'Snapshot budget cleanup failed: {cleanup_errors}')
    report = dict(passed=True, cases=cases, otherSpaceRemainsUsable=True)
    (out / 'snapshot-budget.json').write_text(json.dumps(report, indent=2))
    return report
