#!/usr/bin/env python3
"""Run behind the included HTTPS reverse proxy for public deployment."""
import ipaddress
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from service import MAX_IMAGE, ServiceError, from_environment


def handler_for(service, trusted_proxy=None, *, vercel=False):
    trusted = ipaddress.ip_network(trusted_proxy) if trusted_proxy else None

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(15)

        def respond(self, status, value):
            body = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Connection', 'close')
            if status == 429:
                self.send_header('Retry-After', '60')
            self.end_headers()
            self.close_connection = True
            self.wfile.write(body)

        def do_GET(self):
            if self.path in ('/health', '/api/health'):
                self.respond(200 if service.api_key else 503, {'ready': bool(service.api_key)})
            else:
                self.respond(404, {'error': '接口不存在'})

        def do_POST(self):
            try:
                if self.path != '/api/recognize':
                    raise ServiceError(404, '接口不存在')
                if self.headers.get('Transfer-Encoding'):
                    raise ServiceError(400, '不支持的请求编码')
                lengths = self.headers.get_all('Content-Length', [])
                if len(lengths) != 1:
                    raise ServiceError(411, '缺少图片长度')
                try:
                    length = int(lengths[0])
                except ValueError:
                    raise ServiceError(400, '无效的图片长度')
                if not 0 < length <= MAX_IMAGE:
                    raise ServiceError(413, '图片过大')
                if self.headers.get('Content-Type', '').split(';')[0].strip() != 'image/jpeg':
                    raise ServiceError(415, '请上传 JPEG 图片')
                image = self.rfile.read(length)
                if len(image) != length:
                    raise ServiceError(400, '图片上传不完整')
                ip = self.client_address[0]
                if vercel:
                    try:
                        ip = str(ipaddress.ip_address(self.headers.get('X-Vercel-Forwarded-For', '').strip()))
                    except ValueError:
                        raise ServiceError(400, '无效的来源地址')
                elif trusted and ipaddress.ip_address(ip) in trusted:
                    # Caddy overwrites this header; direct clients cannot select a quota identity.
                    forwarded = self.headers.get('X-Forwarded-For', '').split(',')[-1].strip()
                    try:
                        ip = str(ipaddress.ip_address(forwarded))
                    except ValueError:
                        raise ServiceError(400, '无效的来源地址')
                result = service.recognize(image, ip, self.headers.get('X-Installation-ID', ''))
                self.respond(200, result)
            except ServiceError as error:
                self.respond(error.status, {'error': error.message, **({'code': error.code} if error.code else {})})
            except (TimeoutError, ConnectionError):
                self.close_connection = True
            except Exception:
                # Do not include credentials, upstream bodies or receipt contents in responses/logs.
                self.respond(503, {'error': '识别暂不可用，请使用离线识别'})

        def log_message(self, *_):
            pass

    return Handler


if __name__ == '__main__':
    service = from_environment()
    server = ThreadingHTTPServer((os.environ.get('HOST', '0.0.0.0'), int(os.environ.get('PORT', '8080'))),
                                handler_for(service, os.environ.get('TRUSTED_PROXY_CIDR')))
    server.daemon_threads = True
    print('Receipt OCR service started', flush=True)
    server.serve_forever()
