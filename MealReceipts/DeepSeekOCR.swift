import Foundation

struct DeepSeekReceipt: Decodable {
    let merchant: String?
    let date: String?
    let amount: String?
    var receiptText: String {
        get throws {
            var lines: [String] = []
            if let merchant, !merchant.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                guard merchant.rangeOfCharacter(from:.newlines) == nil, merchant.count < 100 else { throw DeepSeekFailure.invalidResponse }
                lines.append(merchant)
            }
            if let date {
                guard date.range(of:#"^20\d{2}-\d{2}-\d{2}$"#,options:.regularExpression) != nil,
                      ReceiptParser.parse(date).date != nil else { throw DeepSeekFailure.invalidResponse }
                lines.append(date)
            }
            if let amount {
                guard Money.cents(amount) != nil else { throw DeepSeekFailure.invalidResponse }
                lines.append("实付金额 ¥" + amount)
            }
            guard !lines.isEmpty else { throw DeepSeekFailure.invalidResponse }
            return lines.joined(separator:"\n")
        }
    }
}
enum DeepSeekFailure: LocalizedError {
    case invalidResponse, http(Int), oversized, unconfigured
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "云端返回的票据信息无效"
        case .oversized: return "图片过大，无法发送至识别服务"
        case .unconfigured: return "云端识别服务尚未配置"
        case .http(429): return "识别额度已达上限或服务繁忙"
        case .http: return "云端识别暂时不可用"
        }
    }
}
enum OCRConfiguration {
    static var cloudEnabled:Bool {
        UserDefaults.standard.object(forKey:"cloudOCREnabled") as? Bool ?? true
    }
    static var endpoint:URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey:"MealOCRBaseURL") as? String else { return nil }
        return endpoint(baseURL:value)
    }
    static func endpoint(baseURL:String) -> URL? {
        guard let components = URLComponents(string:baseURL.trimmingCharacters(in:.whitespacesAndNewlines)),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil, components.path.isEmpty || components.path == "/",
              let url = components.url else { return nil }
        return url.appendingPathComponent("api/recognize")
    }
    static var installationID:String {
        if let saved = UserDefaults.standard.string(forKey:"ocrInstallationID"), UUID(uuidString:saved) != nil { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id,forKey:"ocrInstallationID")
        return id
    }
}
enum ReceiptOCRClient {
    static func recognize(jpeg:Data, endpoint:URL, installationID:String, session:URLSession = .shared) async throws -> String {
        guard endpoint.scheme == "https", UUID(uuidString:installationID) != nil else { throw DeepSeekFailure.unconfigured }
        guard jpeg.count <= 4_000_000 else { throw DeepSeekFailure.oversized }
        var request = URLRequest(url:endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue(installationID,forHTTPHeaderField:"X-Installation-ID")
        request.setValue("image/jpeg",forHTTPHeaderField:"Content-Type")
        request.httpBody = jpeg
        let (data,response) = try await session.data(for:request)
        guard let response = response as? HTTPURLResponse else { throw DeepSeekFailure.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw DeepSeekFailure.http(response.statusCode) }
        guard data.count <= 1_000_000 else { throw DeepSeekFailure.invalidResponse }
        return try JSONDecoder().decode(DeepSeekReceipt.self,from:data).receiptText
    }
}
