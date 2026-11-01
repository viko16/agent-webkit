"""Offline discovery and live CLI/IPC contract compatibility; standard library only."""
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def verify_offline(cli):
    usage = cli('--help')['usage']
    assert usage.startswith('awb help ') and 'reload' in usage
    version = cli('version')['version']
    assert re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version), version
    assert cli('--version')['version'] == version
    contract = cli('capabilities')
    assert contract['schemaVersion'] == 1
    assert contract['version'] == version
    commands = {item['command']: item for item in contract['commands']}
    assert len(commands) == len(contract['commands'])
    definitions = contract['schemas']['$defs']
    for name, command in commands.items():
        assert command['resultSchema'] in definitions
        assert cli('help', *name.split('.'))['commands'] == [command]
        assert command['args']['maximum'] == len(command['args']['names'])
    for group in ('space', 'tab', 'dialog', 'frame'):
        assert {item['command'] for item in cli('help', group)['commands']} == {
            name for name in commands if name.startswith(group + '.')}
    timeout = next(option for option in commands['open']['options'] if option['name'] == 'timeout')
    assert (timeout['minimum'], timeout['maximum'], timeout['default'], timeout['unit']) == (1, 60000, 15000, 'ms')
    for command in commands.values():
        for option in command['options']:
            if option['name'] in ('socket', 'data-dir'):
                assert option['availability'] == ['cli'] and 'ipcType' not in option
            else:
                assert option['ipcType'] == 'string' and 'ipc' in option['availability']
    detail = next(option for option in commands['diagnostics']['options'] if option['name'] == 'detail')
    assert detail['enum'] == ['on', 'off'] and not detail['required']
    inspectable = next(option for option in commands['diagnostics']['options'] if option['name'] == 'inspectable')
    assert inspectable['enum'] == ['on', 'off'] and not inspectable['required']
    assert contract['constraints']['dialog.respond']['actions'] == ['accept', 'dismiss']
    assert {'space', 'tab', 'text'} <= {option['name'] for option in commands['dialog.respond']['options']}
    assert set(contract['exitCodes']) == {'0', '1'}
    shutdown_flag = next(option for option in commands['shutdown']['options'] if option['name'] == 'all')
    assert shutdown_flag['required'] and shutdown_flag['type'] == 'flag' and shutdown_flag['ipcValue'] == 'true'
    assert commands['shutdown']['usage'] == 'awb shutdown --all'
    assert next(option for option in commands['screenshot']['options'] if option['name'] == 'element')['type'] == 'string'
    assert next(option for option in commands['screenshot']['options'] if option['name'] == 'full-page')['type'] == 'flag'
    assert contract['constraints']['screenshot']['mutuallyExclusive'] == [['element', 'full-page']]
    assert contract['constraints']['frame']['requires'] == ['tab']
    assert 'frame.list' in commands and 'stale_frame' in contract['errors']
    assert {'stale_ref', 'timeout', 'space_busy', 'tab_not_found', 'operation_failed'} <= set(contract['errors'])
    for args in [('help', 'missing'), ('help', 'space', 'missing'), ('help', 'open', 'extra'),
                 ('capabilities', 'extra'), ('capabilities', '--space', 'work'), ('help', '--tab', 'id'),
                 ('shutdown',), ('shutdown', '--all', '--all'), ('status', '--all'), ('shutdown', '--all', '--space', 'work')]:
        cli(*args, error='invalid_arguments')
    return contract


