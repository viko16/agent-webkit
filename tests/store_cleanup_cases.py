"""Restore a real pending store when no live Space has initialized WebKit yet."""
import json
import os


def verify_pending_store_only(cli, start, stop, state, base):
    name = 'pending-only'
    created = cli('space', 'create', name, '--proxy', 'direct')
    cli('open', base, '--space', name)
    cli('evaluate', 'localStorage.setItem("cleanup-probe","must-be-removed");true', '--space', name)
    stop()
    registry = state / 'spaces.json'
    records = json.loads(registry.read_text())
    assert len(records) == 1 and records[0]['id'] == created['id'], records
    # This is this run's generated registry. Model a crash after the deletion
    # tombstone was persisted, before the actual WebKit purge could complete.
    # Do not remove the website store or replace WebKit with a mock.
    records[0]['deleting'] = True
    temporary = state / 'pending-only.tmp'
    temporary.write_text(json.dumps(records))
    os.replace(temporary, registry)
    start()
    assert cli('status')['pendingStoreCleanup'] == 0
    assert cli('space', 'list') == [] and json.loads(registry.read_text()) == []
    replacement = cli('space', 'create', name, '--proxy', 'direct')
    assert replacement['id'] != created['id']
    cli('open', base, '--space', name)
    assert cli('evaluate', 'localStorage.getItem("cleanup-probe")', '--space', name)['value'] is None
    assert cli('space', 'delete', name)['websiteDataRemoved']
    return {'passed': True, 'pendingId': created['id'], 'replacementId': replacement['id'],
            'method': 'real store + interrupted-deletion registry; new process with no live Spaces',
            'pendingStoreCleanup': 0, 'registryEmptyAfterRestore': True}
