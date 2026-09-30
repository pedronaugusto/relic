#!/usr/bin/env python3
"""git http-backend behind HTTP/1.1 with keep-alive, as a hosting service
serves it: every request a CGI run, chunked and gzip request bodies passed
on, the answer sent with its length. Prints its port."""
import http.server, os, socketserver, subprocess, sys
root = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def body(self):
        if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
            out = bytearray()
            while True:
                n = int(self.rfile.readline().split(b';')[0].strip(), 16)
                if n == 0:
                    while self.rfile.readline() not in (b'\r\n', b'\n', b''): pass
                    return bytes(out)
                out += self.rfile.read(n); self.rfile.readline()
        n = int(self.headers.get('Content-Length') or 0)
        return self.rfile.read(n) if n else b''
    def run(self):
        path, _, query = self.path.partition('?')
        env = {'PATH': os.environ['PATH'], 'GIT_PROJECT_ROOT': root, 'GIT_HTTP_EXPORT_ALL': '1',
               'PATH_INFO': path, 'QUERY_STRING': query, 'REQUEST_METHOD': self.command,
               'CONTENT_TYPE': self.headers.get('Content-Type', ''), 'REMOTE_ADDR': '127.0.0.1',
               'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull}
        if self.headers.get('Git-Protocol'): env['GIT_PROTOCOL'] = self.headers['Git-Protocol']
        if self.headers.get('Content-Encoding'): env['HTTP_CONTENT_ENCODING'] = self.headers['Content-Encoding']
        data = self.body() if self.command == 'POST' else b''
        env['CONTENT_LENGTH'] = str(len(data))
        out = subprocess.run(['git', 'http-backend'], input=data, env=env, capture_output=True).stdout
        head, _, rest = out.partition(b'\r\n\r\n')
        if not _:
            head, _, rest = out.partition(b'\n\n')
        status = 200; headers = []
        for line in head.decode('latin-1').splitlines():
            k, _, v = line.partition(':'); v = v.strip()
            if k.lower() == 'status': status = int(v.split()[0])
            else: headers.append((k, v))
        self.send_response(status)
        for k, v in headers: self.send_header(k, v)
        self.send_header('Content-Length', str(len(rest)))
        self.end_headers(); self.wfile.write(rest)
    do_GET = run
    do_POST = run
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
s = S(('127.0.0.1', 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
