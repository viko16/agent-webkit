"""Local origin and an observable HTTP CONNECT proxy; no third-party dependencies."""
import argparse
import http.server
import json
from pathlib import Path
import select
import socket
import socketserver
import threading
import time
import urllib.parse
import uuid


class Events:
    def __init__(self, path=None):
        self.items = []
        self.path = path
        self.lock = threading.Lock()

    def add(self, **event):
        event['time'] = time.time()
        with self.lock:
            self.items.append(event)
            if self.path:
                with open(self.path, 'a') as stream:
                    stream.write(json.dumps(event) + '\n')


class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def origin(port=0, events=None, tls_context=None):
    events = events or Events()
    nonce = uuid.uuid4().hex
    html = (Path(__file__).parent / 'site/index.html').read_text().replace('__FIXTURE_NONCE__', nonce)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            time.sleep(min(float(query.get('delay', ['0'])[0]), 3))
            events.add(kind='origin', path=self.path, peerPort=self.client_address[1], cookie=self.headers.get('Cookie'), host=self.headers.get('Host'), nonce=nonce)
            body = html.replace('__PEER_PORT__', str(self.client_address[1])).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    server = Server(('127.0.0.1', port), Handler)
    server.fixture_nonce = nonce
    if tls_context:
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, events


def proxy(port=8899, events=None):
    events = events or Events()

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(10)
            data = b''
            while b'\r\n\r\n' not in data and len(data) < 65536:
                chunk = self.request.recv(4096)
                if not chunk:
                    return
                data += chunk
            first = data.split(b'\r\n', 1)[0].decode()
            method, target, _ = first.split(' ', 2)
            if method != 'CONNECT':
                events.add(kind='rejected', request=first)
                self.request.sendall(b'HTTP/1.1 405 CONNECT required\r\nContent-Length: 0\r\n\r\n')
                return
            host, port_text = target.rsplit(':', 1)
            # A test fixture, deliberately unable to relay outside the local machine.
            if host not in ('127.0.0.1', 'localhost', '[::1]', 'agent-webkit.test'):
                events.add(kind='rejected', request=first)
                self.request.sendall(b'HTTP/1.1 403 Local targets only\r\nContent-Length: 0\r\n\r\n')
                return
            destination = '127.0.0.1' if host == 'agent-webkit.test' else host.strip('[]')
            with socket.create_connection((destination, int(port_text)), timeout=5) as upstream:
                events.add(kind='connect', target=target, peerPort=self.client_address[1], upstreamPort=upstream.getsockname()[1])
                self.request.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
                pending = data.split(b'\r\n\r\n', 1)[1]
                if pending:
                    upstream.sendall(pending)
                while True:
                    ready, _, _ = select.select([self.request, upstream], [], [], 15)
                    if not ready:
                        return
                    for source in ready:
                        chunk = source.recv(65536)
                        if not chunk:
                            return
                        (upstream if source is self.request else self.request).sendall(chunk)

    server = Server(('127.0.0.1', port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, events


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('kind', choices=['origin', 'proxy'])
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--log')
    args = parser.parse_args()
    server, _ = (origin if args.kind == 'origin' else proxy)(args.port, Events(args.log))
    print(json.dumps({'kind': args.kind, 'port': server.server_address[1]}), flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        server.shutdown()
