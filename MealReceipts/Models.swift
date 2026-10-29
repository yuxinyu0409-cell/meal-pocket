import Foundation

enum MealKind: String, Codable, CaseIterable, Identifiable {
    case delivery = "外卖", dineIn = "堂食"
    var id: String { rawValue }
    var symbol: String { self == .delivery ? "bicycle" : "fork.knife" }
}
struct ReceiptAttachment: Identifiable, Codable, Equatable {
    var id = UUID()
    var filename: String
    var hash: String
    var text: String
    var recognitionNotice: String? = nil
}
struct MealRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var merchant: String = ""
    var date: Date? = nil
    var amountCents: Int? = nil
    var kind: MealKind = .delivery
    var note: String = ""
    var recognitionIssues: [String]?
    var confirmed = false
    var attachments: [ReceiptAttachment] = []
    var createdAt = Date()
    var deletedAt: Date? = nil
    var isValid: Bool { date != nil && amountCents != nil && (amountCents ?? -1) >= 0 && !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !attachments.isEmpty }
    var reviewReasons: [String] {
        var reasons = recognitionIssues ?? []
        if merchant.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { reasons.append("商家未识别") }
        if date == nil && !reasons.contains("消费日期有冲突") { reasons.append("消费日期未识别") }
        if amountCents == nil && !reasons.contains("实付金额有冲突") { reasons.append("实付金额未识别") }
        if attachments.isEmpty { reasons.append("缺少原图") }
        return reasons
    }
    var title: String { merchant.isEmpty ? "待填写商家" : merchant }
}
struct ExportRecord: Identifiable, Codable {
    var id = UUID()
    var createdAt = Date()
    var month: String
    var records: [MealRecord]
    var pdfFilename: String
    var pageFilenames: [String]
    var spreadsheetFilename: String?
    var invoiceFiles: [InvoiceFile]?
    var profile: PersonalProfile?
    var lodgingCents: [String:Int]?
    var dayTimes: [String:String]?
    var reimbursementCents: Int?
    var submitted = false
    var total: Int { reimbursementCents ?? records.reduce(0) { $0 + ($1.amountCents ?? 0) } }
    var filenames: [String] { [pdfFilename] + pageFilenames + [spreadsheetFilename].compactMap { $0 } + (invoiceFiles ?? []).map(\.filename) }
}
struct Archive: Codable {
    var version = 1
    var meals: [MealRecord] = []
    var exports: [ExportRecord] = []
    var profile: PersonalProfile?
    var lodgingCents: [String:Int]?
    var dayTimes: [String:String]?
    var invoices: [InvoiceFile]?
}
struct Backup: Codable {
    var version = 1
    var archive: Archive
    var files: [String: Data]
}
enum Money {
    static func cents(_ input: String) -> Int? {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of:"¥",with:"").replacingOccurrences(of:"￥",with:"").replacingOccurrences(of:",",with:"")
        guard clean.range(of: #"^\d{1,7}(\.\d{1,2})?$"#, options:.regularExpression) != nil,
              let decimal = Decimal(string:clean,locale:Locale(identifier:"en_US_POSIX")) else { return nil }
        return NSDecimalNumber(decimal:decimal * 100).intValue
    }
    static func text(_ cents: Int?) -> String {
        guard let cents else { return "待确认" }
        return String(format:"¥%d.%02d",cents / 100,cents % 100)
    }
    static func editable(_ cents: Int?) -> String { cents.map { String(format:"%d.%02d",$0 / 100,$0 % 100) } ?? "" }
}
struct ParsedReceipt { var merchant = ""; var date: Date?; var amountCents: Int?; var dateConflict = false; var amountConflict = false }
enum ReceiptParser {
    static func parse(_ text: String) -> ParsedReceipt {
        let lines = text.components(separatedBy:.newlines).filter { !$0.trimmingCharacters(in:.whitespaces).isEmpty }
        var result = ParsedReceipt()
        let labelsToSkip = ["订单","支付","付款","实付","实收","金额","合计","总计","优惠","交易","商品","取餐码"]
        result.merchant = lines.first { line in
            line.count >= 2 && line.count < 35 && line.rangeOfCharacter(from:.letters) != nil && !labelsToSkip.contains(where:line.contains) && !["美团","美团外卖","饿了么","小票","已完成","已送达","欢迎光临","感谢惠顾","消费凭证","晚餐消费凭证"].contains(line) && line.range(of:#"^\s*20\d{2}[-/.年]"#,options:.regularExpression) == nil
        } ?? ""
        var dates: [String:Date] = [:]
        if let regex = try? NSRegularExpression(pattern:#"20\d{2}[-/.年]\d{1,2}[-/.月]\d{1,2}日?"#) {
            for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)) {
                guard let range = Range(match.range,in:text) else { continue }
                let digits = String(text[range]).components(separatedBy:CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap(Int.init)
                guard digits.count == 3 else { continue }
                let comps = DateComponents(year:digits[0],month:digits[1],day:digits[2],hour:12)
                let calendar = Calendar.current
                if let date = calendar.date(from:comps), calendar.component(.year,from:date) == digits[0], calendar.component(.month,from:date) == digits[1], calendar.component(.day,from:date) == digits[2] { dates[Reimbursement.day(date)] = date }
            }
        }
        result.dateConflict = dates.count > 1
        result.date = dates.count == 1 ? dates.values.first : nil
        for labels in [["实付款","实付金额","实际支付","实际付款","支付金额","实收金额","实收","实付","已支付"],["合计","总计","应付"]] {
            var amounts:Set<Int> = []
            for (index,line) in lines.enumerated() {
                guard let label = labels.first(where:line.contains), let labelRange = line.range(of:label) else { continue }
                let suffix = String(line[labelRange.upperBound...])
                if let amount = labeledAmount(suffix) { amounts.insert(amount) }
                else if index+1 < lines.count, let amount = labeledAmount(lines[index+1]) { amounts.insert(amount) }
            }
            if !amounts.isEmpty {
                result.amountConflict = amounts.count > 1
                result.amountCents = amounts.count == 1 ? amounts.first : nil
                break
            }
        }
        return result
    }
    private static func labeledAmount(_ value:String) -> Int? {
        let value = value.replacingOccurrences(of:",",with:"")
        guard let regex = try? NSRegularExpression(pattern:#"^[\s:：¥￥人民币元]*(\d{1,7}(?:\.\d{1,2})?)(?![\d.:/年月日-])"#),
              let match = regex.firstMatch(in:value,range:NSRange(value.startIndex...,in:value)), let range = Range(match.range(at:1),in:value) else { return nil }
        return Money.cents(String(value[range]))
    }
}
enum ReportLayout {
    static func sliceHeights(width:Double,height:Double,pageWidth:Double,pageHeight:Double) -> [Double] {
        guard width > 0, height > 0, pageWidth > 0, pageHeight > 0 else { return [] }
        let scale = min(pageWidth / width, 1.5)
        let sourcePage = pageHeight / scale
        return stride(from:0.0,to:height,by:sourcePage).map { min(sourcePage,height - $0) }
    }
}

struct PersonalProfile: Codable, Equatable {
    var name = ""
    var department = ""
    var complete: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !department.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
struct InvoiceFile: Identifiable, Codable, Equatable {
    var id = UUID()
    var month: String
    var filename: String
    var displayName: String
}
enum Reimbursement {
    // One entry per local calendar date, shared by every receipt on that day.
    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year,.month,.day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func month(_ date: Date) -> String { String(day(date).prefix(7)) }
    static func groups(_ records: [MealRecord]) -> [(String,[MealRecord])] {
        Dictionary(grouping: records.filter { $0.date != nil }, by: { day($0.date!) }).sorted { $0.key < $1.key }.map { ($0.key,$0.value) }
    }
    static func total(_ records: [MealRecord]) -> Int {
        groups(records).reduce(0) { $0 + min(3000, $1.1.reduce(0) { $0 + max(0,$1.amountCents ?? 0) }) }
    }
    static func validTime(_ value: String) -> Bool {
        value.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil
    }
}

// Complete OCR results are admitted immediately. Missing or conflicting fields need attention.
enum ReceiptAdmission {
    static func apply(to record: inout MealRecord) {
        let fields = record.attachments.map { ReceiptParser.parse($0.text) }
        record.merchant = fields.map(\.merchant).first { !$0.isEmpty } ?? ""
        let dates = Dictionary(grouping:fields.compactMap(\.date),by:Reimbursement.day)
        let amounts = Set(fields.compactMap(\.amountCents))
        record.date = dates.count == 1 ? dates.values.first?.first : nil
        record.amountCents = amounts.count == 1 ? amounts.first : nil
        var issues = Array(Set(record.attachments.compactMap(\.recognitionNotice))).sorted()
        if dates.count > 1 || fields.contains(where: \.dateConflict) { issues.append("消费日期有冲突") }
        if amounts.count > 1 || fields.contains(where: \.amountConflict) { issues.append("实付金额有冲突") }
        record.recognitionIssues = issues
        record.confirmed = record.isValid && record.reviewReasons.isEmpty
    }
}

enum ReportSelection {
    static func reconcile(current:Set<UUID>, eligible:[MealRecord], submitted:Set<UUID>, userChanged:Bool) -> Set<UUID> {
        let available = Set(eligible.map(\.id))
        return userChanged ? current.intersection(available) : available.subtracting(submitted)
    }
}
