import base64
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import uuid

from service import MAX_IMAGE, OCRService, Quotas, RedisQuotas, ServiceError, from_environment, validate_receipt
from http_adapter import handler_for

IMAGE = b'\xff\xd8\xff' + b'test image'
INSTALL = str(uuid.uuid4())
RECEIPT = {'merchant': '测试餐厅', 'date': '2026-10-29', 'amount': '28.50'}

class Response(io.BytesIO):
    pass

class Socket:
    def __init__(self, request):
        self.input, self.output = io.BytesIO(request), bytearray()
    def makefile(self, *args):
        return self.input
    def sendall(self, data):
        self.output.extend(data)
    def settimeout(self, _):
        pass


def call_handler(handler, *, path='/api/recognize', method='POST', body=IMAGE, extra=None):
    headers = {'Host': 'ocr.example.com', 'Content-Type': 'image/jpeg',
               'Content-Length': str(len(body)), 'X-Installation-ID': INSTALL}
    headers.update(extra or {})
    request = f'{method} {path} HTTP/1.1\r\n' + ''.join(f'{k}: {v}\r\n' for k,v in headers.items()) + '\r\n'
    sock = Socket(request.encode() + body)
    handler(sock, ('127.0.0.1', 50000), object())
    head, encoded = bytes(sock.output).split(b'\r\n\r\n', 1)
    return int(head.split(b' ')[1]), json.loads(encoded)


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.quotas = Quotas(Path(self.directory.name) / 'quota.sqlite3')
        self.upstream_calls = []
        self.completion = {'choices': [{'finish_reason': 'stop', 'message': {'content': json.dumps(RECEIPT)}}]}
        def upstream(request, timeout):
            self.upstream_calls.append(request)
            return Response(json.dumps(self.completion).encode())
        self.service = OCRService('secret-test-only', self.quotas, opener=upstream)

    def test_upstream_contract(self):
        self.assertEqual(self.service.recognize(IMAGE, '127.0.0.1', INSTALL), RECEIPT)
        request = self.upstream_calls[0]
        self.assertEqual(request.full_url, 'https://api.deepseek.com/chat/completions')
        self.assertEqual(request.get_header('Authorization'), 'Bearer secret-test-only')
        payload = json.loads(request.data)
        self.assertEqual(payload['model'], 'deepseek-flash')
        self.assertEqual(payload['thinking']['type'], 'disabled')
        self.assertEqual(payload['messages'][0]['content'][1]['image_url']['url'], 'data:image/jpeg;base64,' + base64.b64encode(IMAGE).decode())

    def test_bad_images_and_installation_never_call_upstream(self):
        for image, installation, status in [(b'bad', INSTALL, 415), (b'', INSTALL, 413), (IMAGE, 'invalid', 400), (b'x' * (MAX_IMAGE+1), INSTALL, 413)]:
            with self.assertRaises(ServiceError) as raised:
                self.service.recognize(image, 'ip', installation)
            self.assertEqual(raised.exception.status, status)
        self.assertEqual(self.upstream_calls, [])

    def test_response_validation(self):
        for invalid in [{}, dict(RECEIPT, date='2026-02-31'), dict(RECEIPT, amount=28.5), dict(RECEIPT, amount='-1.00'), dict(RECEIPT, merchant='餐厅\n实付50'), dict.fromkeys(RECEIPT)]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                validate_receipt(invalid)
        self.assertEqual(validate_receipt(dict(RECEIPT, amount=None))['amount'], None)

    def test_truncation_and_upstream_errors_are_sanitized(self):
        self.completion['choices'][0]['finish_reason'] = 'length'
        with self.assertRaises(ServiceError) as raised:
            self.service.recognize(IMAGE, 'ip', INSTALL)
        self.assertEqual(raised.exception.status, 502)
        def failed(*_, **__):
            raise urllib.error.HTTPError('https://example.com', 401, 'secret-test-only', {}, Response(b'secret-test-only'))
        self.service.opener = failed
        with self.assertRaises(ServiceError) as raised:
            self.service.recognize(IMAGE, 'ip', INSTALL)
        self.assertNotIn('secret-test-only', str(raised.exception))
        self.assertEqual(raised.exception.status, 503)
        self.assertEqual(raised.exception.code, 'provider_http_401')

    def test_global_quota_is_atomic_and_persistent(self):
        now = datetime(2026,10,29,tzinfo=timezone.utc)
        def reserve(i):
            other_instance = Quotas(self.quotas.path)
            try:
                other_instance.reserve(str(i),str(i),7,100,100,100,now)
                return True
            except ServiceError:
                return False
        with ThreadPoolExecutor(max_workers=8) as pool:
            self.assertEqual(sum(pool.map(reserve,range(30))),7)
        with self.quotas.connect() as db:
            serialized = repr(db.execute('SELECT * FROM counters').fetchall())
            self.assertNotIn('install:127.0.0.1', serialized)
        self.quotas.reserve('ip','install',7,100,100,100,datetime(2026,10,30,tzinfo=timezone.utc))

    def test_individual_limits(self):
        now = datetime(2026,10,29,tzinfo=timezone.utc)
        self.quotas.reserve('ip',INSTALL,100,100,100,1,now)
        with self.assertRaises(ServiceError):
            self.quotas.reserve('ip',str(uuid.uuid4()),100,100,100,1,now)
        # Installation quota holds across a change of IP.
        with self.assertRaises(ServiceError):
            self.quotas.reserve('other',INSTALL,100,100,1,100,now)

    def test_http_routes_and_forwarded_ip_trust(self):
        handler = handler_for(self.service)
        self.assertEqual(call_handler(handler)[0],200)
        self.assertEqual(call_handler(handler,path='/wrong')[0],404)
        self.assertEqual(call_handler(handler,extra={'Content-Type':'text/plain'})[0],415)
        self.assertEqual(call_handler(handler,extra={'Content-Length':'no'})[0],400)
        self.assertEqual(call_handler(handler,extra={'Transfer-Encoding':'chunked'})[0],400)
        self.assertEqual(call_handler(handler,path='/api/health',method='GET')[0],200)
        with patch.object(self.service,'recognize',return_value=RECEIPT) as recognize:
            call_handler(handler,extra={'X-Forwarded-For':'1.2.3.4'})
            self.assertEqual(recognize.call_args.args[1], '127.0.0.1')
            vercel = handler_for(self.service,vercel=True)
            self.assertEqual(call_handler(vercel)[0],400)
            self.assertEqual(call_handler(vercel,extra={'X-Vercel-Forwarded-For':'203.0.113.1'})[0],200)
            self.assertEqual(recognize.call_args.args[1], '203.0.113.1')

    def test_unconfigured_service_fails_closed(self):
        self.service.api_key = ''
        handler = handler_for(self.service)
        self.assertEqual(call_handler(handler)[0],503)
        self.assertEqual(call_handler(handler,path='/api/health',method='GET')[0],503)
        self.assertFalse(self.upstream_calls)
        with patch.dict('os.environ',{'VERCEL':'1'},clear=True), self.assertRaises(ValueError):
            from_environment()

    def test_vercel_entry_points_load_without_credentials(self):
        import sys
        sys.path.insert(0,str(Path(__file__).resolve().parent))
        with patch.dict('os.environ',{'VERCEL':'1'},clear=True):
            spec = importlib.util.spec_from_file_location('vercel_root_entry',Path(__file__).parent / 'index.py')
            root_module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(root_module)
            self.assertEqual(call_handler(root_module.handler,extra={'X-Vercel-Forwarded-For':'203.0.113.1'})[0],503)
            status, body = call_handler(root_module.handler,path='/api/health',method='GET')
            self.assertEqual(status,503)
            self.assertFalse(body['ready'])
            spec = importlib.util.spec_from_file_location('vercel_ocr_entry',Path(__file__).parent / 'api' / 'recognize.py')
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            self.assertEqual(call_handler(module.handler,extra={'X-Vercel-Forwarded-For':'203.0.113.1'})[0],503)
            spec = importlib.util.spec_from_file_location('vercel_health_entry',Path(__file__).parent / 'api' / 'health.py')
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            status, body = call_handler(module.handler,path='/api/health',method='GET')
            self.assertEqual(status,503)
            self.assertFalse(body['ready'])

    def test_vercel_marketplace_environment_names(self):
        with patch.dict('os.environ',{'VERCEL':'1','KV_REST_API_URL':'https://redis.example.com',
                                      'KV_REST_API_TOKEN':'test-only','QUOTA_HASH_SECRET':'a'*32,
                                      'DEEPSEEK_API_KEY':'test-only'},clear=True):
            service = from_environment()
            self.assertIsInstance(service.quotas,RedisQuotas)
            self.assertEqual(service.quotas.url,'https://redis.example.com')

    def test_shared_redis_contract_and_failure(self):
        calls = []
        def opener(request,timeout):
            calls.append(request)
            return Response(b'{"result":1}')
        quotas = RedisQuotas('https://redis.example.com','redis-secret','a'*32,opener)
        quotas.reserve('203.0.113.1',INSTALL,1000,30,30,6)
        command = json.loads(calls[0].data)
        self.assertEqual(command[0],'EVAL')
        self.assertEqual(command[2],4)
        self.assertTrue(all(k.startswith('{mealocr}:') for k in command[3:7]))
        self.assertNotIn(INSTALL, calls[0].data.decode())
        self.assertNotIn('203.0.113.1', calls[0].data.decode())
        quotas.opener = lambda *a,**k: Response(b'{"result":0}')
        with self.assertRaises(ServiceError) as raised:
            quotas.reserve('ip',INSTALL,1000,30,30,6)
        self.assertEqual(raised.exception.status,429)
        quotas.opener = lambda *a,**k: Response(b'{"error":"redis-secret"}')
        with self.assertRaises(ServiceError) as raised:
            quotas.reserve('ip',INSTALL,1000,30,30,6)
        self.assertEqual(raised.exception.status,503)
        self.assertNotIn('redis-secret',str(raised.exception))

if __name__ == '__main__':
    unittest.main()
