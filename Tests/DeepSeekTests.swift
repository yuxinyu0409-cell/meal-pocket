import Foundation

final class StubProtocol: URLProtocol {
    static var status = 200
    static var responseBody = Data()
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        assert(request.url?.absoluteString == "https://ocr.example.com/api/recognize")
        assert(request.value(forHTTPHeaderField:"Authorization") == nil)
        assert(request.value(forHTTPHeaderField:"Content-Type") == "image/jpeg")
        assert(UUID(uuidString:request.value(forHTTPHeaderField:"X-Installation-ID") ?? "") != nil)
        if let body = request.httpBody { assert(body == Data([0xff,0xd8,0xff])) }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:Self.status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct DeepSeekTests {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration:config)
        let endpoint = OCRConfiguration.endpoint(baseURL:"https://ocr.example.com")!
        let installation = UUID().uuidString
        func recognize() async throws -> String {
            try await ReceiptOCRClient.recognize(jpeg:Data([0xff,0xd8,0xff]),endpoint:endpoint,installationID:installation,session:session)
        }
        for invalidURL in ["", "http://ocr.example.com", "https://user:password@ocr.example.com", "https://ocr.example.com?secret=1", "https://ocr.example.com/path", "$(MEAL_OCR_BASE_URL)"] {
            assert(OCRConfiguration.endpoint(baseURL:invalidURL) == nil)
        }
        StubProtocol.responseBody = Data(#"{"merchant":"测试餐厅","date":"2026-10-29","amount":"28.50"}"#.utf8)
        let text = try await recognize()
        let parsed = ReceiptParser.parse(text)
        assert(parsed.merchant == "测试餐厅" && parsed.amountCents == 2850 && parsed.date != nil)
        for invalid in [#"{"merchant":null,"date":null,"amount":null}"#, #"{"merchant":"测试餐厅","date":"2026-02-31","amount":"28.50"}"#, #"{"merchant":"测试餐厅","date":null,"amount":"-1.00"}"#, #"{"merchant":"测试餐厅","date":null,"amount":28.5}"#, "not json"] {
            StubProtocol.responseBody = Data(invalid.utf8)
            do { _ = try await recognize(); assertionFailure("Accepted invalid response") } catch {}
        }
        StubProtocol.responseBody = Data(#"{"merchant":"测试餐厅","date":null,"amount":null}"#.utf8)
        let partial = try await recognize()
        assert(ReceiptParser.parse(partial).amountCents == nil)
        for status in [401,402,413,429,500,503] {
            StubProtocol.status = status
            do { _ = try await recognize(); assertionFailure("Accepted HTTP failure") }
            catch DeepSeekFailure.http(let actual) { assert(actual == status) }
        }
        let before = StubProtocol.requests
        do {
            _ = try await ReceiptOCRClient.recognize(jpeg:Data(repeating:0,count:4_000_001),endpoint:endpoint,installationID:installation,session:session)
            assertionFailure("Accepted oversized upload")
        } catch DeepSeekFailure.oversized {}
        assert(StubProtocol.requests == before)
        var meal = MealRecord()
        meal.attachments = [ReceiptAttachment(filename:"test",hash:"hash",text:text,recognitionNotice:"连接失败，已使用离线识别，请核对")]
        ReceiptAdmission.apply(to:&meal)
        assert(meal.isValid && !meal.confirmed && meal.reviewReasons.contains("连接失败，已使用离线识别，请核对"))
        let old = Data(#"{"id":"00000000-0000-0000-0000-000000000001","filename":"test","hash":"hash","text":""}"#.utf8)
        let legacy = try JSONDecoder().decode(ReceiptAttachment.self,from:old)
        assert(legacy.recognitionNotice == nil)
        print("PASS: managed OCR HTTPS/raw JPEG contract, no API key, response validation, partial fields, HTTP failures, upload limit, fallback review, legacy attachment decoding")
    }
}
