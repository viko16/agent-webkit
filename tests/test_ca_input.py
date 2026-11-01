"""Compile the real CA loader without AppKit; observe bounded reads in a test copy."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LIMIT = 1_048_576


@unittest.skipUnless(sys.platform == 'darwin', 'The CA loader uses macOS Security')
class CAInputTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        artifacts = ROOT / '.artifacts' / 'fix-ca-input'
        artifacts.mkdir(parents=True, exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix='probe-', dir=artifacts)
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        swift = shutil.which('swiftc')
        if not swift:
            raise RuntimeError('swiftc is required to test the CA loader')
        source = ROOT / 'Sources' / 'Browser' / 'TLS.swift'
        probe = ROOT / 'tests' / 'ca_input_probe.swift'
        cls.binary = cls.directory / 'ca-input-probe'
        cls.observed_binary = cls.directory / 'ca-input-observed'
        common = [swift, '-module-cache-path', str(artifacts / 'swift-cache')]
        cls.run_command([*common, str(source), str(probe), '-o', str(cls.binary)])
        # Inject observation into a temporary copy, preserving the product's control flow.
        original = source.read_text()
        if original.count('FileHandle(') != 1:
            raise AssertionError('Update the read observer for the CA loader file-handle construction')
        observed = cls.directory / 'TLS-observed.swift'
        observed.write_text(original.replace('FileHandle(', 'ObservedFileHandle('))
        cls.run_command([*common, '-D', 'CA_READ_OBSERVATION', str(observed), str(probe),
                         '-o', str(cls.observed_binary)])
        cls.pem = cls.directory / 'ca.pem'
        cls.der = cls.directory / 'ca.der'
        cls.run_command(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                         '-days', '1', '-subj', '/CN=CA input regression fixture',
                         '-keyout', str(cls.directory / 'ca.key'), '-out', str(cls.pem)])
        cls.run_command(['openssl', 'x509', '-in', str(cls.pem), '-outform', 'DER', '-out', str(cls.der)])

    @staticmethod
    def run_command(arguments):
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise AssertionError(f'{arguments[0]} failed:\n{result.stdout}\n{result.stderr}')
        return result

    def probe(self, path, observed=False, grow=False):
        environment = os.environ.copy()
        if grow:
            environment['CA_PROBE_GROW_PATH'] = str(path)
        binary = self.observed_binary if observed else self.binary
        result = subprocess.run([str(binary), json.dumps(str(path))], capture_output=True, text=True,
                                env=environment, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def assert_invalid(self, path, message=None, **options):
        result = self.probe(path, **options)
        self.assertFalse(result['ok'], result)
        self.assertEqual(result['code'], 'invalid_certificate', result)
        if message:
            self.assertIn(message, result['message'])
        return result

    def assert_bounded_reads(self, result, expected):
        total = 0
        self.assertTrue(result['reads'], 'The test must observe real file reads')
        for read in result['reads']:
            self.assertLessEqual(read['requested'], LIMIT + 1 - total)
            total += read['returned']
        self.assertEqual(total, expected)

    def test_single_pem_and_der_are_accepted(self):
        expected = base64.b64encode(self.der.read_bytes()).decode()
        for path in (self.pem, self.der):
            with self.subTest(format=path.suffix):
                self.assertEqual(self.probe(path), {'ok': True, 'der': expected})
        link = self.directory / 'ca-link.pem'
        link.symlink_to(self.pem)
        self.assertEqual(self.probe(link), {'ok': True, 'der': expected})

    def test_exact_limit_is_accepted_and_one_extra_byte_is_rejected(self):
        path = self.directory / 'limit.pem'
        pem = self.pem.read_bytes()
        path.write_bytes(pem + b' ' * (LIMIT - len(pem)))
        self.assertTrue(self.probe(path)['ok'])
        exact = self.probe(path, observed=True)
        self.assertTrue(exact['ok'])
        self.assert_bounded_reads(exact, LIMIT)
        with path.open('ab') as stream:
            stream.write(b' ')
        self.assert_invalid(path, '超过 1 MiB')

    def test_embedded_nul_does_not_accept_a_readable_certificate_prefix(self):
        self.assertTrue(self.probe(self.pem)['ok'])
        path = str(self.pem) + '\0suffix'
        for observed in (False, True):
            with self.subTest(observed=observed):
                result = self.probe(path, observed=observed)
                self.assertFalse(result['ok'], result)
                self.assertEqual(result['code'], 'operation_failed', result)
                if observed:
                    self.assertEqual(result['reads'], [])

    def test_invalid_empty_and_multiple_certificates_are_rejected(self):
        cases = (b'', b'not a certificate', b'-----BEGIN CERTIFICATE-----\n!\n-----END CERTIFICATE-----',
                 self.pem.read_bytes() * 2)
        for index, data in enumerate(cases):
            with self.subTest(case=index):
                path = self.directory / f'invalid-{index}.pem'
                path.write_bytes(data)
                self.assert_invalid(path)

    def test_missing_unreadable_and_nonregular_inputs_keep_operation_failed(self):
        fifo = self.directory / 'ca.fifo'
        os.mkfifo(fifo)
        unreadable = self.directory / 'unreadable.pem'
        unreadable.write_bytes(self.pem.read_bytes())
        unreadable.chmod(0)
        paths = [self.directory / 'missing.pem', self.directory, fifo, Path('/dev/zero')]
        if os.geteuid() != 0:
            paths.append(unreadable)
        for path in paths:
            with self.subTest(path=path.name):
                result = self.probe(path)
                self.assertFalse(result['ok'], result)
                self.assertEqual(result['code'], 'operation_failed', result)
                observed = self.probe(path, observed=True)
                self.assertEqual(observed['reads'], [], 'Nonregular inputs must be rejected before reading')

    def test_large_file_reads_only_the_limit_plus_one_byte(self):
        path = self.directory / 'large.der'
        with path.open('wb') as stream:
            stream.truncate(32 * LIMIT)
        self.assert_invalid(path, '超过 1 MiB')
        result = self.assert_invalid(path, '超过 1 MiB', observed=True)
        self.assert_bounded_reads(result, LIMIT + 1)
        self.assertGreater(len(result['reads']), 1, 'Short reads must preserve the total budget')

    def test_file_growth_after_metadata_check_is_still_bounded(self):
        path = self.directory / 'growing.pem'
        path.write_bytes(self.pem.read_bytes())
        self.assertLess(path.stat().st_size, LIMIT)
        result = self.assert_invalid(path, '超过 1 MiB', observed=True, grow=True)
        self.assertGreater(path.stat().st_size, LIMIT)
        self.assert_bounded_reads(result, LIMIT + 1)


if __name__ == '__main__':
    unittest.main()
