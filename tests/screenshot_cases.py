"""Verify real PNG pixels and scroll restoration, independently of returned geometry."""
import json
from pathlib import Path
import subprocess
from urllib.parse import urljoin

ROOT = Path(__file__).resolve().parents[1]


def image_pixels(path, *points):
    probe = ROOT / '.build/image-probe'
    source = ROOT / 'tests/image_probe.swift'
    if not probe.exists() or probe.stat().st_mtime < source.stat().st_mtime:
        subprocess.run(['swiftc', str(source), '-o', str(probe)], check=True, capture_output=True)
    result = subprocess.run([str(probe), str(path), *points], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def verify_screenshots(cli, base, out, restart):
    name, peer = 'screen-work', 'screen-peer'
    work = cli('space', 'create', name, '--proxy', 'direct')
    cli('space', 'create', peer, '--proxy', 'direct')
    target = cli('tab', 'new', urljoin(base, '/screenshots'), '--space', name)['tabId']
    flags = ('--space', name, '--tab', target)
    def command(*args, **kwargs):
        return cli(*args, *flags, **kwargs)
    def scrolls():
        return command('evaluate', '({x:scrollX,y:scrollY,inner:document.querySelector("#frame").contentWindow.scrollY,container:document.querySelector("#scroller").scrollTop,left:document.querySelector("#scroller").scrollLeft})')['value']
    def capture(selector, filename, color):
        before = scrolls()
        path = out / filename
        result = command('screenshot', '--element', selector, '--out', str(path))['value']
        assert result['mode'] == 'element' and result['scrollRestored']
        pixels = image_pixels(path, '0.5,0.5', '0.1,0.1')
        assert pixels['width'] == result['width'] and pixels['height'] == result['height']
        for pixel in pixels['samples']:
            assert all(abs(a-b) <= 4 for a,b in zip(pixel, [*color,255])), (filename, pixel, color)
        assert scrolls() == before, (before, scrolls())
        return result
    try:
        command('wait', '#frame >>> #inner')
        command('evaluate', 'scrollTo(0,170);document.querySelector("#frame").contentWindow.scrollTo(0,35);document.querySelector("#scroller").scrollTop=11;document.querySelector("#scroller").scrollLeft=17;true')
        before = cli('status')
        snap = command('snapshot')['value']
        ref = next(e['ref'] for e in snap['elements'] if e['name'] == 'Red target')
        red = capture(ref, 'element-red.png', [220,30,40])
        assert red['range']['width'] == 180 and red['range']['height'] == 100
        clipped = capture('#wide', 'element-clipped.png', [20,160,70])
        assert clipped['range']['clipped'] and clipped['range']['width'] <= 132 and clipped['range']['height'] <= 72
        frame = capture('#frame >>> #inner', 'element-frame.png', [200,100,20])
        assert frame['range']['width'] == 130 and frame['range']['height'] == 70
        capture('#shadow >>> button', 'element-shadow.png', [30,60,220])
        for selector, error in [('#hidden','element_not_actionable'),('#zero','element_not_actionable'),('#missing','selector_count'),('button','selector_count'),('[','invalid_selector')]:
            command('screenshot', '--element', selector, '--out', str(out / 'rejected.png'), error=error)
        assert not (out / 'rejected.png').exists()
        command('evaluate', 'document.querySelector("#frame").style.transform="scale(0.8)";true')
        original = scrolls()
        command('screenshot', '--element', '#frame >>> #inner', '--out', str(out / 'rejected.png'), error='unsupported_screenshot_geometry')
        assert scrolls() == original
        command('evaluate', 'document.querySelector("#frame").style.transform="none";true')
        command('evaluate', 'const box=document.querySelector("#scroller"),wrapper=document.createElement("div");wrapper.id="scaled-wrapper";wrapper.style.transform="scale(.5)";box.replaceWith(wrapper);wrapper.append(box);true')
        original = scrolls()
        command('screenshot', '--element', '#wide', '--out', str(out / 'rejected.png'), error='unsupported_screenshot_geometry')
        assert scrolls() == original
        command('evaluate', 'document.querySelector("#scaled-wrapper").style.transform="none";true')
        command('screenshot', '--element', '#target', '--out', str(out / 'missing-folder/image.png'), error='operation_failed')
        assert scrolls() == original
        command('screenshot', '--element', '#target', '--out', str(out / 'rejected.png'), '--timeout', '25', error='timeout')
        assert scrolls() == original
        cli('screenshot', '--space', peer, '--tab', target, '--element', '#target', '--out', str(out / 'rejected.png'), error='tab_not_found')
        assert cli('space', 'info', name)['defaultTabId'] == work['defaultTabId']
        assert cli('status')['frontmostPid'] == before['frontmostPid']
        viewport = command('screenshot', '--out', str(out / 'viewport.png'))['value']
        assert viewport['mode'] == 'viewport'
        restart()
        command('wait', '#target')
        command('screenshot', '--element', ref, '--out', str(out / 'rejected.png'), error='stale_ref')
        capture('#target', 'element-restarted.png', [220,30,40])
        report = dict(elementScreenshots=True, pixelsVerified=True, scrollRestored=True,
                      clipping=True, sameOriginFrame=True, openShadow=True, errors=True,
                      nondefaultTab=True, restart=True, foregroundUnchanged=True)
        (out / 'screenshots.json').write_text(json.dumps(report, indent=2))
        return report
    finally:
        cli('space', 'delete', name)
        cli('space', 'delete', peer)
