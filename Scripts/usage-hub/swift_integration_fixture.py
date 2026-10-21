#!/usr/bin/env python3
"""Real loopback hub for Swift URLSession integration; synthetic state only."""
import json
import os
from pathlib import Path
import socket
import sys
import time

import midas_usage_hub as hub

os.umask(0o077)
root = Path(sys.argv[1]).resolve()
store = hub.Store.initialize(root / 'hub')
server = hub.HubServer(('127.0.0.1', 0), store)
endpoint = 'http://127.0.0.1:' + str(server.server_port)
connections = []
for name in ('fixture-one', 'fixture-two', 'fixture-legacy'):
    path = root / (name + '.json')
    store.add_device(name, endpoint, path)
    connections.append(json.loads(path.read_bytes()))
at = time.time() - hub.APPLE_EPOCH - 1
legacy = connections[2]
store.exchange(legacy['credential'], {'schemaVersion': 1, 'workspaceID': legacy['workspaceID'],
    'deviceID': legacy['deviceID'], 'deviceName': legacy['deviceName'], 'publishedAt': at,
    'excludedRecords': 0, 'events': [], 'accountDays': []})

class FaultHandler(hub.HubHandler):
    def send_bytes(self, status, body):
        control = root / 'fault.txt'
        fault = control.read_text() if control.exists() else ''
        applies = ((fault == 'drop-commit' and self.path == '/v2/upload/commit') or
                   (fault == 'drop-receipt' and self.path == '/v2/receipt') or
                   (fault in ('truncate-page', 'slow-page') and self.path.startswith('/v2/pages/')))
        if applies and status == 200:
            control.unlink(missing_ok=True)
            if fault.startswith('drop-'):
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                return
            if fault == 'slow-page':
                time.sleep(.15)
            else:
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(body[:len(body)//2])
                self.close_connection = True
                return
        super().send_bytes(status, body)

server.RequestHandlerClass = FaultHandler
with store.connect() as c:
    workspace = store.workspace_in(c)
(root / 'ready.json').write_text(json.dumps({'connections': connections, 'workspace': workspace}))
server.serve_forever(poll_interval=.05)
