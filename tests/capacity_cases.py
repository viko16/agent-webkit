"""Real creation, popup and suspended-restoration capacity boundaries."""
import json
import os
from urllib.parse import urljoin


def verify_capacity(cli, base, out, start, stop, state):
    names = ('capacity-work', 'capacity-peer', 'capacity-sleep')
    environment = dict(BROWSER_MAX_SPACES='3', BROWSER_MAX_TABS_PER_SPACE='3',
                       BROWSER_MAX_TOTAL_TABS='6', BROWSER_MAX_LIVE_WEBVIEWS='4',
                       BROWSER_MAX_POPUPS_PER_SPACE='1')
    stop(); start(extra_env=environment)
    try:
        for name in names:
            cli('space', 'create', name, '--proxy', 'direct')
        cli('space', 'create', 'capacity-excess', '--proxy', 'direct', error='resource_limit')
        first = cli('tab', 'new', '--space', names[0])['tabId']
        cli('tab', 'new', '--space', names[1], error='resource_limit')
        cli('space', 'suspend', names[2])
        second = cli('tab', 'new', '--space', names[0])['tabId']
        cli('tab', 'new', '--space', names[0], error='resource_limit')
        cli('space', 'suspend', names[0])
        cli('space', 'resume', names[2])
        cli('space', 'resume', names[0], error='resource_limit')
        assert cli('space', 'info', names[0])['liveWebViews'] == 0
        cli('tab', 'close', second, '--space', names[0])
        cli('space', 'resume', names[0])
        cli('space', 'suspend', names[2])
        cli('tab', 'close', first, '--space', names[0])
        cli('open', urljoin(base, '/popups'), '--space', names[0])
        popup = cli('click', '#blank', '--wait-for-popup', '--space', names[0])['value']['newTabId']
        cli('wait', '--space', names[0], '--tab', popup)
        cli('click', '#blank', '--wait-for-popup', '--timeout', '500', '--space', names[0], error='resource_limit')
        assert len(cli('tab', 'list', '--space', names[0])) == 2
        cli('space', 'suspend', names[0])
        cli('space', 'resume', names[0])
        cli('wait', '--space', names[0])
        cli('click', '#blank', '--wait-for-popup', '--timeout', '500', '--space', names[0], error='resource_limit')
        stop(); start(extra_env=environment)
        cli('wait', '--space', names[0])
        cli('click', '#blank', '--wait-for-popup', '--timeout', '500', '--space', names[0], error='resource_limit')
        cli('open', base, '--space', names[1])
        assert cli('evaluate', 'document.title', '--space', names[1])['value']
        before = {space['id']: [tab['tabId'] for tab in space['tabs']] for space in cli('space', 'list')}
        stop(); start(extra_env=dict(environment, BROWSER_MAX_LIVE_WEBVIEWS='1'))
        assert cli('status')['liveWebViews'] <= 1
        after = {space['id']: [tab['tabId'] for tab in space['tabs']] for space in cli('space', 'list')}
        assert before == after
        blocked = cli('space', 'info', names[0])
        assert blocked['lifecycle'] == 'suspended' and blocked['resourceBlockedReason']
        cli('space', 'resume', names[0], error='resource_limit')
        # Lowering the total budget rejects additions, preserving existing metadata.
        stop(); start(extra_env=dict(environment, BROWSER_MAX_TOTAL_TABS='4'))
        cli('tab', 'new', '--space', names[1], error='resource_limit')
        report = dict(passed=True, spacesAndTabsBounded=True, activeViewsBounded=True,
                      popupsBounded=True, popupQuotaSurvivesSuspendAndRestart=True, suspendedResumeBounded=True,
                      restorePreservesMetadataWithinViewBudget=True, totalTabsBounded=True)
    finally:
        for space in cli('space', 'list'):
            if space['name'] in names:
                cli('space', 'delete', space['id'])
        stop(); start()
    report['loweredPopupQuota'] = verify_lowered_popup_quota(cli, base, start, stop, state)
    (out / 'capacity.json').write_text(json.dumps(report, indent=2))
    return report


def verify_lowered_popup_quota(cli, base, start, stop, state):
    name = 'popup-restore-quota'
    stop(); start(extra_env={'BROWSER_MAX_POPUPS_PER_SPACE': '2'})
    try:
        space = cli('space', 'create', name, '--proxy', 'direct')
        cli('open', urljoin(base, '/popups'), '--space', name)
        popups = []
        for _ in range(2):
            popup = cli('click', '#blank', '--wait-for-popup', '--space', name)['value']['newTabId']
            cli('wait', '--space', name, '--tab', popup)
            popups.append(popup)
        tab_ids = [tab['tabId'] for tab in cli('tab', 'list', '--space', name)]
        cli('space', 'suspend', name)
        stop(); start(extra_env={'BROWSER_MAX_POPUPS_PER_SPACE': '1'})
        cli('space', 'resume', name, error='resource_limit')
        cli('snapshot', '--space', name, error='resource_limit')
        assert cli('space', 'info', name)['liveWebViews'] == 0
        assert [tab['tabId'] for tab in cli('tab', 'list', '--space', name)] == tab_ids
        stop()
        # Only this run's own registry: request active restoration under the lower limit.
        registry = state / 'spaces.json'
        records = json.loads(registry.read_text())
        next(record for record in records if record['id'] == space['id'])['suspended'] = False
        temporary = state / 'popup-quota.tmp'
        temporary.write_text(json.dumps(records)); os.replace(temporary, registry)
        start(extra_env={'BROWSER_MAX_POPUPS_PER_SPACE': '1'})
        blocked = cli('space', 'info', name)
        assert blocked['lifecycle'] == 'suspended' and blocked['liveWebViews'] == 0 and blocked['resourceBlockedReason'], blocked
        assert [tab['tabId'] for tab in blocked['tabs']] == tab_ids
        cli('space', 'resume', name, error='resource_limit')
        cli('tab', 'close', popups[-1], '--space', name)
        cli('space', 'resume', name)
        cli('wait', '--space', name)
        cli('wait', '--space', name, '--tab', popups[0])
        cli('click', '#blank', '--wait-for-popup', '--timeout', '500', '--space', name, error='resource_limit')
        stop(); start(extra_env={'BROWSER_MAX_POPUPS_PER_SPACE': '1'})
        restored = cli('space', 'info', name)
        assert restored['lifecycle'] == 'active' and restored['liveWebViews'] == 2, restored
        assert [tab['tabId'] for tab in restored['tabs']] == [space['defaultTabId'], popups[0]]
    finally:
        for item in cli('space', 'list'):
            if item['name'] == name:
                cli('space', 'delete', item['id'])
        stop(); start()
    return dict(passed=True, loweredLimitBlocksResume=True, loweredLimitBlocksStartup=True,
                metadataPreserved=True, closeExtraPopupAllowsResume=True, exactLimitRestores=True)
