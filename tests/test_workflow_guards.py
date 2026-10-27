"""Focused guards for workflow evidence; no daemon, GUI or network required."""
import unittest
from unittest.mock import Mock

from real_site_cases import site_gui_checks
from vite_cases import verify_hmr_acknowledgements


class HMRAcknowledgementsTests(unittest.TestCase):
    def test_distinct_documents_before_and_after_restart(self):
        expected = {'update': ['old-a', 'old-b'], 'restart': ['new-a', 'new-b']}
        events = [dict(revision=revision, documentId=document)
                  for revision, documents in expected.items() for document in reversed(documents)]
        verify_hmr_acknowledgements(events, expected)

    def test_reject_incomplete_or_wrong_document_evidence(self):
        cases = {
            'duplicate': ['new-a', 'new-a'],
            'missing': ['new-a'],
            'unexpected': ['new-a', 'other'],
            'before-restart': ['old-a', 'old-b'],
            'extra': ['new-a', 'new-b', 'new-b'],
            'missing-id': ['new-a', None],
        }
        for case, documents in cases.items():
            with self.subTest(case=case), self.assertRaises(AssertionError):
                events = [dict(revision='restart', documentId=document) for document in documents]
                verify_hmr_acknowledgements(events, {'restart': ['new-a', 'new-b']})


class SiteGUIChecksTests(unittest.TestCase):
    def test_each_workflow_keeps_its_callback_and_report(self):
        contexts = []
        for workflow in ('spa', 'login'):
            actual = dict(spaceId=workflow, tabId=workflow + '-tab', visible=workflow == 'spa')
            cli = Mock(return_value={'observer': actual})
            callback, report, created = Mock(), {}, {}
            checkpoint, observer = site_gui_checks(cli, created, report, callback)
            # The workflows populate their Space mapping after binding the helpers.
            created['work'] = {'id': workflow}
            contexts.append((checkpoint, observer, cli, callback, report, actual))
        for checkpoint, observer, cli, callback, report, actual in contexts:
            checkpoint('close', tab=actual['tabId'])
            callback.assert_called_once_with('close', {'tab': actual['tabId']})
            if actual['visible']:
                observer('work', actual['tabId'])
            else:
                observer('work', actual['tabId'], visible=False)
            cli.assert_called_once_with('status')
            self.assertEqual(report, {'observerChecks': [actual]})

    def test_wrong_space_tab_or_visibility_is_rejected_without_recording(self):
        for field, wrong in [('spaceId', 'other'), ('tabId', 'other'), ('visible', True)]:
            with self.subTest(field=field):
                actual = dict(spaceId='space', tabId='tab', visible=False)
                actual[field] = wrong
                report = {}
                _, observer = site_gui_checks(Mock(return_value={'observer': actual}),
                    {'work': {'id': 'space'}}, report, Mock())
                with self.assertRaises(AssertionError):
                    observer('work', 'tab', visible=False)
                self.assertEqual(report, {})

    def test_headless_checkpoint_does_not_query_or_record_gui_state(self):
        cli, report = Mock(), {}
        checkpoint, _ = site_gui_checks(cli, {}, report, None)
        checkpoint('headless', windowClosed=True)
        cli.assert_not_called()
        self.assertEqual(report, {})

    def test_rejected_checkpoint_propagates_without_recording(self):
        report = {}
        callback = Mock(side_effect=AssertionError('not confirmed'))
        checkpoint, _ = site_gui_checks(Mock(), {}, report, callback)
        with self.assertRaisesRegex(AssertionError, 'not confirmed'):
            checkpoint('close', windowClosed=True)
        self.assertEqual(report, {})


if __name__ == '__main__':
    unittest.main()
