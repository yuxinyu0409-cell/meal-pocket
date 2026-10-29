#if DEBUG
import UIKit
import PDFKit

@MainActor enum DebugChecks {
    static func run() async {
        let base = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let output = base.appendingPathComponent("self-test-result.txt")
        do {
            let store = ReceiptStore(root:base.appendingPathComponent("SelfTest-\(UUID())"))
            let image = UIGraphicsImageRenderer(size:CGSize(width:600,height:2400)).image { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(x:0,y:0,width:600,height:2400))
                let rows = ["示例餐厅 / SAMPLE RECEIPT","2026-10-27 12:30","实付款 ¥28.50"] + (1...35).map {"商品明细 \($0)  ¥1.00"} + ["凭证末尾 END OF RECEIPT"]
                for (i,row) in rows.enumerated() { (row as NSString).draw(at:CGPoint(x:25,y:25+i*60),withAttributes:[.font:UIFont.systemFont(ofSize:28),.foregroundColor:UIColor.black]) }
            }
            try store.saveProfile(PersonalProfile(name:"测试本人",department:"测试部门"))
            let data = image.pngData()!
            var attachment = try store.addImage(data)
            attachment.text = await ImportService.recognizeOffline(data)
            // No network or paid requests during self-test, even in a configured build.
            let fallback = await ImportService.recognizeWithFallback(data,cloudEnabled:true,endpoint:nil)
            guard fallback.notice != nil, ReceiptParser.parse(fallback.text).amountCents == 2850 else { throw AppError.message("Unavailable backend must fall back to real Vision OCR") }
            let offline = await ImportService.recognizeWithFallback(data,cloudEnabled:false,endpoint:nil)
            guard offline.notice == nil, ReceiptParser.parse(offline.text).amountCents == 2850 else { throw AppError.message("Offline opt-out must avoid backend and retain OCR") }
            let fields = ReceiptParser.parse(attachment.text)
            guard fields.amountCents == 2850, fields.date != nil else {throw AppError.message("OCR failed: \(attachment.text)")}
            // Exercise the same real image import service used by Photos and the camera.
            let imported = try await ImportService.importImages([data],group:false,kind:.delivery,store:store,recognize:ImportService.recognizeOffline)
            guard imported.count == 1, imported[0].confirmed, imported[0].amountCents == 2850 else { throw AppError.message("Complete OCR must auto-admit without confirmation") }
            var meal = imported[0]
            guard store.archive.dayTimes?[Reimbursement.day(meal.date!)] == nil else { throw AppError.message("Admission must not require an end time") }
            try store.save(meal,endTime:"22:05")
            let duplicate = try await ImportService.importImages([data],group:false,kind:.delivery,store:store,recognize:ImportService.recognizeOffline)
            guard !duplicate[0].confirmed, duplicate[0].reviewReasons.contains("凭证与已有票据重复") else { throw AppError.message("Duplicate image must not silently double the reimbursement") }
            try store.trash(duplicate[0])
            let incomplete = try await ImportService.importImages([data],group:false,kind:.dineIn,store:store,recognize:{ _ in "示例餐厅\n2026-10-27" })
            guard !incomplete[0].confirmed, incomplete[0].reviewReasons.contains("实付金额未识别"), store.image(incomplete[0].attachments[0]) != nil else { throw AppError.message("Failed OCR must retain image and queue missing fields") }
            try store.trash(incomplete[0])
            let conflicting = try await ImportService.importImages([data,data],group:true,kind:.delivery,store:store,recognize:{ _ in "示例餐厅\n2026-10-27\n实付款 ¥28.50\n实付款 ¥36.50" })
            guard !conflicting[0].confirmed, conflicting[0].reviewReasons.contains("实付金额有冲突") else { throw AppError.message("Conflicting OCR must queue for manual completion") }
            try store.trash(conflicting[0])
            let reloaded = ReceiptStore(root:store.root)
            guard reloaded.meals.count == 1, reloaded.meals[0].amountCents == 2850 else {throw AppError.message("Persistence failed")}
            guard store.duplicates(for:[attachment]).count == 1 else {throw AppError.message("Duplicate test failed")}
            let sameDate = MealRecord(merchant:"同日",date:meal.date,amountCents:1000)
            try store.save(sameDate,endTime:"23:10")
            guard store.archive.dayTimes?[Reimbursement.day(meal.date!)] == "23:10" else { throw AppError.message("Shared day time failed") }
            try store.trash(sameDate)
            let invoiceURL = base.appendingPathComponent("测试发票.pdf")
            try UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:595,height:842)).writePDF(to:invoiceURL) { context in context.beginPage(); ("测试发票" as NSString).draw(at:CGPoint(x:30,y:30),withAttributes:[.font:UIFont.systemFont(ofSize:20)]) }
            try store.importInvoice(invoiceURL,month:Reimbursement.month(meal.date!))
            var missing = meal; missing.date = Calendar.current.date(byAdding:.day,value:3,to:meal.date!)
            var missingBlocked = false
            do { _ = try await ReportExporter.render(records:[missing],month:"测试",store:store) } catch { missingBlocked = true }
            guard missingBlocked else { throw AppError.message("Missing end time must block export") }
            let report = try await ReportExporter.render(records:[meal],month:"2026年10月",store:store)
            guard let pdf = PDFDocument(url:store.file(report.pdfFilename)), pdf.pageCount == 1, report.pageFilenames.count == pdf.pageCount else {throw AppError.message("Pagination failed")}
            // Text extracted from a PDF does not prove its receipt bitmap survived export.
            // Recognize the rendered evidence page, which is also what the preview displays.
            let evidence = pdf.page(at:0)!.thumbnail(of:CGSize(width:3570,height:5052),for:.mediaBox)
            let evidenceText = await ImportService.recognizeOffline(evidence.pngData()!)
            guard evidenceText.contains("SAMPLE RECEIPT"), evidenceText.contains("28.50") else {
                throw AppError.message("Exported PDF evidence page must contain the original receipt image")
            }
            let previewView = PDFView()
            previewView.document = PDFDocument(url:store.file(report.pdfFilename))
            guard previewView.document?.pageCount == pdf.pageCount else { throw AppError.message("PDF preview must load all exported pages") }
            guard report.invoiceFiles?.count == 1, let originalInvoice = store.archive.invoices?.first else { throw AppError.message("Invoice not included") }
            try store.removeInvoice(originalInvoice)
            guard FileManager.default.fileExists(atPath:store.file(report.invoiceFiles![0].filename).path) else { throw AppError.message("Invoice snapshot was removed") }
            meal.amountCents = 9000; try store.save(meal)
            guard store.archive.exports[0].total == 2850 else {throw AppError.message("Snapshot changed")}
            try store.trash(meal); guard store.meals.isEmpty else {throw AppError.message("Trash failed")}
            try store.restore(meal); guard store.meals.count == 1 else {throw AppError.message("Restore failed")}
            let backupURL = try store.backupURL()
            let restored = ReceiptStore(root:base.appendingPathComponent("RestoreTest-\(UUID())"))
            try restored.importBackup(backupURL)
            guard restored.meals.count == 1, restored.archive.exports.count == 1, restored.archive.profile?.name == "测试本人", restored.archive.dayTimes?[Reimbursement.day(meal.date!)] == "23:10", restored.archive.exports[0].spreadsheetFilename != nil, restored.archive.exports[0].invoiceFiles?.count == 1, restored.image(restored.meals[0].attachments[0]) != nil else {throw AppError.message("Backup restoration failed")}
            var broken = try JSONDecoder().decode(Backup.self,from:Data(contentsOf:backupURL))
            broken.files.removeAll()
            let badURL = base.appendingPathComponent("broken.mealbackup")
            try JSONEncoder().encode(broken).write(to:badURL)
            var rejected = false
            do {try restored.importBackup(badURL)} catch {rejected = true}
            guard rejected,restored.meals.count == 1 else {throw AppError.message("Corrupt backup must be rejected without modifying records")}
            let package = try ReportExporter.package(report,root:store.root)
            try Data(contentsOf:package).write(to:base.appendingPathComponent("self-test-package.zip"))
            let restoredReport = restored.archive.exports[0]
            try restored.removeExport(restoredReport)
            let afterDeletion = ReceiptStore(root:restored.root)
            guard afterDeletion.archive.exports.isEmpty,
                  afterDeletion.meals.count == 1,
                  afterDeletion.image(afterDeletion.meals[0].attachments[0]) != nil,
                  FileManager.default.fileExists(atPath:afterDeletion.file(restoredReport.invoiceFiles![0].filename).path),
                  !FileManager.default.fileExists(atPath:afterDeletion.file(restoredReport.pdfFilename).path),
                  !FileManager.default.fileExists(atPath:afterDeletion.file(restoredReport.spreadsheetFilename!).path),
                  restoredReport.pageFilenames.allSatisfy({ !FileManager.default.fileExists(atPath:afterDeletion.file($0).path) })
            else { throw AppError.message("Deleting export must persist, remove generated files and preserve original receipts/invoices") }
            let small = UIGraphicsImageRenderer(size:CGSize(width:600,height:200)).pngData {ctx in UIColor.white.setFill();ctx.fill(CGRect(x:0,y:0,width:600,height:200));("小票测试" as NSString).draw(at:CGPoint(x:20,y:20),withAttributes:[.font:UIFont.systemFont(ofSize:30)])}
            let sa = try store.addImage(small)
            var two = MealRecord(merchant:"两张小票",date:Date(),amountCents:1000); two.attachments = [sa,sa,sa,sa]; two.confirmed = true
            try store.save(two,endTime:"21:30")
            let compact = try await ReportExporter.render(records:[two],month:"测试月份",store:store)
            guard PDFDocument(url:store.file(compact.pdfFilename))?.pageCount == 1 else {throw AppError.message("Four small receipts should fit on one evidence page")}
            var five = two; five.attachments.append(sa)
            let overflow = try await ReportExporter.render(records:[five],month:"测试月份",store:store)
            guard PDFDocument(url:store.file(overflow.pdfFilename))?.pageCount == 2 else { throw AppError.message("Fifth receipt must start a new page") }
            try store.split(two)
            guard store.meals.filter({$0.title == two.title}).count == 4,store.meals.filter({$0.title == two.title}).allSatisfy({$0.amountCents == nil && !$0.confirmed}) else {throw AppError.message("Split must be atomic and clear duplicated amounts")}
            let parts = store.meals.filter {$0.title == two.title}
            try store.merge(parts[0],into:parts[1].id)
            guard store.meals.filter({$0.title == two.title}).count == 3 else {throw AppError.message("Merge failed")}
            let damagedRoot = base.appendingPathComponent("DamagedTest-\(UUID())")
            try FileManager.default.createDirectory(at:damagedRoot,withIntermediateDirectories:true)
            let damagedIndex = damagedRoot.appendingPathComponent("archive.json")
            try Data("BROKEN INDEX".utf8).write(to:damagedIndex)
            let damagedStore = ReceiptStore(root:damagedRoot)
            var blocked = false
            do {try damagedStore.save(MealRecord())} catch {blocked = true}
            guard blocked,try String(contentsOf:damagedIndex,encoding:.utf8) == "BROKEN INDEX" else {throw AppError.message("Damaged index must not be overwritten")}
            guard let xlsx = report.spreadsheetFilename else { throw AppError.message("Missing workbook") }
            try Data(contentsOf:store.file(xlsx)).write(to:base.appendingPathComponent("self-test-detail.xlsx"))
            try Data(contentsOf:store.file(report.pdfFilename)).write(to:base.appendingPathComponent("self-test-report.pdf"))
            try Data(contentsOf:store.file(report.pageFilenames[0])).write(to:base.appendingPathComponent("self-test-page.png"))
            try "PASS: auto-admission without end time, failed/conflicting OCR queue with original retention, duplicate admission protection, offline OCR, persistence, duplicates, PDF original-image rendering, four receipts per page and fifth-receipt overflow, PNG pages, immutable export snapshot, trash/restore, profile and shared time, workbook snapshot, full backup restore, corrupt backup rejection, compact multi-image pagination, atomic merge/split, corrupt index write protection\n".write(to:output,atomically:true,encoding:.utf8)
        } catch {try? "FAIL: \(error)".write(to:output,atomically:true,encoding:.utf8)}
    }
}
#endif