def verify_live_contract(cli, socket_path):
    def raw(command, args=None, options=None):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(5)
            client.connect(str(socket_path))
            client.sendall(json.dumps(dict(command=command, args=args or [], options=options or {})).encode() + b'\n')
            return json.loads(client.makefile('rb').readline())

    before = cli('status')
    spaces = cli('space', 'list')
    contract = cli('capabilities')
    assert raw('capabilities')['result'] == contract
    assert raw('help', ['space', 'create'])['result'] == cli('help', 'space', 'create')
    assert raw('help', ['missing'])['error']['code'] == 'invalid_arguments'
    assert raw('capabilities', options={'tab': 'wrong'})['error']['code'] == 'invalid_arguments'
    for key in ('data-dir', 'socket'):
        assert raw('status', options={key: '/tmp/other-daemon'})['error']['code'] == 'invalid_arguments'
        assert raw('space.delete', ['work'], {key: '/tmp/other-daemon'})['error']['code'] == 'invalid_arguments'
    assert cli('status', '--data-dir', str(socket_path.parent), '--socket', str(socket_path))['pid'] == before['pid']
    assert cli('space', 'list') == spaces
    assert raw('wait', options={'space': 'work', 'url': 'x', 'text': 'y'})['error']['code'] == 'invalid_arguments'
    assert raw('diagnostics', options={'space': 'work', 'inspectable': 'yes'})['error']['code'] == 'invalid_arguments'
    assert raw('diagnostics', options={'space': 'work', 'detail': 'on', 'inspectable': 'on'})['error']['code'] == 'invalid_arguments'
    assert raw('dialog.respond', ['unknown', 'yes'], {'space': 'work'})['error']['code'] == 'invalid_arguments'
    assert raw('dialog.list', options={'space': 'work', 'text': 'wrong'})['error']['code'] == 'invalid_arguments'
    assert raw('snapshot', options={'space': 'work', 'element': '#message'})['error']['code'] == 'invalid_arguments'
    assert raw('snapshot', options={'space': 'work', 'frame': 'unknown'})['error']['code'] == 'invalid_arguments'
    assert raw('snapshot', options={'space': 'work', 'tab': spaces[0]['defaultTabId'], 'frame': ''})['error']['code'] == 'invalid_arguments'
    assert raw('evaluate', ['true'], {'space': 'work', 'tab': spaces[0]['defaultTabId'], 'frame': 'unknown'})['error']['code'] == 'invalid_arguments'
    assert raw('screenshot', options={'space': 'work', 'full-page': 'false', 'out': '/tmp/unused.png'})['error']['code'] == 'invalid_arguments'
    assert raw('screenshot', options={'space': 'work', 'full-page': 'true', 'element': '#message', 'out': '/tmp/unused.png'})['error']['code'] == 'invalid_arguments'
    for options in ({}, {'all': 'false'}, {'all': 'yes'}, {'all': 'true', 'tab': 'wrong'}):
        assert raw('shutdown', options=options)['error']['code'] == 'invalid_arguments'
    cli('shutdown', error='invalid_arguments')
    impact = before['shutdownImpact']
    assert impact == dict(spaces=[dict(spaceId=space['id'], name=space['name'],
                                     tabIds=[tab['tabId'] for tab in space['tabs']]) for space in spaces],
                          websiteDataPreserved=True, pageMemoryPreserved=False), impact
    definitions = contract['schemas']['$defs']
    # Validate schemas against actual host results, rather than only self-consistent metadata.
    for name, result in [('status', before), ('space', cli('space', 'info', 'work')),
                         ('tab', cli('tab', 'list', '--space', 'work')[0]),
                         ('page', cli('snapshot', '--space', 'work')),
                         ('diagnostics', cli('diagnostics', '--space', 'work'))]:
        assert set(definitions[name]['required']) <= result.keys(), (name, result)
    cli('fill', '--space', 'work', '--', '#message', '--help')
    assert cli('evaluate', 'document.querySelector("#message").value', '--space', 'work')['value'] == '--help'
    after = cli('status')
    assert after['observer'] == before['observer']
    assert after['frontmostPid'] == before['frontmostPid']
    assert cli('space', 'list') == spaces
    return 'offline help/capabilities; CLI/IPC parity; actual result schemas; literal --help; fixed targets and observer unchanged'


def main():
    with tempfile.TemporaryDirectory(prefix='aw-contract-') as directory:
        data = Path(directory) / 'unused'
        env = dict(os.environ, BROWSER_DATA_DIR=str(data), BROWSER_SOCKET=str(data / 'missing.sock'))

        def cli(*args, error=None):
            process = subprocess.run([str(ROOT / '.build/debug/awb'), *args], env=env,
                                     capture_output=True, text=True, timeout=10)
            response = json.loads(process.stdout)
            assert process.returncode == (1 if error else 0), (args, response, process.stderr)
            assert response['ok'] == (error is None), (args, response)
            assert 'ipcRoundTripMs' not in response.get('timing', {}), response
            if error:
                assert response['error']['code'] == error, response
                return response
            return response['result']

        contract = verify_offline(cli)
        assert not data.exists(), 'Offline discovery must not create a registry or start a daemon'
        print(json.dumps(dict(ok=True, offline=True, commands=len(contract['commands']), schemaVersion=contract['schemaVersion'])))


if __name__ == '__main__':
    main()
