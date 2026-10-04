"""Loopback-only basic Git LFS transfer and locking server.
The harness resets its disk store, locks and request journal outside timing.
Uploads verify SHA-256 and size; every download and lock has fixed metadata.
"""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import sys
import threading
from urllib.parse import urlsplit

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
mutex = threading.Lock()
locks = []
journal = []


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def body(self):
        if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
            chunks = []
            while True:
                n = int(self.rfile.readline().split(b';')[0], 16)
                if not n:
                    while self.rfile.readline() not in (b'\r\n', b'\n', b''): pass
                    return b''.join(chunks)
                chunks.append(self.rfile.read(n))
                assert self.rfile.read(2) == b'\r\n'
        return self.rfile.read(int(self.headers.get('Content-Length', 0)))
    def reply(self, value, status=200, raw=False):
        data = value if raw else json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/octet-stream' if raw else 'application/vnd.git-lfs+json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def run(self):
        global locks, journal
        path = urlsplit(self.path).path
        data = self.body() if self.command in ('POST', 'PUT') else b''
        if path == '/_reset':
            seed = json.loads(data)
            with mutex:
                for p in root.iterdir(): p.unlink()
                for name in seed.get('objects', []):
                    src = Path(name)
                    shutil.copyfile(src, root/src.name)
                locks = seed.get('locks', [])
                journal = []
            return self.reply({})
        if path == '/_state':
            with mutex:
                return self.reply({'locks': locks, 'requests': journal,
                                   'objects': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.iterdir())}})
        if path == '/lfs/objects/batch':
            body = json.loads(data)
            op = body['operation']
            result = []
            for obj in body['objects']:
                oid, size = obj['oid'], obj['size']
                if len(oid) != 64 or any(c not in '0123456789abcdef' for c in oid):
                    return self.reply({'message': 'invalid oid'}, 400)
                url = f'http://127.0.0.1:{self.server.server_port}/lfs/objects/{oid}'
                actions = {}
                if op == 'download':
                    if not (root/oid).exists(): return self.reply({'message': 'missing object'}, 404)
                    actions['download'] = {'href': url}
                elif not (root/oid).exists():
                    actions = {'upload': {'href': url}, 'verify': {'href': url+'/verify'}}
                result.append(dict(obj, authenticated=True, actions=actions))
            with mutex: journal.append({'kind': 'batch', 'operation': op, 'objects': body['objects']})
            return self.reply({'transfer': 'basic', 'objects': result})
        if path.startswith('/lfs/objects/'):
            oid = path.split('/')[3]
            if len(oid) != 64 or any(c not in '0123456789abcdef' for c in oid):
                return self.reply({}, 400)
            if path.endswith('/verify'):
                body = json.loads(data)
                if body['oid'] != oid or (root/oid).stat().st_size != body['size']: return self.reply({}, 422)
                with mutex: journal.append({'kind': 'verify', 'oid': oid})
                return self.reply({})
            if self.command == 'PUT':
                if hashlib.sha256(data).hexdigest() != oid: return self.reply({}, 422)
                (root/oid).write_bytes(data)
                with mutex: journal.append({'kind': 'upload', 'oid': oid, 'bytes': len(data)})
                return self.reply({})
            data = (root/oid).read_bytes()
            with mutex: journal.append({'kind': 'download', 'oid': oid, 'bytes': len(data)})
            return self.reply(data, raw=True)
        if path == '/lfs/locks/verify':
            with mutex:
                journal.append({'kind': 'locks-verify'})
                return self.reply({'ours': locks, 'theirs': [], 'next_cursor': ''})
        if path == '/lfs/locks' and self.command == 'GET':
            with mutex:
                journal.append({'kind': 'locks-list'})
                return self.reply({'locks': locks, 'next_cursor': ''})
        if path == '/lfs/locks':
            body = json.loads(data)
            lock = {'id': '1', 'path': body['path'], 'locked_at': '2020-01-01T00:00:00Z', 'owner': {'name': 'anonymous'}}
            with mutex:
                if locks: return self.reply({'lock': locks[0]}, 409)
                locks.append(lock)
                journal.append({'kind': 'lock', 'path': lock['path']})
            return self.reply({'lock': lock}, 201)
        if path == '/lfs/locks/1/unlock':
            with mutex:
                if not locks: return self.reply({}, 404)
                lock = locks.pop()
                journal.append({'kind': 'unlock', 'path': lock['path']})
            return self.reply({'lock': lock})
        return self.reply({'message': 'unknown route'}, 404)
    do_GET = run
    do_POST = run
    do_PUT = run


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
print(server.server_port, flush=True)
server.serve_forever()
