"""Vercel Python application entry point. Deploy with Root Directory = backend."""
from http.server import BaseHTTPRequestHandler
from http_adapter import handler_for
from service import ServiceError, from_environment

try:
    service = from_environment()
except Exception:
    class Unconfigured:
        api_key = ''
        def recognize(self, *_):
            raise ServiceError(503, '云端识别服务尚未配置')
    service = Unconfigured()

_adapter = handler_for(service, vercel=True)

# Vercel statically detects a directly declared BaseHTTPRequestHandler subclass.
class handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def respond(self, status, value):
        return _adapter.respond(self, status, value)

    def do_GET(self):
        return _adapter.do_GET(self)

    def do_POST(self):
        return _adapter.do_POST(self)

    def log_message(self, *_):
        pass
