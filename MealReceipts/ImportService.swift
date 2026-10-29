import Foundation
import UIKit
import Vision

struct ImportService {
    @MainActor static func importImages(_ images:[Data], group:Bool, kind:MealKind, store:ReceiptStore,
                                        recognize:((Data) async -> String)? = nil,
                                        progress:(String) -> Void = { _ in }) async throws -> [MealRecord] {
        var current = MealRecord(kind:kind)
        var imported:[MealRecord] = []
        for (index,data) in images.enumerated() {
            progress("保存并识别 \(index+1)/\(images.count)")
            if !group { current = MealRecord(kind:kind) }
            var attachment = try store.addImage(data)
            current.attachments.append(attachment); current.confirmed = false
            // Original first: even failed or interrupted OCR leaves a recoverable record.
            try store.save(current)
            if let recognize { attachment.text = await recognize(data) }
            else {
                let result = await recognizeWithFallback(data)
                attachment.text = result.text; attachment.recognitionNotice = result.notice
            }
            current.attachments[current.attachments.count-1] = attachment
            ReceiptAdmission.apply(to:&current)
            if !store.duplicates(for:current.attachments,excluding:current.id).isEmpty {
                current.recognitionIssues = (current.recognitionIssues ?? []) + ["凭证与已有票据重复"]
                current.confirmed = false
            }
            try store.save(current)
            if group { imported = [current] } else { imported.append(current) }
        }
        return imported
    }

    static func recognize(_ data: Data) async -> String {
        await recognizeWithFallback(data).text
    }

    static func recognizeWithFallback(_ data:Data, cloudEnabled:Bool = OCRConfiguration.cloudEnabled,
                                      endpoint:URL? = OCRConfiguration.endpoint) async -> (text:String, notice:String?) {
        do {
            if cloudEnabled {
                guard let endpoint else { throw DeepSeekFailure.unconfigured }
                guard let image = UIImage(data:data) else { throw DeepSeekFailure.invalidResponse }
                let maxSide = max(image.size.width,image.size.height)
                guard maxSide > 0 else { throw DeepSeekFailure.invalidResponse }
                var scale = min(1, 8000 / maxSide)
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                var jpeg:Data?
                // Bound both dimensions and upload size; keep the original attachment unchanged.
                for _ in 0..<5 {
                    let size = CGSize(width:max(1,image.size.width * scale),height:max(1,image.size.height * scale))
                    let rendered = UIGraphicsImageRenderer(size:size,format:format).image { _ in image.draw(in:CGRect(origin:.zero,size:size)) }
                    for quality in [0.9, 0.75, 0.6] {
                        if let candidate = rendered.jpegData(compressionQuality:quality), candidate.count <= 4_000_000 {
                            jpeg = candidate; break
                        }
                    }
                    if jpeg != nil { break }
                    scale *= 0.7
                }
                guard let jpeg else { throw DeepSeekFailure.oversized }
                return (try await ReceiptOCRClient.recognize(jpeg:jpeg,endpoint:endpoint,installationID:OCRConfiguration.installationID),nil)
            }
        } catch {
            let reason = (error as? DeepSeekFailure)?.localizedDescription ?? "云端识别连接异常"
            return (await recognizeOffline(data),reason + "，已使用离线识别，请核对")
        }
        return (await recognizeOffline(data),nil)
    }

    static func recognizeOffline(_ data: Data) async -> String {
        await Task.detached(priority:.userInitiated) {
            guard let image = UIImage(data:data), let cgImage = image.normalized.cgImage else { return "" }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans","en-US"]
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage:cgImage).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator:"\n")
            } catch { return "" }
        }.value
    }
}
extension UIImage {
    var normalized: UIImage {
        if imageOrientation == .up { return self }
        return UIGraphicsImageRenderer(size:size).image { _ in draw(in:CGRect(origin:.zero,size:size)) }
    }
}
