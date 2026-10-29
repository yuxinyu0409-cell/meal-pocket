#!/usr/bin/env python3
"""Serve the local prototype and recognize receipt images with macOS Vision."""
import argparse
import json
import subprocess
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent
OCR = ROOT / '.runtime' / 'receipt-ocr'

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def do_POST(self):
        if urlparse(self.path).path != '/api/recognize':
            self.send_error(404)
            return
        origin = self.headers.get('Origin')
        if origin and origin != 'http://' + self.headers.get('Host', ''):
            self.send_error(403)
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 8_000_000:
                self.send_error(413)
                return
            data = self.rfile.read(length)
            completed = subprocess.run([str(OCR)], input=data, capture_output=True, timeout=35, check=True)
            result = json.loads(completed.stdout)
            encoded = json.dumps(result, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
        except (ValueError, OSError, subprocess.SubprocessError):
            encoded = json.dumps({'error': '识别暂不可用，请手动补填'}, ensure_ascii=False).encode()
            self.send_response(503)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

    def log_message(self, fmt, *args):
        # Do not log uploaded images or recognized receipt content.
        super().log_message(fmt, *args)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    print(f'餐费小袋预览：http://127.0.0.1:{args.port}', flush=True)
    ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
