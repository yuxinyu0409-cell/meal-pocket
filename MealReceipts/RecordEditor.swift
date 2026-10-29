import SwiftUI
import PhotosUI

struct RecordEditor:View {
    @EnvironmentObject private var store:ReceiptStore
    @Environment(\.dismiss) private var dismiss
    @State var record:MealRecord
    @State private var amount = ""
    @State private var endTime = ""
    @State private var lodging = ""
    @State private var error:String?
    @State private var photos:[PhotosPickerItem] = []
    @State private var busy = false
    @State private var selectedImage:ReceiptAttachment?
    @State private var deleting = false
    @State private var mergeTarget:UUID?
    @State private var discardChanges = false
    private enum Field:Hashable { case merchant,amount,endTime,lodging,note }
    @FocusState private var focusedField:Field?
    @State private var amountEditing = false
    private struct EditorValues:Equatable {
        var record:MealRecord
        var amount:String
        var endTime:String
        var lodging:String
    }
    @State private var initialValues:EditorValues?
    private var editorValues:EditorValues { EditorValues(record:record,amount:amount,endTime:endTime,lodging:lodging) }
    private var hasChanges:Bool { initialValues.map { $0 != editorValues } ?? false }
    private var dailyAllowance:Int? {
        guard let date = record.date, let cents = Money.cents(amount) else { return nil }
        let others = store.meals.filter { $0.id != record.id && $0.confirmed && $0.date.map { Calendar.current.isDate($0,inSameDayAs:date) } == true }
        var current = record; current.amountCents = cents
        return Reimbursement.total(others + [current])
    }
    var isNew = false
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Label(record.confirmed ? "已录入，可计入报销" : "请补全未识别的信息",systemImage:record.confirmed ? "checkmark.seal.fill" : "exclamationmark.circle")
                        .foregroundStyle(record.confirmed ? Color.purple : Color.orange)
                    TextField("商家名称",text:$record.merchant).focused($focusedField,equals:.merchant)
                    HStack {
                        Text("实付金额")
                        Spacer()
                        if amountEditing {
                            TextField("填写实付金额",text:$amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($focusedField,equals:.amount).accessibilityLabel("实付金额")
                        } else {
                            Text(Money.cents(amount).map { Money.text($0) } ?? "未识别").fontWeight(.semibold)
                            Button(amount.isEmpty ? "手动输入" : "修改") { amountEditing = true; focusedField = .amount }.font(.caption).buttonStyle(.borderless)
                        }
                    }
                    if record.date != nil {
                        DatePicker("消费日期",selection:Binding(get:{record.date ?? Date()},set:{record.date = $0}),displayedComponents:.date)
                    } else {
                        Button { record.date = Date() } label: { HStack { Text("消费日期"); Spacer(); Text("待识别 · 手动补填").font(.caption) } }
                    }
                    Picker("消费类型",selection:$record.kind) { ForEach(MealKind.allCases) { Text($0.rawValue).tag($0) } }
                    TextField("备注（选填）",text:$record.note,axis:.vertical).focused($focusedField,equals:.note)
                } header: { Text("消费信息") } footer: { Text("识别仅供参考。识别完整的票据自动录入；这里只需补齐未识别的信息。") }
                if !record.confirmed && !record.reviewReasons.isEmpty { Section { Text(record.reviewReasons.joined(separator:"、")).font(.caption).foregroundStyle(.orange) } }
                Section {
                    HStack { Text("当日晚餐餐补"); Spacer(); Text(dailyAllowance.map { Money.text($0) } ?? "待识别").fontWeight(.semibold) }
                    Text("每日最高30元，同一天合并计算，不重复申报。").font(.caption).foregroundStyle(.secondary)
                } header: { Text("费用申请") }
                Section {
                    TextField("加班结束时间，例如22:05",text:$endTime).keyboardType(.numbersAndPunctuation).focused($focusedField,equals:.endTime)
                    Text("手动填写，同一天的票据共用此时间；可以先保存，月底补齐。").font(.caption).foregroundStyle(.secondary)
                } header: { Text("加班信息") }
                Section {
                    TextField("住宿费（元，选填）",text:$lodging).keyboardType(.decimalPad).focused($focusedField,equals:.lodging)
                    Text("同一天共用一笔住宿费；涉及住宿请在下方补充对应凭证。无则留空。").font(.caption).foregroundStyle(.secondary)
                } header: { Text("住宿费用") }
                Section("凭证 · \(record.attachments.count) 张") {
                    ForEach(record.attachments) { attachment in
                        HStack {
                            if let image = store.image(attachment) { Image(uiImage:image).resizable().scaledToFit().frame(width:58,height:78).onTapGesture { selectedImage = attachment } }
                            else { Image(systemName:"photo.badge.exclamationmark").foregroundStyle(.orange) }
                            VStack(alignment:.leading,spacing:6) {
                                Text("凭证 \((record.attachments.firstIndex(of:attachment) ?? 0)+1)")
                                Text(attachment.text.isEmpty ? "未识别到文字，可手动填写" : attachment.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button { rotate(attachment) } label:{Image(systemName:"rotate.right")}.buttonStyle(.borderless).accessibilityLabel("旋转图片")
                        }
                    }.onDelete { offsets in record.attachments.remove(atOffsets:offsets); record.confirmed = false }
                        .onMove { a,b in record.attachments.move(fromOffsets:a,toOffset:b) }
                    PhotosPicker(selection:$photos,maxSelectionCount:20,matching:.images) { Label(busy ? "正在读取…" : "补充图片",systemImage:"plus.circle") }.disabled(busy)
                }
                if record.attachments.count > 1 && !isNew {
                    Section {
                        Button("将每张图片拆成独立消费") { split() }
                    } footer:{ Text("拆分后的消费需要分别核对；原记录进入最近删除。") }
                }
                let duplicates = store.duplicates(for:record.attachments,excluding:record.id)
                if !duplicates.isEmpty { Section("发现相同图片") { ForEach(duplicates) { Text("与“\($0.title)”的图片重复，请核对。 ").foregroundStyle(.orange) } } }
                if !store.meals.filter({$0.id != record.id}).isEmpty {
                    Section("合并到已有消费") {
                        Picker("选择消费",selection:$mergeTarget) { Text("不合并").tag(nil as UUID?); ForEach(store.meals.filter {$0.id != record.id}) { item in Text("\(item.title) · \(Money.text(item.amountCents))").tag(Optional(item.id)) } }
                        if mergeTarget != nil { Text("合并只追加凭证，保留目标消费的金额与日期；合并后需要重新确认。").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if !isNew { Section { Button("删除此笔消费",role:.destructive) { deleting = true } } }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(record.confirmed ? "票据详情" : "补全票据信息").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement:.keyboard) {Spacer(); Button("完成输入") {focusedField = nil}}
                ToolbarItem(placement:.cancellationAction) { Button("关闭") { if hasChanges { discardChanges = true } else { dismiss() } } }
                ToolbarItem(placement:.primaryAction) { EditButton() }
                ToolbarItemGroup(placement:.bottomBar) {
                    if !record.confirmed { Button("暂存") { save(confirm:false) }.disabled(busy) }
                    Spacer()
                    Button(mergeTarget == nil ? "保存" : "合并凭证") { save(confirm:mergeTarget == nil) }.buttonStyle(.borderedProminent).disabled(busy)
                }
            }
            .interactiveDismissDisabled()
            .confirmationDialog("离开前保存修改？",isPresented:$discardChanges,titleVisibility:.visible) { Button("保存修改") {save(confirm:false)}; Button("放弃修改",role:.destructive) {dismiss()}; Button("继续编辑",role:.cancel) {} }
            .onAppear { amount = Money.editable(record.amountCents); loadTime(); initialValues = editorValues }
            .onChange(of:record.date) { _,_ in loadTime() }
            .onChange(of:photos) { _,items in Task { await add(items) } }
            .alert("无法完成",isPresented:Binding(get:{error != nil},set:{if !$0 {error = nil}})) { Button("好",role:.cancel) {} } message:{Text(error ?? "")}
            .confirmationDialog("将此笔消费移入最近删除？",isPresented:$deleting,titleVisibility:.visible) { Button("删除消费",role:.destructive) { do {try store.trash(record); dismiss()} catch {self.error = error.localizedDescription} } }
            .sheet(item:$selectedImage) { a in NavigationStack { ScrollView([.horizontal,.vertical]) { if let image = store.image(a) { Image(uiImage:image).resizable().scaledToFit().frame(width:UIScreen.main.bounds.width-24) } }.toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { selectedImage = nil } } } } }
        }
    }
    private func loadTime() {
        endTime = record.date.flatMap { store.archive.dayTimes?[Reimbursement.day($0)] } ?? ""
        lodging = record.date.flatMap { store.archive.lodgingCents?[Reimbursement.day($0)] }.flatMap { $0 > 0 ? Money.editable($0) : nil } ?? ""
    }
    private func save(confirm:Bool) {
        let clean = amount.trimmingCharacters(in:.whitespaces)
        if !clean.isEmpty && Money.cents(clean) == nil { error = "金额请输入最多两位小数的非负数字。"; return }
        if !lodging.isEmpty && Money.cents(lodging) == nil { error = "住宿费请输入非负金额，最多两位小数。"; return }
        record.amountCents = Money.cents(clean)
        // The user has supplied the corrected fields; recognition conflicts no longer gate admission.
        record.recognitionIssues = nil
        record.confirmed = record.isValid
        if confirm && !record.isValid { error = "请填写商家、金额、消费日期，并至少添加一张凭证。"; return }
        do {
            if let id = mergeTarget {
                try store.merge(record,into:id)
            } else { try store.save(record,endTime:endTime.trimmingCharacters(in:.whitespacesAndNewlines),lodgingCents:Money.cents(lodging) ?? 0) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func rotate(_ attachment:ReceiptAttachment) {
        guard let image = store.image(attachment) else { return }
        let rotated = UIGraphicsImageRenderer(size:CGSize(width:image.size.height,height:image.size.width)).image { ctx in
            ctx.cgContext.translateBy(x:image.size.height,y:0); ctx.cgContext.rotate(by:.pi/2); image.draw(at:.zero)
        }
        do {
            guard let data = rotated.jpegData(compressionQuality:0.98), let i = record.attachments.firstIndex(of:attachment) else { return }
            var replacement = try store.addImage(data); replacement.text = attachment.text; replacement.recognitionNotice = attachment.recognitionNotice; record.attachments[i] = replacement
        } catch { self.error = error.localizedDescription }
    }
    private func split() {
        do {
            try store.split(record); dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func add(_ items:[PhotosPickerItem]) async {
        busy = true; defer { busy = false; photos = [] }
        do { for item in items { guard let data = try await item.loadTransferable(type:Data.self) else { throw AppError.message("有图片读取失败，请重试。") }; var a = try store.addImage(data); let recognition = await ImportService.recognizeWithFallback(data); a.text = recognition.text; a.recognitionNotice = recognition.notice; if let notice = recognition.notice { record.recognitionIssues = (record.recognitionIssues ?? []) + [notice] }; record.attachments.append(a); record.confirmed = false } }
        catch { self.error = error.localizedDescription }
    }
}
