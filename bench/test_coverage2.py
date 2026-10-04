"""Loopback LFS fixture contracts: hashes, verify, lock ownership and reset."""
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from http.client import HTTPConnection

from coverage2_pass import LOCAL, CLONE, SERVE, LFS, missing


class LfsServerTests(unittest.TestCase):
    def test_bad_upload_rejected_and_transfer_and_locks_reset(self):
        with tempfile.TemporaryDirectory() as name:
            env = dict(os.environ, HOME=name, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
            server = subprocess.Popen([sys.executable, str(Path(__file__).parent/'src/lfs_server.py'), name],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
            try:
                self.assertTrue(select.select([server.stdout], [], [], 15)[0])
                port = int(server.stdout.readline())
                def request(path, data=None, method=None):
                    conn = HTTPConnection('127.0.0.1', port, source_address=('127.0.0.1', 0))
                    try:
                        conn.request(method or ('POST' if data is not None else 'GET'), path, body=data)
                        result = conn.getresponse()
                        body = result.read()
                        return result.status, body
                    finally: conn.close()
                payload = b'LFS fixture bytes\n'
                oid = hashlib.sha256(payload).hexdigest()
                batch = {'operation':'upload', 'objects':[{'oid':oid, 'size':len(payload)}]}
                answer = json.loads(request('/lfs/objects/batch', json.dumps(batch).encode())[1])
                self.assertIn('verify', answer['objects'][0]['actions'])
                self.assertEqual(request('/lfs/objects/'+oid, b'wrong', 'PUT')[0], 422)
                request('/lfs/objects/'+oid, payload, 'PUT')
                request('/lfs/objects/'+oid+'/verify', json.dumps({'oid':oid,'size':len(payload)}).encode())
                self.assertEqual(request('/lfs/objects/'+oid)[1], payload)
                first = json.loads(request('/lfs/locks', b'{"path":"data/f00.bin"}')[1])['lock']
                self.assertEqual(request('/lfs/locks', b'{"path":"data/f00.bin"}')[0], 409)
                listed = json.loads(request('/lfs/locks/verify', b'{}')[1])
                self.assertEqual(listed, {'ours':[first], 'theirs':[], 'next_cursor':''})
                request('/_reset', b'{}')
                state = json.loads(request('/_state')[1])
                self.assertEqual(state, {'locks':[], 'requests':[], 'objects':{}})
            finally:
                server.terminate()
                server.wait(timeout=5)
                server.stdout.close()
                server.stderr.close()

    def test_each_workload_has_explicit_competitor_availability(self):
        self.assertEqual(len(LOCAL+CLONE+SERVE+LFS), 24)
        for tool in ('gix','libgit2','go-git'):
            for workload in LOCAL+CLONE+SERVE+LFS:
                reason = missing(tool, workload)
                supported = workload=='clone-depth' or (workload=='midx-read' and tool!='go-git') or (workload=='serve-full' and tool=='go-git')
                self.assertEqual(reason is None, supported, (tool,workload))
                if reason: self.assertNotIn('\n', reason)


if __name__ == '__main__': unittest.main()
