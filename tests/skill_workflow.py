"""Opt-in real Codex CLI integration; never installs skills or changes agent settings."""
import json
import errno
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

from fixtures import origin

ROOT = Path(__file__).resolve().parents[1]


def verify_agent_trace(path):
    responses = []
    for line in path.read_text().splitlines():
        event = json.loads(line)
        item = event.get('item', {})
        if event.get('type') != 'item.completed' or item.get('type') != 'command_execution':
            continue
        for output in item.get('aggregated_output', '').splitlines():
            try:
                response = json.loads(output)
            except json.JSONDecodeError:
                continue
            if isinstance(response, dict) and isinstance(response.get('ok'), bool):
                responses.append(response)
    errors = [response.get('error', {}).get('code') for response in responses if not response['ok']]
    assert 'stale_ref' in errors and 'timeout' in errors, errors
    deadline = next(i for i, response in enumerate(responses) if response.get('error', {}).get('code') == 'timeout')
    assert any(isinstance(response.get('result'), dict) and response['result'].get('page')
               for response in responses[deadline + 1:]), 'No page observation after timeout'
    return errors


def verify_cleanup(state):
    assert json.loads((state / 'spaces.json').read_text()) == []
    # AppKit termination may leave a stale path; test the service, not path existence.
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(2)
        try:
            client.connect(str(state / 'browser.sock'))
        except OSError as error:
            assert error.errno in (errno.ENOENT, errno.ECONNREFUSED), error
        else:
            raise AssertionError('Test daemon still accepts connections')


def cleanup_test_services(cli, daemon, site):
    errors = []
    try:
        if daemon is not None and daemon.poll() is None:
            try:
                spaces = cli('space', 'list')
            except Exception as error:
                errors.append(error)
                spaces = []
            for space in spaces:
                try:
                    cli('space', 'delete', space['id'])
                except Exception as error:
                    errors.append(error)
            try:
                cli('shutdown', '--all')
                daemon.wait(timeout=15)
            except Exception as error:
                errors.append(error)
    finally:
        try:
            if daemon is not None and daemon.poll() is None:
                daemon.terminate()
                try:
                    daemon.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait(timeout=10)
        except Exception as error:
            errors.append(error)
        finally:
            for close in (site.shutdown, site.server_close):
                try:
                    close()
                except Exception as error:
                    errors.append(error)
    return errors


def finish_test_services(cli, daemon, site, out):
    # Keep the test failure primary; cleanup errors must still prevent a success report.
    failed = sys.exc_info()[0] is not None
    errors = cleanup_test_services(cli, daemon, site)
    if errors:
        (out / 'cleanup-errors.json').write_text(json.dumps([
            dict(type=type(error).__name__, message=str(error)) for error in errors], indent=2))
        if not failed:
            raise RuntimeError(f'Test cleanup failed; see {out / "cleanup-errors.json"}') from errors[0]


def main():
    out = ROOT / '.artifacts' / time.strftime('skill-codex-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    state = Path(tempfile.mkdtemp(prefix='aw-skill-'))
    env = dict(os.environ, BROWSER_DATA_DIR=str(state), BROWSER_SOCKET=str(state / 'browser.sock'))
    binary = ROOT / '.build/debug/awb'
    app = ROOT / '.build/Agent WebKit.app/Contents/MacOS/awb'
    site, _ = origin()
    url = f'http://127.0.0.1:{site.server_address[1]}/index.html'

    def cli(*args):
        process = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=20)
        response = json.loads(process.stdout)
        with (out / 'host-commands.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(args=args, response=response)) + '\n')
        assert process.returncode == 0 and response['ok'], response
        return response['result']

    with (out / 'daemon.log').open('w') as log:
        daemon = None
        try:
            daemon = subprocess.Popen([str(app), 'daemon'], env=env, stdout=log, stderr=log)
            for _ in range(100):
                assert daemon.poll() is None, 'Test daemon exited'
                if (state / 'browser.sock').exists() and cli('status')['ready']:
                    break
                time.sleep(.1)
            else:
                raise AssertionError('Startup timed out')
            work = cli('space', 'create', 'skill-work', '--proxy', 'direct')
            peer = cli('space', 'create', 'skill-peer', '--proxy', 'direct')
            cli('open', url, '--space', peer['id'])
            target = cli('tab', 'new', url, '--space', work['id'])['tabId']
            flags = ('--space', work['id'], '--tab', target)
            old = next(el['ref'] for el in cli('snapshot', *flags)['value']['elements'] if el['tag'] == 'button')
            cli('evaluate', '''const button=document.querySelector('#save'); button.replaceWith(button.cloneNode(true));
                window.fixtureSaves=0; document.querySelector('#save').onclick=()=>{
                window.fixtureSaves++; document.querySelector('#result').textContent=document.querySelector('#message').value}; true''', *flags)
            before = cli('status')
            prompt = f'''读取并使用 {ROOT / 'skills/agent-webkit/SKILL.md'}，在已授权的独立测试页面完成以下任务。
CLI 为 {binary}，每条调用显式传 --socket {state / 'browser.sock'}；不要连接其他服务。
目标 Space={work['id']}，Tab={target}（不是默认 Tab）。页面 URL={url}。
此前保存按钮的引用是 {old}；先用它点击一次，然后根据实际返回继续处理。
把 Message 填为 P1-skill，并使该值保存成功一次。之后等待 #server-ack，期限150毫秒（此测试页不会出现这个标记），按实际结果结束并报告。
仅允许本目标的 CLI 查询与页面操作。不要创建/关闭/删除 Space/Tab，不要 shutdown 或启动 daemon，不改系统设置、源码、Agent 配置，不写额外脚本或客户端。'''
            (out / 'prompt.txt').write_text(prompt)
            # Explicit path invocation exercises the actual agent without installing the skill.
            command = ['codex', '--no-daemon', '-a', 'never', '-c', 'sandbox_workspace_write.network_access=true',
                       'exec', '--ephemeral', '--json', '--sandbox', 'workspace-write',
                       '--skip-git-repo-check', '--cd', str(state), '-o', str(out / 'answer.txt'), prompt]
            with (out / 'agent-events.jsonl').open('w') as events, (out / 'agent-stderr.log').open('w') as errors:
                process = subprocess.run(command, env=env, stdout=events, stderr=errors, timeout=240)
            assert process.returncode == 0, f'Codex failed; see {out}'
            errors = verify_agent_trace(out / 'agent-events.jsonl')
            outcome = cli('evaluate', '({saves:window.fixtureSaves,result:document.querySelector("#result").textContent})', *flags)['value']
            assert outcome == dict(saves=1, result='P1-skill'), outcome
            assert cli('evaluate', 'document.querySelector("#result").textContent', '--space', peer['id'])['value'] == 'Ready'
            assert cli('space', 'info', work['id'])['defaultTabId'] == work['defaultTabId']
            after = cli('status')
            assert after['observer'] == before['observer']
            assert after['frontmostPid'] == before['frontmostPid']
            report = dict(ok=True, agent='codex', invocation='explicit SKILL.md path; ephemeral; no installation',
                          outcome=outcome, targetTab=target, defaultTab=work['defaultTabId'],
                          observedErrors=errors,
                          peerUnchanged=True, observerUnchanged=True, foregroundUnchanged=True,
                          artifacts=str(out))
        finally:
            finish_test_services(cli, daemon, site, out)
    verify_cleanup(state)
    report['cleanupVerified'] = True
    (out / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report))


if __name__ == '__main__':
    main()
