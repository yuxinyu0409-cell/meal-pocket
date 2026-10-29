import Foundation

// Minimal standards-compliant OOXML workbook; stored ZIP entries need no third-party runtime.
enum SpreadsheetExporter {
    static func workbook(records: [MealRecord], profile: PersonalProfile, times: [String:String], lodging: [String:Int] = [:]) -> Data {
        let headers = ["日期","星期","报销人","部门","加班结束时间","晚餐餐补（元）","住宿费（元）","备注"]
        var rows = [headers.map { Cell.text($0) }]
        for (day, meals) in Reimbursement.groups(records) {
            let date = meals[0].date!
            let weekday = ["周日","周一","周二","周三","周四","周五","周六"][Calendar.current.component(.weekday, from:date)-1]
            rows.append([.text(day),.text(weekday),.text(profile.name),.text(profile.department),.text(times[day] ?? ""),.number(Money.editable(Reimbursement.total(meals))),.number(Money.editable(lodging[day] ?? 0)),.text(meals.map(\.note).filter { !$0.isEmpty }.joined(separator:"；"))])
        }
        rows.append([.text("合计"),.text(""),.text(""),.text(""),.text(""),.number(Money.editable(Reimbursement.total(records))),.number(Money.editable(Reimbursement.groups(records).reduce(0) { $0 + (lodging[$1.0] ?? 0) })),.text("")])
        let sheet = rows.enumerated().map { i,row in
            "<row r=\"\(i+1)\">" + row.enumerated().map { j,cell in
                let ref = "\(String(UnicodeScalar(65+j)!))\(i+1)"
                switch cell {
                case .text(let value): return "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(value))</t></is></c>"
                case .number(let value): return "<c r=\"\(ref)\" s=\"1\"><v>\(value)</v></c>"
                }
            }.joined() + "</row>"
        }.joined()
        return zip([
            ("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/></Types>"),
            ("_rels/.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"),
            ("xl/workbook.xml", "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"晚餐报销明细\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>"),
            ("xl/styles.xml", "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"PingFang SC\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border/></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"2\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/></cellXfs></styleSheet>"),
            ("xl/worksheets/sheet1.xml", "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><cols><col min=\"1\" max=\"8\" width=\"20\" customWidth=\"1\"/></cols><sheetData>\(sheet)</sheetData></worksheet>")
        ])
    }
    private enum Cell { case text(String), number(String) }
    private static func xml(_ text: String) -> String {
        let clean = text.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || ($0.value >= 32 && $0.value != 0xFFFE && $0.value != 0xFFFF) }.map(String.init).joined()
        return clean.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")
    }
    private static func zip(_ files: [(String,String)]) -> Data {
        BinaryZIP.archive(files.map { path,text in
            (path,Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"+text).utf8))
        })
    }
}

// Store entries without recompressing already compressed PDF, XLSX and image files.
enum BinaryZIP {
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB88320 : 0) }
        return crc
    }
    static func archive(_ files: [(String,Data)]) -> Data {
        var output = Data(), central = Data()
        func u16(_ n: Int) -> Data { var value = UInt16(n).littleEndian; return withUnsafeBytes(of:&value) { Data($0) } }
        func u32(_ n: UInt32) -> Data { var value = n.littleEndian; return withUnsafeBytes(of:&value) { Data($0) } }
        for (path,data) in files {
            let name = Data(path.utf8)
            var crc: UInt32 = 0xFFFFFFFF
            for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] }
            crc ^= 0xFFFFFFFF
            let offset = UInt32(output.count), count = UInt32(data.count)
            output += u32(0x04034B50)
            for value in [20,0x0800,0,0,33] { output += u16(value) }
            for value in [crc,count,count] { output += u32(value) }
            output += u16(name.count); output += u16(0); output += name; output += data
            central += u32(0x02014B50)
            for value in [20,20,0x0800,0,0,33] { central += u16(value) }
            for value in [crc,count,count] { central += u32(value) }
            for value in [name.count,0,0,0,0] { central += u16(value) }
            central += u32(0); central += u32(offset); central += name
        }
        let offset = UInt32(output.count)
        output += central
        output += u32(0x06054B50)
        for value in [0,0,files.count,files.count] { output += u16(value) }
        output += u32(UInt32(central.count)); output += u32(offset); output += u16(0)
        return output
    }
}
