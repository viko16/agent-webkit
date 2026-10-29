"""Exercise the acceptance entry point with cleanup faults, without external services."""
from contextlib import ExitStack, redirect_stdout
from io import StringIO
import json
from pathlib import Path
from subprocess import CompletedProcess, TimeoutExpired
import tempfile
import unittest
from unittest.mock import Mock, patch

import acceptance


class AcceptanceCleanupTests(unittest.TestCase):
    def run_entry(self, mode='--vite-only', failure=None, original_failure=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            out = root / 'out'
            state = root / 'state'
            state.mkdir()
            (state / 'browser.sock').touch()
            pending_case = failure in ('pending', 'pending_uncleared')
            if pending_case:
                (state / 'spaces.json').write_text(json.dumps([dict(id='pending', deleting=True)]))
            daemon = Mock(returncode=0)
            daemon.poll.return_value = None
            daemon.terminate.side_effect = lambda: setattr(daemon.poll, 'return_value', -15)
            if failure == 'shutdown_timeout':
                daemon.wait.side_effect = [TimeoutExpired('browser', 15), 0]
            site = Mock(server_address=('127.0.0.1', 12345), fixture_nonce='test-nonce')
            whistle = Mock(url='http://127.0.0.1:12346', rules='test-rules')
            calls = []
            launches = 0

            def launch(*args, **kwargs):
                nonlocal launches
                launches += 1
                daemon.poll.return_value = None
                if failure == 'pending' and launches == 2:
                    (state / 'spaces.json').write_text('[]')
                return daemon

            def run(command, **kwargs):
                args = tuple(command[1:])
                calls.append(args)
                result = None
                fault = None
                if args == ('status',):
                    result = dict(ready=True)
                elif args == ('space', 'list'):
                    if failure == 'ipc':
                        fault = 'IPC disconnected during cleanup'
                    else:
                        result = [dict(id='first'), dict(id='second')]
                elif args[:2] == ('space', 'delete'):
                    if failure == 'delete' and args[2] == 'first':
                        fault = 'first Space delete failed'
                    else:
                        result = dict(websiteDataRemoved=True)
                elif args == ('shutdown', '--all'):
                    if failure == 'shutdown':
                        fault = 'shutdown failed'
                    else:
                        if failure != 'shutdown_timeout':
                            daemon.poll.return_value = 0
                        result = dict(shutdown=True)
                else:
                    raise AssertionError(f'Unexpected command {args}')
                payload = dict(ok=False, error=dict(code='injected_failure', message=fault)) if fault else dict(ok=True, result=result)
                return CompletedProcess(command, 1 if fault else 0, json.dumps(payload), '')

            def close_whistle():
                # An only-mode run must publish its final success after resource cleanup.
                self.assertFalse((out / 'report.json').exists())
                if failure == 'whistle':
                    raise RuntimeError('Whistle cleanup failed')

            whistle.close.side_effect = close_whistle
            if failure == 'http':
                site.shutdown.side_effect = RuntimeError('HTTP shutdown failed')
            if failure == 'http_close':
                site.server_close.side_effect = RuntimeError('HTTP close failed')
            workflow = Mock(return_value=dict(passed=True))
            if original_failure:
                workflow.side_effect = RuntimeError('Original workflow failure')

            with ExitStack() as stack:
                stack.enter_context(patch('sys.argv', ['acceptance.py', mode, '--out', str(out)]))
                stack.enter_context(patch.object(acceptance.tempfile, 'mkdtemp', return_value=str(state)))
                stack.enter_context(patch.object(acceptance, 'origin', return_value=(site, Mock())))
                stack.enter_context(patch.object(acceptance, 'WhistleFixture', return_value=whistle))
                stack.enter_context(patch.object(acceptance, 'processes', return_value=[]))
                stack.enter_context(patch.object(acceptance.subprocess, 'check_output', return_value='101'))
                stack.enter_context(patch.object(acceptance.subprocess, 'Popen', side_effect=launch))
                stack.enter_context(patch.object(acceptance.subprocess, 'run', side_effect=run))
                verifier = stack.enter_context(patch.object(acceptance, 'verify_cleanup'))
                if failure in ('registry', 'pending_uncleared'):
                    verifier.side_effect = AssertionError('Registry still contains a Space')
                for name in ('verify_vite_workflow', 'verify_proxy_uploads', 'verify_real_spa', 'verify_real_login', 'verify_independent_proxies'):
                    stack.enter_context(patch.object(acceptance, name, workflow))
                stack.enter_context(patch.object(acceptance, 'verify_proxy_arguments', return_value=dict(passed=True)))
                with redirect_stdout(StringIO()):
                    exit_code = acceptance.main()
            report = json.loads((out / 'report.json').read_text())
            cleanup_path = out / 'cleanup-errors.json'
            cleanup = json.loads(cleanup_path.read_text()) if cleanup_path.exists() else []
            self.assertEqual(site.shutdown.call_count, 2 if pending_case else 1)
            self.assertEqual(site.server_close.call_count, 2 if pending_case else 1)
            whistle.close.assert_called_once()
            return exit_code, report, cleanup, calls, daemon

    def test_every_only_mode_returns_nonzero_after_cleanup_failure(self):
        for mode in ('--vite-only', '--uploads-only', '--real-sites-only', '--independent-proxies-only'):
            with self.subTest(mode=mode):
                exit_code, report, cleanup, calls, _ = self.run_entry(mode, failure='delete')
                self.assertEqual(exit_code, 1)
                self.assertFalse(report['passed'])
                self.assertEqual(len(cleanup), 1)
                self.assertIn(('space', 'delete', 'second'), calls)
                self.assertIn(('shutdown', '--all'), calls)

    def test_independent_cleanup_faults_cannot_generate_success(self):
        for fault in ('ipc', 'shutdown', 'shutdown_timeout', 'whistle', 'http', 'http_close', 'registry'):
            with self.subTest(fault=fault):
                exit_code, report, cleanup, calls, daemon = self.run_entry(failure=fault)
                self.assertEqual(exit_code, 1)
                self.assertFalse(report['passed'])
                self.assertEqual(len(cleanup), 1)
                self.assertIn(('shutdown', '--all'), calls)
                if fault in ('shutdown', 'shutdown_timeout'):
                    daemon.terminate.assert_called_once()

    def test_original_failure_and_cleanup_failure_are_both_retained(self):
        for fault, message in [('delete', 'first Space delete failed'),
                               ('pending_uncleared', 'Registry still contains a Space')]:
            with self.subTest(fault=fault):
                exit_code, report, cleanup, _, _ = self.run_entry(failure=fault, original_failure=True)
                self.assertEqual(exit_code, 1)
                self.assertFalse(report['passed'])
                self.assertIn('Original workflow failure', report['failure'])
                self.assertIn(message, cleanup[0]['message'])
                self.assertEqual(report['cleanupErrors'], cleanup)

    def test_pending_container_is_retried_through_a_new_daemon(self):
        exit_code, report, cleanup, calls, daemon = self.run_entry(failure='pending')
        self.assertEqual(exit_code, 0)
        self.assertTrue(report['passed'])
        self.assertEqual(cleanup, [])
        self.assertEqual(calls.count(('shutdown', '--all')), 2)
        self.assertEqual(daemon.wait.call_count, 2)

    def test_retry_cannot_hide_a_nonempty_registry(self):
        exit_code, report, cleanup, calls, _ = self.run_entry(failure='pending_uncleared')
        self.assertEqual(exit_code, 1)
        self.assertFalse(report['passed'])
        self.assertEqual(calls.count(('shutdown', '--all')), 2)
        self.assertIn('Registry still contains a Space', cleanup[0]['message'])

    def test_success_is_reported_only_after_cleaning_up(self):
        exit_code, report, cleanup, _, daemon = self.run_entry()
        self.assertEqual(exit_code, 0)
        self.assertTrue(report['passed'])
        self.assertEqual(cleanup, [])
        daemon.terminate.assert_not_called()


if __name__ == '__main__':
    unittest.main()
