"""Focused guards for workflow evidence; no daemon, GUI or network required."""
import unittest

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


if __name__ == '__main__':
    unittest.main()
