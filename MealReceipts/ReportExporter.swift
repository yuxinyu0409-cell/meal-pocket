import UIKit
import PDFKit

// Rendering uses a background task; only the final archive update touches the main actor.
enum ReportExporter {
    static let size = CGSize(width:595,height:842)
    @MainActor static func render(records:[MealRecord],month:String,store:ReceiptStore) async throws -> ExportRecord {
        guard let profile = store.archive.profile, profile.complete else { throw AppError.message("请先在个人资料填写姓名和部门。") }
        let times = store.archive.dayTimes ?? [:]
        for (day,_) in Reimbursement.groups(records) where !Reimbursement.validTime(times[day] ?? "") { throw AppError.message("请补填\(day)的加班结束时间。") }
        let invoices = (store.archive.invoices ?? []).filter { $0.month == records.first?.date.map(Reimbursement.month) }
        let lodging = store.archive.lodgingCents ?? [:]
        let root = store.root
        let report = try await Task.detached(priority:.userInitiated) {try renderFiles(records:records,month:month,root:root,profile:profile,times:times,invoices:invoices,lodging:lodging)}.value
        do {try store.addExport(report); return report}
        catch {for name in report.filenames.filter({ !(report.invoiceFiles ?? []).map(\.filename).contains($0) }) {try? FileManager.default.removeItem(at:root.appendingPathComponent(name))}; throw error}
    }
    static func package(_ report:ExportRecord,root:URL) throws -> URL {
        var files = [(report.pdfFilename,"\(report.month)餐费票据.pdf")]
        if let name = report.spreadsheetFilename { files.append((name,"\(report.month)报销明细.xlsx")) }
        files += (report.invoiceFiles ?? []).enumerated().map {
            ($0.element.filename,"发票\($0.offset+1)-\(URL(fileURLWithPath:$0.element.displayName).lastPathComponent)")
        }
        let entries = try files.map { source,name in (name,try Data(contentsOf:root.appendingPathComponent(source))) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("报销包-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let url = directory.appendingPathComponent("\(report.month)报销包.zip")
        do { try BinaryZIP.archive(entries).write(to:url,options:.atomic); return url }
        catch { try? FileManager.default.removeItem(at:directory); throw error }
    }
    private static func renderFiles(records:[MealRecord],month:String,root:URL,profile:PersonalProfile,times:[String:String],invoices:[InvoiceFile],lodging:[String:Int]) throws -> ExportRecord {
        guard !records.isEmpty else {throw AppError.message("请至少选择一笔已确认消费。")}
        let ordered = records.sorted {
            if $0.kind != $1.kind { return $0.kind == .delivery }
            return ($0.date ?? $0.createdAt) < ($1.date ?? $1.createdAt)
        }
        for record in ordered {
            guard record.confirmed && record.isValid else {throw AppError.message("有记录尚未确认或材料不完整。")}
            for a in record.attachments {
                let valid = autoreleasepool {UIImage(contentsOfFile:root.appendingPathComponent(a.filename).path) != nil}
                guard valid else {throw AppError.message("\(record.title) 有原图缺失，请补图后重试。")}
            }
        }
        var report = ExportRecord(month:month,records:ordered,pdfFilename:"report-\(UUID().uuidString).pdf",pageFilenames:[])
        report.lodgingCents = lodging; report.profile = profile; report.dayTimes = times; report.invoiceFiles = invoices
        report.reimbursementCents = Reimbursement.total(records) + Reimbursement.groups(records).reduce(0) { $0 + (lodging[$1.0] ?? 0) }
        report.spreadsheetFilename = "detail-\(report.id).xlsx"
        var written:[URL] = []
        do {
            for invoice in invoices { guard FileManager.default.fileExists(atPath:root.appendingPathComponent(invoice.filename).path) else { throw AppError.message("发票原件缺失，请重新添加。") } }
            let workbookURL = root.appendingPathComponent(report.spreadsheetFilename!)
            try SpreadsheetExporter.workbook(records:ordered,profile:profile,times:times,lodging:lodging).write(to:workbookURL,options:.atomic)
            written.append(workbookURL)
            let pdfURL = root.appendingPathComponent(report.pdfFilename)
            let renderer = UIGraphicsPDFRenderer(bounds:CGRect(origin:.zero,size:size))
            try renderer.writePDF(to:pdfURL) {context in
                for kind in MealKind.allCases {
                    let receipts = ordered.filter { $0.kind == kind }.flatMap { record in
                        record.attachments.enumerated().map { (record, $0.offset, $0.element) }
                    }
                    for (slot,item) in receipts.enumerated() {
                        let (record,index,attachment) = item
                        if slot % 4 == 0 {
                            context.beginPage()
                            drawTitle(kind == .delivery ? "外卖截图" : "堂食小票",subtitle:"\(month) · \(profile.name) · \(profile.department) · 申请报销 \(Money.text(report.total))")
                        }
                        autoreleasepool {
                            let image = UIImage(contentsOfFile:root.appendingPathComponent(attachment.filename).path)!.normalized
                            let column = slot % 2
                            let row = (slot % 4) / 2
                            let cell = CGRect(x:36 + CGFloat(column)*269,y:123 + CGFloat(row)*341,width:254,height:327)
                            let imageBox = CGRect(x:cell.minX,y:cell.minY,width:cell.width,height:286)
                            let scale = min(imageBox.width/image.size.width,imageBox.height/image.size.height)
                            let target = CGRect(x:imageBox.midX-image.size.width*scale/2,y:imageBox.minY,width:image.size.width*scale,height:image.size.height*scale)
                            image.draw(in:target)
                            draw(record.title,rect:CGRect(x:cell.minX,y:cell.minY+291,width:cell.width,height:16),font:.boldSystemFont(ofSize:10))
                            draw("\(record.date!.formatted(date:.numeric,time:.omitted)) · \(Money.text(record.amountCents)) · 凭证 \(index+1)/\(record.attachments.count)",rect:CGRect(x:cell.minX,y:cell.minY+309,width:cell.width,height:16),font:.systemFont(ofSize:9),color:.darkGray)
                        }
                    }
                }
            }
            written.append(pdfURL)
            guard let document = PDFDocument(url:pdfURL) else {throw AppError.message("生成 PDF 失败。")}
            for index in 0..<document.pageCount {
                try autoreleasepool {
                    guard let page = document.page(at:index) else {throw AppError.message("读取 PDF 页面失败。")}
                    let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
                    let png = UIGraphicsImageRenderer(size:size,format:format).pngData {ctx in
                        UIColor.white.setFill(); ctx.fill(CGRect(origin:.zero,size:size)); ctx.cgContext.translateBy(x:0,y:size.height); ctx.cgContext.scaleBy(x:1,y:-1); page.draw(with:.mediaBox,to:ctx.cgContext)
                    }
                    let name = "page-\(report.id)-\(index+1).png"; let url = root.appendingPathComponent(name)
                    try png.write(to:url,options:.atomic); written.append(url); report.pageFilenames.append(name)
                }
            }
            return report
        } catch {for url in written {try? FileManager.default.removeItem(at:url)}; throw error}
    }
    private static func drawTitle(_ title:String,subtitle:String) {
        draw(title,rect:CGRect(x:36,y:38,width:523,height:39),font:.boldSystemFont(ofSize:25))
        draw(subtitle,rect:CGRect(x:36,y:82,width:523,height:23),font:.systemFont(ofSize:12),color:.darkGray)
    }
    private static func draw(_ text:String,rect:CGRect,font:UIFont,color:UIColor = .black) {
        (text as NSString).draw(in:rect,withAttributes:[.font:font,.foregroundColor:color])
    }
}
