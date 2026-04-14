#!/usr/bin/env python3
"""Savanna server — static files + reset + spacetime speed control. Threaded."""
import http.server, socketserver, os
from urllib.parse import urlparse, parse_qs

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        if path.startswith('/7c_') and path.endswith('.wav'):
            try:
                fname = '/tmp' + path.replace('.wav', '_000.wav')
                with open(fname, 'rb') as f: data = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'audio/wav')
                self.send_header('Content-Length', len(data))
                self.end_headers()
                self.wfile.write(data)
            except: self.send_error(404)
        elif path == '/reset':
            with open('savanna_cmd.txt', 'w') as f: f.write('reset')
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(b'reset')
        elif path == '/set_speed':
            # Spacetime zoom: update sleep interval
            sleep_ms = params.get('sleep', ['50'])[0]
            with open('savanna_sleep.txt', 'w') as f: f.write(sleep_ms)
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(f'sleep={sleep_ms}'.encode())
        else:
            super().do_GET()
    def log_message(self, *a): pass

class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

print("Savanna server on :8765 (threaded)")
ThreadedServer(('', 8765), Handler).serve_forever()
