#!/usr/bin/env python3
"""Run the real Google demo, measuring each separate CLI process with a monotonic clock."""
import argparse
import json
from pathlib import Path
import platform
import subprocess
import time
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--awb', '--browser', dest='awb', default=str(ROOT / '.build/debug/awb'))
    parser.add_argument('--space', default='google-demo')
    parser.add_argument('--socket', help='Connect to an already running app; otherwise use CLI defaults')
    parser.add_argument('--out', default=str(ROOT / '.artifacts' / time.strftime('google-timing-%Y%m%d-%H%M%S')))
    args = parser.parse_args()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    steps = []
    report = {
        'ok': False, 'space': args.space, 'out': str(out), 'steps': steps,
        'startedAt': time.strftime('%Y-%m-%dT%H:%M:%S%z'), 'macOS': platform.mac_ver()[0],
        'clock': 'monotonic; Python perf_counter_ns and Swift DispatchTime.uptimeNanoseconds',
        'definitions': {
            'cliEndToEndMs': 'Parent starts CLI process through collecting stdout/stderr and process exit; excludes Python JSON parsing and artifact writes.',
            'cliMs': 'Swift main entry through response parsing, before final JSON encoding/stdout; excludes process loading and exit.',
            'ipcRoundTripMs': 'CLI request serialization/connect/write through reading the full response.',
            'serverMs': 'MainActor handler entry through command completion/error; excludes main queue entry and response serialization/write.',
            'webkitMs': 'Union of host-observed WebKit API/navigation intervals within this request, not CPU time. Navigation ends at didFinish/didFail; screenshot ends at takeSnapshot callback, before PNG encoding/write.',
            'webkitOperations': 'Individual API spans can overlap (navigation/readiness JS); their totals must not be added to compute webkitMs. inProgress marks a span still running when the response was generated.',
        },
        'cachePolicy': 'open reloads ignoring local cache; persistent Google cookies and later link navigation retain normal WebKit behavior; this is one sample, not a cold-start benchmark.',
    }

    def save():
        (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')

    def run(label, *command, phase='demo', allow_error=False):
        number = len(steps) + 1
        argv = [args.awb, *command]
        if args.socket:
            argv += ['--socket', args.socket]
        start = time.perf_counter_ns()
        try:
            process = subprocess.run(argv, capture_output=True, text=True, timeout=80)
        except subprocess.TimeoutExpired as error:
            step = {'step': number, 'label': label, 'phase': phase, 'args': argv[1:],
                    'cliEndToEndMs': (time.perf_counter_ns() - start) / 1_000_000,
                    'ok': False, 'error': str(error)}
            steps.append(step); save(); raise
        elapsed = (time.perf_counter_ns() - start) / 1_000_000
        step = {'step': number, 'label': label, 'phase': phase, 'args': argv[1:],
                'cliEndToEndMs': elapsed, 'exitCode': process.returncode}
        steps.append(step)
        (out / f'{number:02}-{label}.json').write_text(process.stdout)
        if process.stderr:
            (out / f'{number:02}-{label}.stderr').write_text(process.stderr)
        try:
            response = json.loads(process.stdout)
            step['ok'] = response.get('ok') is True and process.returncode == 0
            step['timing'] = response.get('timing', {})
            if 'serverMs' not in step['timing']:
                raise RuntimeError('服务端未返回计时；请构建并重启原生应用。')
            if response.get('result', {}).get('page'):
                step['page'] = response['result']['page']
            if not step['ok']:
                step['error'] = response.get('error', {})
                if not allow_error:
                    raise RuntimeError(f'{label}: {step["error"]}')
            return response
        finally:
            save()
            timing = step.get('timing', {})
            def measured(key):
                return f'{timing[key]:9.2f}' if key in timing else '      n/a'
            print(f'{number:2} {label:24} CLI {elapsed:9.2f} ms | '
                  f'IPC {measured("ipcRoundTripMs")} | '
                  f'server {measured("serverMs")} | '
                  f'WebKit {measured("webkitMs")}', flush=True)

    def page(label, *command):
        return run(label, *command, '--space', args.space)['result']

    def element(snapshot, predicate, description):
        candidates = [e for e in snapshot['elements'] if not e['disabled'] and predicate(e)]
        if not candidates:
            raise RuntimeError(f'未找到{description}；检查本步结构与截图。若遇到 CAPTCHA，需要用户处理，脚本不会绕过。')
        return candidates[0]['ref']

    try:
        run('status', 'status', phase='setup')
        existing = run('space-info', 'space', 'info', args.space, phase='setup', allow_error=True)
        if not existing['ok']:
            if existing['error']['code'] != 'space_not_found':
                raise RuntimeError(existing['error'])
            space = run('space-create', 'space', 'create', args.space, '--proxy', 'direct', phase='setup')['result']
        else:
            space = existing['result']
        if space['proxy'] != 'direct' or space['tls']['policy'] != 'system':
            raise RuntimeError('演示 Space 必须使用 direct 和系统证书校验；请指定另一个 --space 名称。')
        page('open-google', 'open', 'https://www.google.com/?hl=zh-CN', '--timeout', '30000')
        home = page('home-structure', 'snapshot')['value']
        page('home-screenshot', 'screenshot', '--out', str(out / 'home.png'))
        search = element(home, lambda e: e['tag'] in ('input', 'textarea') and
                         (e['name'] == 'q' or any(s in e['name'].lower() for s in ('google', 'search', '搜索'))), 'Google 搜索框')
        submit = element(home, lambda e: e['tag'] in ('input', 'button') and
                         (e['name'] == 'btnK' or e['value'] in ('Google 搜索', 'Google Search') or
                          e['name'] in ('Google 搜索', 'Google Search')), 'Google 搜索按钮')
        page('fill-search', 'fill', search, 'WebKit')
        result = page('click-search-and-load', 'click', submit, '--wait-for-navigation', '--timeout', '30000')
        if urlparse(result['page']['url']).path != '/search':
            raise RuntimeError('点击后未进入 Google 搜索结果页。')
        results = page('search-structure', 'snapshot')['value']
        page('search-screenshot', 'screenshot', '--out', str(out / 'search.png'))
        scroll = page('scroll-650px', 'evaluate', '(() => { const before = scrollY; window.scrollBy(0, 650); return {before, after:scrollY, viewport:innerHeight, pageHeight:document.documentElement.scrollHeight}; })()')['value']
        report['scroll'] = scroll
        if scroll['after'] <= scroll['before']:
            raise RuntimeError(f'页面没有实际向下滚动：{scroll}')
        page('scrolled-screenshot', 'screenshot', '--out', str(out / 'scrolled.png'))
        target = element(results, lambda e: e['tag'] == 'a' and 'Apple Developer Documentation' in e['name'], 'Apple WebKit 文档搜索结果')
        destination = page('click-result-and-load', 'click', target, '--wait-for-navigation', '--timeout', '30000')
        if urlparse(destination['page']['url']).hostname != 'developer.apple.com':
            raise RuntimeError(f'未到达 Apple 文档页面：{destination["page"]}')
        document = page('destination-structure', 'snapshot')['value']
        page('destination-screenshot', 'screenshot', '--out', str(out / 'destination.png'))
        report['elementCounts'] = {'home': len(home['elements']), 'search': len(results['elements']), 'destination': len(document['elements'])}
        report['ok'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        save()
        print(f'Report: {out / "report.json"}', flush=True)


if __name__ == '__main__':
    main()
