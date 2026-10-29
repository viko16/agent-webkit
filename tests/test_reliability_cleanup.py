"""Inject cleanup failures through reliability.main's final reporting path."""
from contextlib import ExitStack, redirect_stdout
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import reliability


class ReliabilityCleanupTests(unittest.TestCase):
    def run_entry(self, directory, flag='--uploads-only', failure=None, primary=None, deferred=False):
        root = Path(directory)
        state = root / 'state'
        state.mkdir()
        (state / 'browser.sock').touch()
        (state / 'spaces.json').write_text('[]')
        out = root / '.artifacts' / 'run'
        daemon, site = Mock(), Mock()
        daemon.poll.return_value = None
        daemon.terminate.side_effect = lambda: setattr(daemon.poll, 'return_value', -15)
        daemon.wait.return_value = 0
        site.server_address = ('127.0.0.1', 12345)
        site.fixture_nonce = 'fixture'
        calls = []

        def launch(*args, **kwargs):
            calls.append(('daemon-start',))
            daemon.poll.return_value = None
            if deferred and calls.count(('daemon-start',)) > 1:
                (state / 'spaces.json').write_text('[]')
            return daemon

        def command(arguments, **kwargs):
            args = tuple(arguments[1:])
            calls.append(args)
            code, result, ok = 0, {}, True
            if args[0] == 'open':
                code, ok = 1, False
                response = dict(ok=False, error=dict(code='invalid_arguments'))
            else:
                if args == ('status',):
                    result = dict(ready=True)
                elif args == ('space', 'list'):
                    self.assertFalse((out / 'report.json').exists(), 'Report preceded cleanup')
                    if failure == 'list':
                        raise RuntimeError('list failed')
                    result = [dict(id='first'), dict(id='second')]
                elif args[:2] == ('space', 'delete'):
                    if failure == 'delete' and args[2] == 'first':
                        raise RuntimeError('delete failed')
                    result = dict(websiteDataRemoved=True)
                elif args == ('shutdown', '--all'):
                    self.assertFalse((out / 'report.json').exists(), 'Report preceded shutdown')
                    if failure == 'shutdown':
                        raise RuntimeError('shutdown failed')
                    daemon.poll.return_value = 0
                    if deferred and calls.count(('daemon-start',)) == 1:
                        (state / 'spaces.json').write_text('[{"deleting":true}]')
                response = dict(ok=ok, result=result)
            return subprocess.CompletedProcess(arguments, code, stdout=json.dumps(response), stderr='')

        def close():
            self.assertFalse((out / 'report.json').exists(), 'Report preceded HTTP close')
            if failure == 'http':
                raise RuntimeError('HTTP close failed')

        site.server_close.side_effect = close
        output = io.StringIO()
        caught = None
        with ExitStack() as stack:
            stack.enter_context(patch.object(reliability, 'ROOT', root))
            stack.enter_context(patch.object(reliability.sys, 'argv', ['reliability.py', *([flag] if flag else [])]))
            stack.enter_context(patch.object(reliability.tempfile, 'mkdtemp', return_value=str(state)))
            stack.enter_context(patch.object(reliability.time, 'strftime', return_value='run'))
            stack.enter_context(patch.object(reliability, 'origin', return_value=(site, Mock())))
            stack.enter_context(patch.object(reliability.subprocess, 'run', side_effect=command))
            stack.enter_context(patch.object(reliability.subprocess, 'Popen', side_effect=launch))
            verification = stack.enter_context(patch.object(reliability, 'verify_cleanup'))
            for name in ('verify_offline', 'verify_capacity', 'verify_snapshot_budget', 'verify_state_integrity',
                         'verify_proxy_summary', 'verify_screenshots', 'verify_fullpage', 'verify_uploads',
                         'verify_downloads', 'verify_lifecycle', 'verify_dialogs', 'verify_diagnostics',
                         'verify_detailed_diagnostics', 'verify_pending_store_only', 'verify_store_cleanup_failures',
                         'verify_delete_persistence_failure'):
                check = stack.enter_context(patch.object(reliability, name, return_value={'check': name}))
                if primary is not None and name == ('verify_uploads' if flag else 'verify_pending_store_only'):
                    check.side_effect = primary
            if failure == 'verify':
                verification.side_effect = AssertionError('Registry or socket still present')
            with redirect_stdout(output):
                try:
                    reliability.main()
                except Exception as error:
                    caught = error
        report = json.loads((out / 'report.json').read_text())
        self.assertEqual(json.loads(output.getvalue()), report)
        site.shutdown.assert_called()
        site.server_close.assert_called()
        self.assertIsNotNone(daemon.poll())
        return caught, report, calls, out, verification

    def test_each_only_branch_reports_success_after_cleanup(self):
        for flag in ('--resources-only', '--integrity-only', '--screenshots-only', '--uploads-only',
                     '--downloads-only', '--lifecycle-only', '--dialogs-only', '--diagnostics-only', '--cleanup-only'):
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as directory:
                caught, report, calls, out, verification = self.run_entry(directory, flag=flag)
                self.assertIsNone(caught)
                self.assertTrue(report['ok'])
                self.assertIn(('space', 'delete', 'second'), calls)
                self.assertIn(('shutdown', '--all'), calls)
                verification.assert_called_once()
                self.assertFalse((out / 'cleanup-errors.json').exists())

    def test_cleanup_failures_write_failed_report_and_exit_nonzero(self):
        for failure in ('list', 'delete', 'shutdown', 'http', 'verify'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                caught, report, calls, out, _ = self.run_entry(directory, failure=failure)
                self.assertIsInstance(caught, RuntimeError)
                self.assertFalse(report['ok'])
                self.assertTrue(report['cleanupErrors'])
                self.assertTrue((out / 'cleanup-errors.json').exists())
                self.assertIn(('shutdown', '--all'), calls)
                if failure == 'delete':
                    self.assertIn(('space', 'delete', 'second'), calls)

    def test_original_failure_is_preserved_in_only_and_full_entries(self):
        for flag in ('--uploads-only', None):
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as directory:
                primary = TimeoutError('original test failure')
                caught, report, _, out, _ = self.run_entry(directory, flag=flag, failure='delete', primary=primary)
                self.assertIs(caught, primary)
                self.assertFalse(report['ok'])
                self.assertEqual(report['error'], dict(type='TimeoutError', message='original test failure'))
                self.assertTrue((out / 'cleanup-errors.json').exists())

    def test_deferred_store_cleanup_restarts_before_final_success(self):
        with tempfile.TemporaryDirectory() as directory:
            caught, report, calls, _, verification = self.run_entry(directory, deferred=True)
            self.assertIsNone(caught)
            self.assertTrue(report['ok'])
            self.assertEqual(calls.count(('daemon-start',)), 2)
            verification.assert_called_once()


if __name__ == '__main__':
    unittest.main()
