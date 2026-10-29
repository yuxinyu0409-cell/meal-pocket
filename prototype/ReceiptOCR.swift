import Foundation
import Vision
import ImageIO

@main struct ReceiptOCR {
    static func main() {
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard !data.isEmpty, data.count <= 8_000_000 else { throw NSError(domain:"ReceiptOCR",code:1) }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans","en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(data:data).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator:"\n")
            let parsed = ReceiptParser.parse(text)
            var result: [String:Any] = ["merchant":parsed.merchant,"text":text]
            if let date = parsed.date { result["date"] = Reimbursement.day(date) }
            // A clear paid label takes precedence; competing amounts remain for manual confirmation.
            let paidLabels = ["实付款","实付金额","实际支付","实际付款","支付金额","实收金额","实收","实付","已支付"]
            let totalLabels = ["合计","总计","应付"]
            var amounts: [Int] = []
            var source = "paid"
            for labels in [paidLabels,totalLabels] {
                for (index,line) in lines.enumerated() {
                    guard let label = labels.first(where:line.contains), let range = line.range(of:label) else { continue }
                    let suffix = String(line[range.upperBound...])
                    var value = money(suffix)
                    if value == nil && index + 1 < lines.count { value = money(lines[index+1]) }
                    if let value { amounts.append(value) }
                }
                if !amounts.isEmpty { break }; source = "total"
            }
            let candidates = Array(Set(amounts)).sorted()
            result["candidates"] = candidates
            if candidates.count == 1 { result["amountCents"] = candidates[0]; result["amountSource"] = source }
            let output = try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
            FileHandle.standardOutput.write(output)
        } catch {
            FileHandle.standardOutput.write(Data("{\"error\":\"无法识别这张图片，请手动补填\"}".utf8))
        }
    }
    static func money(_ value:String) -> Int? {
        let cleaned = value.replacingOccurrences(of:",",with:"").trimmingCharacters(in:.whitespaces)
        guard let regex = try? NSRegularExpression(pattern:#"^[\s:：¥￥人民币元]*(\d{1,7}(?:\.\d{1,2})?)(?![\d.:/年月日-])"#),
              let match = regex.firstMatch(in:cleaned,range:NSRange(cleaned.startIndex...,in:cleaned)),
              let range = Range(match.range(at:1),in:cleaned) else { return nil }
        return Money.cents(String(cleaned[range]))
    }
}
