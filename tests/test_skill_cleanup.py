"""Failure-path cleanup without model calls or changes to the user's running services."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock

from skill_workflow import cleanup_test_services, finish_test_services


class SkillCleanupTests(unittest.TestCase):
    def services(self):
        daemon = Mock()
        daemon.poll.return_value = None
        daemon.terminate.side_effect = lambda: setattr(daemon.poll, 'return_value', -15)
        return daemon, Mock()

    def test_ipc_or_delete_failures_do_not_skip_other_cleanup(self):
        for failure in ('list', 'delete', 'shutdown'):
            with self.subTest(failure=failure):
                daemon, site = self.services()
                calls = []

                def cli(*args):
                    calls.append(args)
                    if args == ('space', 'list'):
                        if failure == 'list':
                            raise RuntimeError('IPC disconnected')
                        return [dict(id='first'), dict(id='second')]
                    if args == ('space', 'delete', 'first') and failure == 'delete':
                        raise RuntimeError('space_busy')
                    if args == ('shutdown',):
                        if failure == 'shutdown':
                            raise RuntimeError('shutdown failed')
                        daemon.poll.return_value = 0

                errors = cleanup_test_services(cli, daemon, site)
                self.assertEqual(len(errors), 1)
                self.assertIn(('shutdown',), calls)
                if failure == 'delete':
                    self.assertIn(('space', 'delete', 'second'), calls)
                if failure == 'shutdown':
                    daemon.terminate.assert_called_once()
                self.assertIsNotNone(daemon.poll())
                site.shutdown.assert_called_once()
                site.server_close.assert_called_once()

    def test_shutdown_timeout_uses_bounded_terminate_and_kill(self):
        daemon, site = self.services()
        daemon.wait.side_effect = [subprocess.TimeoutExpired('daemon', 15),
                                   subprocess.TimeoutExpired('daemon', 10), 0]
        cli = Mock(side_effect=[[], None])
        errors = cleanup_test_services(cli, daemon, site)
        self.assertEqual(len(errors), 1)
        daemon.terminate.assert_called_once()
        daemon.kill.assert_called_once()
        self.assertEqual([call.kwargs['timeout'] for call in daemon.wait.call_args_list], [15, 10, 10])
        site.shutdown.assert_called_once()
        site.server_close.assert_called_once()

    def test_original_failure_survives_cleanup_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            daemon, site = self.services()
            cli = Mock(side_effect=RuntimeError('IPC disconnected'))
            original = TimeoutError('Codex timed out')
            with self.assertRaises(TimeoutError) as caught:
                try:
                    raise original
                finally:
                    finish_test_services(cli, daemon, site, out)
            self.assertIs(caught.exception, original)
            self.assertEqual(len(json.loads((out / 'cleanup-errors.json').read_text())), 2)
            self.assertFalse((out / 'report.json').exists())
            site.server_close.assert_called_once()

    def test_cleanup_failure_cannot_report_success(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            daemon, site = self.services()
            with self.assertRaisesRegex(RuntimeError, 'Test cleanup failed'):
                finish_test_services(Mock(side_effect=RuntimeError('IPC disconnected')), daemon, site, out)
            self.assertTrue((out / 'cleanup-errors.json').is_file())
            self.assertFalse((out / 'report.json').exists())

    def test_startup_and_http_shutdown_failures_still_close_server(self):
        site = Mock()
        site.shutdown.side_effect = RuntimeError('HTTP shutdown failed')
        errors = cleanup_test_services(Mock(), None, site)
        self.assertEqual(len(errors), 1)
        site.server_close.assert_called_once()


if __name__ == '__main__':
    unittest.main()
