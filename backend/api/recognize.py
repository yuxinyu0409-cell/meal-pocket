"""Vercel Python function entry point. Deploy with Root Directory = backend."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
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

handler = handler_for(service, vercel=True)
