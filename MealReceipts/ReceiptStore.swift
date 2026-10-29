import Foundation
import UIKit
import CryptoKit
import PDFKit

@MainActor final class ReceiptStore: ObservableObject {
    @Published private(set) var archive = Archive()
    @Published var error: String?
    let root: URL
    private let fm = FileManager.default
    private var loadFailed = false
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("MealReceipts",isDirectory:true)
        do {
            try fm.createDirectory(at:self.root,withIntermediateDirectories:true)
            let url = self.root.appendingPathComponent("archive.json")
            if fm.fileExists(atPath:url.path) { archive = try JSONDecoder().decode(Archive.self,from:Data(contentsOf:url)) }
        } catch { self.loadFailed = true; self.error = "读取本机记录失败：\(error.localizedDescription)。请保留数据，勿卸载应用。" }
    }
    var meals: [MealRecord] { archive.meals.filter { $0.deletedAt == nil }.sorted { ($0.date ?? $0.createdAt) > ($1.date ?? $1.createdAt) } }
    var deleted: [MealRecord] { archive.meals.filter { $0.deletedAt != nil } }
    func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    func image(_ attachment: ReceiptAttachment) -> UIImage? { UIImage(contentsOfFile:file(attachment.filename).path) }
    private func commit(_ next: Archive) throws {
        guard !loadFailed else { throw AppError.message("原有索引读取失败，已阻止写入以保护历史数据。请先导出原始目录以便修复。") }
        let data = try JSONEncoder().encode(next)
        try data.write(to:file("archive.json"),options:.atomic)
        archive = next
    }
    func save(_ meal: MealRecord) throws {
        var next = archive
        if let index = next.meals.firstIndex(where: { $0.id == meal.id }) { next.meals[index] = meal }
        else { next.meals.append(meal) }
        try commit(next)
    }
    func trash(_ meal: MealRecord) throws { var m = meal; m.deletedAt = Date(); try save(m) }
    func restore(_ meal: MealRecord) throws { var m = meal; m.deletedAt = nil; try save(m) }
    func merge(_ source:MealRecord, into targetID:UUID) throws {
        guard source.id != targetID, let targetIndex = archive.meals.firstIndex(where:{$0.id == targetID && $0.deletedAt == nil}) else {throw AppError.message("未找到合并目标。")}
        var next = archive
        next.meals[targetIndex].attachments += source.attachments
        next.meals[targetIndex].confirmed = false
        if let index = next.meals.firstIndex(where:{$0.id == source.id}) {next.meals[index].deletedAt = Date()}
        try commit(next)
    }
    func split(_ source:MealRecord) throws {
        guard source.attachments.count > 1, let index = archive.meals.firstIndex(where:{$0.id == source.id}) else {throw AppError.message("此消费无法拆分。")}
        var next = archive
        next.meals[index].deletedAt = Date()
        for attachment in source.attachments {var record = source; record.id = UUID(); record.attachments = [attachment]; record.confirmed = false; record.amountCents = nil; record.deletedAt = nil; next.meals.append(record)}
        try commit(next)
    }
    func addImage(_ data: Data) throws -> ReceiptAttachment {
        guard UIImage(data:data) != nil else { throw AppError.message("无法读取图片，请使用 JPEG、PNG 或 HEIC 图片。") }
        let hash = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        let name = "image-\(UUID().uuidString).original"
        try data.write(to:file(name),options:.atomic)
        return ReceiptAttachment(filename:name,hash:hash,text:"")
    }
    func duplicates(for attachments: [ReceiptAttachment], excluding: UUID? = nil) -> [MealRecord] {
        let hashes = Set(attachments.map(\.hash))
        return meals.filter { $0.id != excluding && $0.attachments.contains { hashes.contains($0.hash) } }
    }
    func saveProfile(_ profile: PersonalProfile) throws {
        var next = archive; next.profile = profile; try commit(next)
    }
    func save(_ meal: MealRecord, endTime: String, lodgingCents: Int? = nil) throws {
        if !endTime.isEmpty && !Reimbursement.validTime(endTime) { throw AppError.message("结束时间请填写为 HH:mm，例如22:05。") }
        var next = archive
        if let i = next.meals.firstIndex(where: { $0.id == meal.id }) { next.meals[i] = meal } else { next.meals.append(meal) }
        if let date = meal.date { var times = next.dayTimes ?? [:]; times[Reimbursement.day(date)] = endTime.isEmpty ? nil : endTime; next.dayTimes = times }
        if let date = meal.date, let lodgingCents {
            var lodging = next.lodgingCents ?? [:]; lodging[Reimbursement.day(date)] = lodgingCents; next.lodgingCents = lodging
        }
        try commit(next)
    }
    func importInvoice(_ url: URL, month: String) throws {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        guard ["pdf","png","jpg","jpeg","heic"].contains(ext) else { throw AppError.message("发票支持PDF和图片。") }
        let bytes = try Data(contentsOf:url)
        guard !bytes.isEmpty, bytes.count < 50_000_000 else { throw AppError.message("发票为空或超过50MB。") }
        guard ext == "pdf" ? PDFDocument(data:bytes) != nil : UIImage(data:bytes) != nil else { throw AppError.message("发票文件无法读取，请重新选择有效的PDF或图片。") }
        let name = "invoice-\(UUID()).\(ext)"
        try bytes.write(to:file(name),options:.atomic)
        do { var next = archive; next.invoices = (next.invoices ?? []) + [InvoiceFile(month:month,filename:name,displayName:url.lastPathComponent)]; try commit(next) }
        catch { try? fm.removeItem(at:file(name)); throw error }
    }
    func importInvoiceImage(_ data:Data, month:String) throws {
        guard let image = UIImage(data:data), let bytes = image.pngData() else { throw AppError.message("发票图片无法读取。") }
        let temporary = fm.temporaryDirectory.appendingPathComponent("餐饮发票-\(UUID()).png")
        try bytes.write(to:temporary,options:.atomic)
        defer { try? fm.removeItem(at:temporary) }
        try importInvoice(temporary,month:month)
    }
    func removeInvoice(_ invoice: InvoiceFile) throws {
        var next = archive; next.invoices?.removeAll { $0.id == invoice.id }; try commit(next)
        // Export snapshots may still reference the original; retain the file.
    }
    func addExport(_ report: ExportRecord) throws { var next = archive; next.exports.insert(report,at:0); try commit(next) }
    func removeExport(_ report: ExportRecord) throws {
        guard let existing = archive.exports.first(where: { $0.id == report.id }) else { return }
        var next = archive
        next.exports.removeAll { $0.id == report.id }
        // Persist the index first; a failed commit must leave the export usable.
        try commit(next)
        let retained = Set(next.exports.flatMap(\.filenames)
            + next.exports.flatMap { $0.records.flatMap(\.attachments).map(\.filename) }
            + next.meals.flatMap(\.attachments).map(\.filename)
            + (next.invoices ?? []).map(\.filename))
        // Invoice originals are never owned by the export being deleted.
        let generatedFiles = [existing.pdfFilename] + existing.pageFilenames + [existing.spreadsheetFilename].compactMap { $0 }
        for name in generatedFiles where !retained.contains(name) {
            try? fm.removeItem(at:file(name))
        }
    }
    func markSubmitted(_ report: ExportRecord) throws {
        var next = archive
        if let i = next.exports.firstIndex(where: { $0.id == report.id }) { next.exports[i].submitted.toggle() }
        try commit(next)
    }
    func isSubmitted(_ meal: MealRecord) -> Bool { archive.exports.contains { $0.submitted && $0.records.contains(where: { $0.id == meal.id }) } }
    func backupURL() throws -> URL {
        var files: [String:Data] = [:]
        let names = Set((archive.invoices ?? []).map(\.filename) + archive.meals.flatMap(\.attachments).map(\.filename) + archive.exports.flatMap { $0.filenames + $0.records.flatMap(\.attachments).map(\.filename) })
        var bytesTotal = 0
        for name in names {let attributes = try fm.attributesOfItem(atPath:file(name).path); bytesTotal += (attributes[.size] as? NSNumber)?.intValue ?? 0}
        guard bytesTotal < 200_000_000 else {throw AppError.message("当前完整备份超过 200 MB，请先使用电脑文件共享保存原始目录。") }
        for name in names { files[name] = try Data(contentsOf:file(name)) }
        let backup = Backup(archive:archive,files:files)
        let url = fm.temporaryDirectory.appendingPathComponent("餐费完整备份-\(UUID().uuidString.prefix(8)).mealbackup")
        try JSONEncoder().encode(backup).write(to:url,options:.atomic)
        return url
    }
    func importBackup(_ url: URL) throws {
        let allowed = url.startAccessingSecurityScopedResource(); defer { if allowed { url.stopAccessingSecurityScopedResource() } }
        let attributes = try fm.attributesOfItem(atPath:url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 300_000_000 else {throw AppError.message("备份超过 300 MB，请在电脑上拆分后恢复。") }
        let data = try Data(contentsOf:url)
        guard data.count < 300_000_000 else { throw AppError.message("备份过大，请拆分备份。") }
        let backup = try JSONDecoder().decode(Backup.self,from:data)
        guard backup.version == 1 && backup.archive.version == 1 else { throw AppError.message("不支持此备份版本。") }
        let names = Set((backup.archive.invoices ?? []).map(\.filename) + backup.archive.meals.flatMap(\.attachments).map(\.filename) + backup.archive.exports.flatMap { $0.filenames + $0.records.flatMap(\.attachments).map(\.filename) })
        for name in names {
            guard name == URL(fileURLWithPath:name).lastPathComponent, !name.hasPrefix("."), name != "archive.json", let bytes = backup.files[name], !bytes.isEmpty else { throw AppError.message("备份附件不完整，现有数据未修改。") }
        }
        for attachment in backup.archive.meals.flatMap(\.attachments) + backup.archive.exports.flatMap({ $0.records.flatMap(\.attachments) }) {
            guard let bytes = backup.files[attachment.filename], UIImage(data:bytes) != nil, SHA256.hash(data:bytes).map({ String(format:"%02x",$0) }).joined() == attachment.hash else { throw AppError.message("备份图片校验失败，现有数据未修改。") }
        }
        // All imported file names and identifiers are new, so restoring never overwrites local data.
        var mapping: [String:String] = [:]
        var written: [URL] = []
        do {
            for name in names {
                let newName = "restore-\(UUID().uuidString)-\(name)"
                mapping[name] = newName
                let destination = file(newName)
                try backup.files[name]!.write(to:destination,options:.atomic); written.append(destination)
            }
            var next = archive
            var ids: [UUID:UUID] = [:]
            func remap(_ source: MealRecord) -> MealRecord {
                var m = source
                if ids[m.id] == nil { ids[m.id] = UUID() }; m.id = ids[m.id]!
                m.attachments = m.attachments.map { item in var a = item; a.id = UUID(); a.filename = mapping[a.filename]!; return a }
                return m
            }
            next.meals += backup.archive.meals.map(remap)
            next.exports += backup.archive.exports.map { source in
                var e = source; e.id = UUID(); e.records = e.records.map(remap); e.pdfFilename = mapping[e.pdfFilename]!; e.pageFilenames = e.pageFilenames.map { mapping[$0]! }; e.spreadsheetFilename = e.spreadsheetFilename.map { mapping[$0]! }; e.invoiceFiles = e.invoiceFiles?.map { var f = $0; f.id = UUID(); f.filename = mapping[f.filename]!; return f }; return e
            }
            next.invoices = (next.invoices ?? []) + (backup.archive.invoices ?? []).map { var f = $0; f.id = UUID(); f.filename = mapping[f.filename]!; return f }
            if next.profile == nil { next.profile = backup.archive.profile }
            var times = next.dayTimes ?? [:]
            for (key,value) in backup.archive.dayTimes ?? [:] where times[key] == nil { times[key] = value }
            next.dayTimes = times
            var lodging = next.lodgingCents ?? [:]
            for (key,value) in backup.archive.lodgingCents ?? [:] where lodging[key] == nil { lodging[key] = value }
            next.lodgingCents = lodging
            try commit(next)
        } catch { for url in written { try? fm.removeItem(at:url) }; throw error }
    }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let s): return s } }
}
