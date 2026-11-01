"""Exercise real IPC writes when the peer closes before socket configuration."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin', 'The IPC transport uses Darwin sockets')
class SocketDisconnectTests(unittest.TestCase):
    def test_early_disconnect_does_not_terminate_or_poison_later_writes(self):
        artifacts = ROOT / '.artifacts' / 'socket-disconnect'
        artifacts.mkdir(parents=True, exist_ok=True)
        swift = shutil.which('swiftc')
        self.assertIsNotNone(swift, 'swiftc is required to test the IPC transport')
        with tempfile.TemporaryDirectory(prefix='probe-', dir=artifacts) as directory:
            directory = Path(directory)
            source = directory / 'Socket.swift'
            # Append in a test copy to reach file-private transport helpers without production hooks.
            source.write_text((ROOT / 'Sources/Browser/Socket.swift').read_text() + r'''

@main struct SocketDisconnectProbe {
    static func main() throws {
        signal(SIGPIPE, SIG_DFL)
        var broken: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &broken) == 0)
        defer { close(broken[0]) }
        close(broken[1])
        // macOS may reject SO_NOSIGPIPE after an early peer disconnect.
        configure(broken[0])
        do {
            try writeMessage(broken[0], Data("reply".utf8))
            preconditionFailure("A disconnected peer must fail the write")
        } catch let error as BrowserError {
            precondition(error.code == "ipc_error")
        }

        var healthy: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &healthy) == 0)
        defer { close(healthy[0]); close(healthy[1]) }
        configure(healthy[0]); configure(healthy[1])
        try writeMessage(healthy[0], Data("healthy".utf8))
        let reply = try readMessage(healthy[1])
        precondition(reply == Data("healthy".utf8))
        print("{\"disconnectedWriteFailed\":true,\"healthyWriteSucceeded\":true}")
    }
}
''')
            binary = directory / 'socket-disconnect-probe'
            build = subprocess.run([swift, '-module-cache-path', str(artifacts / 'swift-cache'),
                                    str(ROOT / 'Sources/Browser/Protocol.swift'), str(source),
                                    '-o', str(binary)], capture_output=True, text=True, timeout=120)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout), dict(disconnectedWriteFailed=True,
                                                            healthyWriteSucceeded=True))


if __name__ == '__main__':
    unittest.main()
