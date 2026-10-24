"""Verify fetch and WSS using real Whistle sessions plus the local origin's evidence."""
import json


def verify_network_cases(cli, whistle, site, events):
    nonce = site.fixture_nonce
    resource = f'https://example.com/resource?network_probe={nonce}'
    websocket = f'wss://example.com/echo?network_probe={nonce}'

    def evaluate(space, script):
        return cli('evaluate', script, '--space', space, '--await', '--timeout', '5000')['value']

    result = evaluate('admin', f'fetch({json.dumps(resource)}).then(r=>r.json())')
    assert result['nonce'] == nonce, result
    ws_script = """new Promise(resolve=>{
        const ws=new WebSocket(URL);
        const timer=setTimeout(()=>{ws.close();resolve({timeout:true})},2000);
        ws.onopen=()=>ws.send('probe');
        ws.onmessage=e=>{clearTimeout(timer);resolve({message:e.data});ws.close()};
        ws.onerror=()=>{clearTimeout(timer);resolve({error:true})};
    })""".replace('URL', json.dumps(websocket))
    proxied_ws = evaluate('admin', ws_script)
    assert proxied_ws == {'message': nonce + ':probe'}, proxied_ws

    def sessions():
        return [s for s in whistle.sessions() if 'network_probe=' + nonce in s.get('url', '')]

    before = sessions()
    assert any('/resource?' in s['url'] for s in before), before
    assert any('/echo?' in s['url'] for s in before), before
    before_hits = [e for e in events.items if 'network_probe=' + nonce in e['path']]
    assert any(e['kind'] == 'websocket' for e in before_hits), before_hits
    direct = evaluate('user', f'fetch({json.dumps(resource)}).then(r=>r.text())')
    assert nonce not in direct, direct
    direct_ws = evaluate('user', ws_script)
    assert direct_ws.get('message') != nonce + ':probe', direct_ws
    assert {s['id'] for s in sessions()} == {s['id'] for s in before}, 'direct added Whistle sessions'
    assert [e for e in events.items if 'network_probe=' + nonce in e['path']] == before_hits, 'direct reached local origin'
    return {'passed': True, 'fetchNonce': result['nonce'], 'webSocketReply': proxied_ws,
            'directWebSocket': direct_ws, 'whistleSessionIds': [s['id'] for s in before],
            'directAddedWhistleSessions': 0, 'originEvidence': before_hits}
