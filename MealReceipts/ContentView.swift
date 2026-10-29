import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ContentView:View {
    @EnvironmentObject private var store:ReceiptStore
    @State private var tab = 0
    @State private var profileOpen = false
    @State private var ocrSettingsOpen = false
    @State private var invoiceImporter = false
    @State private var invoicePhotos:[PhotosPickerItem] = []
    @State private var generated: ExportRecord?
    @State private var generatedAction: GeneratedAction?
    @State private var generatedError: String?
    @State private var packaging = false
    @State private var month = Date()
    @State private var photos:[PhotosPickerItem] = []
    @State private var uploadKind: MealKind = .delivery
    @State private var showUploadSource = false
    @State private var showPicker = false
    @State private var showCamera = false
    @State private var importBusy = false
    @State private var importProgress = ""
    @State private var importNotice: String?
    @State private var editing:MealRecord?
    @State private var share:ShareItem?
    @State private var preview:PreviewItem?
    @State private var selected:Set<UUID> = []
    @State private var userChangedSelection = false
    @State private var error:String?
    @State private var showBackupImporter = false
    @State private var backupToImport:URL?
    @State private var restoreConfirm = false
    @State private var trashOpen = false
    @State private var exportBusy = false
    @State private var exportMonth = ""
    @State private var completedExport: ExportRecord?
    @State private var exportFailure: String?
    @State private var exportToDelete: ExportRecord?
    private var monthLabel:String { month.formatted(.dateTime.year().month(.wide)) }
    private var monthMeals:[MealRecord] { store.meals.filter { Calendar.current.isDate($0.date ?? $0.createdAt,equalTo:month,toGranularity:.month) } }
    private var eligible:[MealRecord] { monthMeals.filter { $0.confirmed && $0.isValid } }
    private func reimbursement(_ records:[MealRecord]) -> Int { Reimbursement.total(records) + Reimbursement.groups(records).reduce(0) { $0 + (store.archive.lodgingCents?[$1.0] ?? 0) } }
    private var total:Int { reimbursement(eligible) }
    private var chosen:[MealRecord] { eligible.filter { selected.contains($0.id) } }
    private var missingDays:[String] { Reimbursement.groups(chosen).map { $0.0 }.filter { !Reimbursement.validTime(store.archive.dayTimes?[$0] ?? "") } }
    private var invoices:[InvoiceFile] { (store.archive.invoices ?? []).filter { $0.month == Reimbursement.month(month) } }
    private var ready:Bool { !chosen.isEmpty && missingDays.isEmpty && store.archive.profile?.complete == true && monthMeals.allSatisfy { $0.confirmed && $0.isValid } }
    var body:some View {
        TabView(selection:$tab) {
            NavigationStack { dashboard }.tabItem { Label("票夹",systemImage:"square.stack.3d.up.fill") }.tag(0)
            NavigationStack { reports }.tabItem { Label("报销",systemImage:"doc.richtext") }.tag(1)
        }
        .confirmationDialog("上传票据",isPresented:$showUploadSource,titleVisibility:.visible) {
            Button("拍照") {
                if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
                else { error = "当前设备没有可用相机，请选择从相册上传。" }
            }
            Button("从相册选择") { showPicker = true }
            Button("取消",role:.cancel) {}
        }
        .photosPicker(isPresented:$showPicker,selection:$photos,maxSelectionCount:1,matching:.images)
        .onChange(of:invoicePhotos) { _,items in
            if !items.isEmpty { Task {
                let invoiceMonth = Reimbursement.month(month)
                importBusy = true; importProgress = "保存发票原件…"
                defer { invoicePhotos = []; importBusy = false }
                do { for item in items { guard let data = try await item.loadTransferable(type:Data.self) else { throw AppError.message("读取发票图片失败。") }; try store.importInvoiceImage(data,month:invoiceMonth) } } catch { self.error = error.localizedDescription }
            } }
        }
        .onChange(of:photos) { _,items in if !items.isEmpty { Task { await importPhotos(items) } } }
        .sheet(isPresented:$showCamera) { CameraPicker { data in if let data { Task { await importData([data],kind:uploadKind) } } } }
        .sheet(item:$editing) { record in RecordEditor(record:record).environmentObject(store) }
        .sheet(item:$share) { ShareSheet(urls:$0.urls) }
        .sheet(item:$preview) { item in FilePreview(url:item.url) }
        .sheet(isPresented:$ocrSettingsOpen) { OCRSettings() }
        .sheet(isPresented:$profileOpen) { ProfileEditor().environmentObject(store) }
        .sheet(item:$generated) { report in generatedView(report) }
        .fileImporter(isPresented:$invoiceImporter,allowedContentTypes:[.pdf,.jpeg,.png,.heic],allowsMultipleSelection:true) { result in
            do { for url in try result.get() { try store.importInvoice(url,month:Reimbursement.month(month)) } } catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented:$trashOpen) { trashView }
        .fileImporter(isPresented:$showBackupImporter,allowedContentTypes:[.data],allowsMultipleSelection:false) { result in
            do { backupToImport = try result.get().first; restoreConfirm = backupToImport != nil } catch { self.error = error.localizedDescription }
        }
        .confirmationDialog("恢复备份将作为新记录合并，原记录不会被覆盖。重复恢复会产生重复记录。",isPresented:$restoreConfirm,titleVisibility:.visible) {
            Button("确认合并恢复") { if let url = backupToImport { do {try store.importBackup(url); resetSelection()} catch {self.error = error.localizedDescription} } }
        }
        .alert("提示",isPresented:Binding(get:{error != nil || store.error != nil},set:{if !$0 {error = nil; store.error = nil}})) { Button("好",role:.cancel) {} } message:{Text(error ?? store.error ?? "")}
        .safeAreaInset(edge:.top,spacing:0) { exportStatus }
        .confirmationDialog("删除这份报销包？",isPresented:Binding(get:{exportToDelete != nil},set:{if !$0 {exportToDelete = nil}}),titleVisibility:.visible) {
            Button("删除报销包",role:.destructive) {
                guard let report = exportToDelete else { return }
                do {
                    try store.removeExport(report)
                    if completedExport?.id == report.id { completedExport = nil }
                    resetSelection()
                } catch { self.error = error.localizedDescription }
                exportToDelete = nil
            }
            Button("取消",role:.cancel) { exportToDelete = nil }
        } message: { Text("删除此次生成的文件和历史记录，保留原始票据及发票。已保存到其他位置的文件不受影响。") }
        .overlay { if importBusy { ZStack { Color.black.opacity(0.2).ignoresSafeArea(); VStack(spacing:16) { ProgressView(); Text(importProgress).font(.subheadline); Text("请保持应用打开").font(.caption).foregroundStyle(.secondary) }.padding(28).background(.regularMaterial,in:RoundedRectangle(cornerRadius:20)) } } }
        .onAppear { resetSelection() }
        .onChange(of:month) { _,_ in userChangedSelection = false; resetSelection() }
        .onChange(of:store.archive.meals) { _,_ in reconcileSelection() }
    }
    private var monthPicker:some View {
        HStack {
            Button { shiftMonth(-1) } label:{Image(systemName:"chevron.left").frame(width:40,height:40)}.accessibilityLabel("上个月")
            Spacer(); Text(monthLabel).font(.headline); Spacer()
            Button { shiftMonth(1) } label:{Image(systemName:"chevron.right").frame(width:40,height:40)}.accessibilityLabel("下个月")
        }.listRowBackground(Color.clear)
    }
    private var dashboard:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                HStack {
                    Text("\(Calendar.current.component(.month,from:month))月票夹").font(.largeTitle.bold())
                    Spacer()
                    Button { shiftMonth(-1) } label: { Image(systemName:"chevron.left") }.accessibilityLabel("上个月")
                    Text(month.formatted(.dateTime.year().month())).font(.caption)
                    Button { shiftMonth(1) } label: { Image(systemName:"chevron.right") }.accessibilityLabel("下个月")
                }
                VStack(alignment:.leading,spacing:5) {
                    Text("预计可报销").font(.subheadline).foregroundStyle(.secondary)
                    Text(Money.text(total)).font(.system(size:40,weight:.semibold)).monospacedDigit()
                    Text("实付 \(Money.text(eligible.reduce(0) { $0 + ($1.amountCents ?? 0) })) · \(monthMeals.count) 笔").font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing:16) {
                    ForEach(MealKind.allCases) { kind in
                        NavigationLink { folder(kind) } label: {
                            FolderCard(kind:kind,count:monthMeals.filter { $0.kind == kind }.count)
                        }.buttonStyle(.plain)
                    }
                }
                if let importNotice { Text(importNotice).font(.caption).foregroundStyle(PaperStyle.violet) }
                if monthMeals.count > eligible.count {
                    Button { if let meal = monthMeals.first(where: { !$0.confirmed || !$0.isValid }) { editing = meal } } label: {
                        HStack { Image(systemName:"circle"); Text("\(monthMeals.count-eligible.count) 笔待核对"); Spacer(); Image(systemName:"chevron.right") }.font(.subheadline).padding(14).background(.white,in:RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain)
                }
                Text("最近收集").font(.headline)
                if monthMeals.isEmpty { ContentUnavailableView("这个月还没有票据",systemImage:"receipt",description:Text("选择外卖截图或堂食小票，随手收好。")) }
                ForEach(monthMeals) { meal in
                    Button { editing = meal } label: { mealRow(meal).padding(12).background(.white,in:RoundedRectangle(cornerRadius:14)) }.buttonStyle(.plain)
                }
                Text("按消费日期归档；缺少日期的票据需核对后计入报销。").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }.background(PaperStyle.background).navigationTitle("餐费小袋").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarTrailing) { settingsMenu } }
    }
    private func folder(_ kind:MealKind) -> some View {
        let title = kind == .delivery ? "外卖截图" : "堂食小票"
        let records = monthMeals.filter { $0.kind == kind }
        return List {
            if records.isEmpty {
                ContentUnavailableView("还没有\(title)",systemImage:kind == .delivery ? "bicycle" : "receipt",
                                       description:Text("点击下方上传票据，拍照或从相册选择。"))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(records) { meal in
                    Button { editing = meal } label: { mealRow(meal) }.buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(title)
        .safeAreaInset(edge:.bottom) {
            VStack(spacing:10) {
                Button {
                    uploadKind = kind
                    showUploadSource = true
                } label: {
                    Label("上传票据",systemImage:"plus.circle.fill")
                        .font(.headline).frame(maxWidth:.infinity).padding(.vertical,10)
                }
                .buttonStyle(.borderedProminent).tint(PaperStyle.violet)
                .disabled(importBusy)
                Text("新增到\(title) · 每次一张，自动识别录入")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(alignment:.top,spacing:8) {
                    Text("开启云端识别时，图片将经后台交由 DeepSeek 识别。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength:0)
                    Button("识别设置") { ocrSettingsOpen = true }.font(.caption2)
                }
            }.padding(.horizontal,20).padding(.vertical,14).background(.regularMaterial)
        }
    }
    private var reports:some View {
        List {
            monthPicker
            Section {
                HStack { Text("已选 \(selected.count) 笔票据"); Spacer(); Text(Money.text(reimbursement(chosen))).font(.title2.bold()).monospacedDigit() }
                Text("晚餐餐补每日最高30元，同一天只申请一次。").font(.caption).foregroundStyle(.secondary)
            }
            Section("材料检查") {
                checkRow("餐费票据",detail:"\(monthMeals.count-eligible.count) 笔待核对",complete:monthMeals.count == eligible.count)
                ForEach(monthMeals.filter { !$0.confirmed || !$0.isValid }) { meal in Button { editing = meal } label: { VStack(alignment:.leading,spacing:4) { Text("补全：\(meal.title)"); Text(meal.reviewReasons.joined(separator:"、")).font(.caption).foregroundStyle(.secondary) } } }
                if missingDays.isEmpty { checkRow("加班结束时间",detail:"已填写",complete:true) }
                ForEach(missingDays,id:\.self) { day in Button {
                    editing = chosen.first { $0.date.map(Reimbursement.day) == day }
                } label: { HStack { Image(systemName:"exclamationmark.circle").foregroundStyle(.orange); Text("\(day) 结束时间待填"); Spacer(); Image(systemName:"chevron.right") }.font(.subheadline) } }
                Button { profileOpen = true } label: { checkRow("本人报销资料",detail:store.archive.profile?.complete == true ? "已填写" : "填写姓名、部门",complete:store.archive.profile?.complete == true) }.buttonStyle(.plain)
            }
            Section {
                ForEach(invoices) { invoice in
                    HStack { Button { preview = PreviewItem(url:store.file(invoice.filename)) } label: { Label(invoice.displayName,systemImage:"doc") }; Spacer(); Button(role:.destructive) { do {try store.removeInvoice(invoice)} catch {self.error = error.localizedDescription} } label: { Image(systemName:"minus.circle") } }.buttonStyle(.borderless)
                }
                Button { invoiceImporter = true } label: { Label("从文件添加发票",systemImage:"doc.badge.plus") }
                PhotosPicker(selection:$invoicePhotos,maxSelectionCount:20,matching:.images) { Label("从相册添加发票",systemImage:"photo.badge.plus") }
            } header: { Text("餐饮发票 · \(invoices.count) 份") } footer: { Text("支持PDF及图片，保留原件；请按公司要求核对发票是否齐全。") }
            Section("纳入本次报销") {
                Button(selected.count == eligible.count ? "取消全选" : "全选已录入票据") { userChangedSelection = true; selected = selected.count == eligible.count ? [] : Set(eligible.map(\.id)) }
                ForEach(eligible) { meal in Button { userChangedSelection = true; if selected.contains(meal.id) {selected.remove(meal.id)} else {selected.insert(meal.id)} } label: { HStack { Image(systemName:selected.contains(meal.id) ? "checkmark.circle.fill" : "circle"); mealRow(meal) } }.buttonStyle(.plain) }
                Text("\(eligible.count-selected.count) 笔已录入票据未纳入；已提交记录默认不选。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("票据排版：外卖、堂食分章节").font(.subheadline)
                Text("生成后包含：Excel 明细、票据 PDF、发票原件").font(.caption).foregroundStyle(.secondary)
                Button { Task { await export() } } label: { Text(exportBusy ? "报销包正在生成" : ready ? "生成报销包" : "补齐后生成报销包").font(.headline).frame(maxWidth:.infinity).padding(10) }.buttonStyle(.borderedProminent).tint(PaperStyle.ink).disabled(!ready || exportBusy)
            }
            Section("历史导出") {
                ForEach(store.archive.exports) { report in
                    Button { generated = report } label: { VStack(alignment:.leading,spacing:5) { Text(report.month).font(.headline); Text("\(Money.text(report.total)) · \(report.submitted ? "已手动标记提交" : "尚未标记提交")").font(.caption).foregroundStyle(.secondary) } }.buttonStyle(.plain)
                        .swipeActions(edge:.trailing,allowsFullSwipe:false) {
                            Button(role:.destructive) { exportToDelete = report } label: { Label("删除",systemImage:"trash") }
                        }
                }
            }
        }.scrollContentBackground(.hidden).background(PaperStyle.background).navigationTitle("月底整理")
    }
    private func checkRow(_ title:String,detail:String,complete:Bool) -> some View {
        HStack { Image(systemName:complete ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(complete ? PaperStyle.violet : Color.orange); Text(title); Spacer(); Text(complete && title == "餐费票据" ? "已录入" : detail).font(.caption).foregroundStyle(.secondary) }
    }
    private func generatedView(_ report:ExportRecord) -> some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment:.leading,spacing:12) { Image(systemName:"checkmark.circle.fill").font(.largeTitle).foregroundStyle(PaperStyle.violet); Text("报销包已生成").font(.title.bold()); Text("\(report.month) · \(Money.text(report.total))").foregroundStyle(.secondary) }.padding(.vertical)
                }
                Section("汇总文件") {
                    fileRow("餐费票据.pdf",url:store.file(report.pdfFilename))
                    if let name = report.spreadsheetFilename { fileRow("报销明细.xlsx",url:store.file(name)) }
                }
                Section("发票原件") { ForEach(report.invoiceFiles ?? []) { invoice in fileRow(invoice.displayName,url:store.file(invoice.filename)) } }
                Section {
                    Button(packaging ? "正在打包…" : "导出 ZIP 报销包") {
                        guard !packaging else { return }
                        packaging = true
                        let root = store.root
                        Task {
                            defer { packaging = false }
                            do {
                                let url = try await Task.detached(priority:.userInitiated) { try ReportExporter.package(report,root:root) }.value
                                generatedAction = .share(ShareItem(urls:[url]))
                            } catch { generatedError = error.localizedDescription }
                        }
                    }.buttonStyle(.borderedProminent).tint(PaperStyle.ink).disabled(packaging)
                    Text("ZIP 内含票据 PDF、Excel 明细及已添加的发票原件。").font(.caption).foregroundStyle(.secondary)
                    Button(report.submitted ? "撤销提交标记" : "标记已提交") { do {try store.markSubmitted(report); resetSelection(); generated = nil} catch {self.error = error.localizedDescription} }
                    Text("材料准备完成，需自行提交公司报销。").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("生成结果").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { generated = nil } } }
                .sheet(item:$generatedAction) { action in
                    switch action {
                    case .preview(let item): FilePreview(url:item.url)
                    case .share(let item): ShareSheet(urls:item.urls)
                    }
                }
                .alert("导出失败",isPresented:Binding(get:{generatedError != nil},set:{if !$0 {generatedError = nil}})) { Button("好",role:.cancel) {} } message: { Text(generatedError ?? "") }
        }
    }
    private func fileRow(_ name:String,url:URL) -> some View {
        Button { generatedAction = .preview(PreviewItem(url:url)) } label: { HStack { Label(name,systemImage:"doc.text"); Spacer(); Text("预览").font(.caption) } }
    }
    private func mealRow(_ meal:MealRecord) -> some View {
        HStack(spacing:12) {
            if let attachment = meal.attachments.first,let image = store.image(attachment) { Image(uiImage:image).resizable().scaledToFill().frame(width:48,height:60).clipped().clipShape(RoundedRectangle(cornerRadius:7)) }
            else { Image(systemName:meal.kind.symbol).frame(width:48,height:60).background(Color(.tertiarySystemFill),in:RoundedRectangle(cornerRadius:7)) }
            VStack(alignment:.leading,spacing:5) {
                Text(meal.title).font(.headline).lineLimit(1)
                Text("\(meal.date?.formatted(date:.abbreviated,time:.omitted) ?? "待补消费日期") · \(meal.kind.rawValue) · \(meal.attachments.count) 张").font(.caption).foregroundStyle(.secondary)
                if !meal.confirmed { Text(meal.reviewReasons.isEmpty ? "待补票据信息" : meal.reviewReasons.joined(separator:"、")).font(.caption2).foregroundStyle(.orange) }
                else if store.isSubmitted(meal) { Text("已提交").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(); VStack(alignment:.trailing,spacing:4) { Text(Money.text(meal.amountCents)).font(.subheadline.weight(.semibold)); Text("实付").font(.caption2).foregroundStyle(.secondary) }
        }.padding(.vertical,5)
    }
    private var settingsMenu:some View {
        Menu {
            Button("识别设置",systemImage:"viewfinder") { ocrSettingsOpen = true }
            Button("个人资料",systemImage:"person.crop.circle") { profileOpen = true }
            Button("导出完整备份",systemImage:"externaldrive") { do {share = ShareItem(urls:[try store.backupURL()])} catch {self.error = error.localizedDescription} }
            Button("从备份恢复",systemImage:"arrow.clockwise") {showBackupImporter = true}
            Button("最近删除（\(store.deleted.count)）",systemImage:"trash") {trashOpen = true}
            Text("数据保存在本机，请定期备份；卸载会删除本机数据。")
        } label:{Image(systemName:"ellipsis.circle")}
    }
    private var trashView:some View {
        NavigationStack { List {
            if store.deleted.isEmpty { ContentUnavailableView("暂无删除记录",systemImage:"trash") }
            ForEach(store.deleted) { item in HStack {Text(item.title); Spacer(); Button("恢复") {do {try store.restore(item)} catch {self.error = error.localizedDescription}}} }
        }.navigationTitle("最近删除").toolbar {ToolbarItem(placement:.confirmationAction) {Button("完成") {trashOpen = false}}} }
    }
    private func shiftMonth(_ delta:Int) {month = Calendar.current.date(byAdding:.month,value:delta,to:month) ?? month}
    private func resetSelection() { userChangedSelection = false; reconcileSelection() }
    private func reconcileSelection() {
        selected = ReportSelection.reconcile(current:selected,eligible:eligible,submitted:Set(eligible.filter {store.isSubmitted($0)}.map(\.id)),userChanged:userChangedSelection)
    }
    private func importPhotos(_ items:[PhotosPickerItem]) async {
        guard let item = items.first else { return }
        importBusy = true; importProgress = "读取图片…"
        defer { importBusy = false; photos = [] }
        do {
            guard let data = try await item.loadTransferable(type:Data.self) else { throw AppError.message("图片读取失败，请重新选择。") }
            await importData([data],kind:uploadKind)
        } catch { self.error = error.localizedDescription }
    }
    private func importData(_ images:[Data],kind:MealKind) async {
        importBusy = true; defer {importBusy = false}
        do {
            let imported = try await ImportService.importImages(images,group:false,kind:kind,store:store,progress:{ importProgress = $0 })
            if let first = imported.first { month = first.date ?? first.createdAt }
            let admitted = imported.filter { $0.confirmed }.count
            let pending = imported.count-admitted
            importNotice = pending == 0 ? "已自动识别并录入\(admitted)笔票据" : "已自动录入\(admitted)笔，\(pending)笔需补全或核对，已放入待核对"
        } catch {self.error = "\(error.localizedDescription) 已成功保存的图片仍在“本月”。"}
    }
    @ViewBuilder private var exportStatus: some View {
        if exportBusy || completedExport != nil || exportFailure != nil {
            HStack(spacing:10) {
                if exportBusy {
                    ProgressView()
                    VStack(alignment:.leading,spacing:3) {
                        Text("\(exportMonth)报销包正在生成").font(.subheadline)
                        Text("可继续使用，稍后到报销页查看结果").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let report = completedExport {
                    Image(systemName:"checkmark.circle.fill").foregroundStyle(PaperStyle.violet)
                    Text("\(report.month)报销包已生成").font(.subheadline)
                    Spacer()
                    Button("查看") { generated = report; completedExport = nil }
                    Button { completedExport = nil } label: { Image(systemName:"xmark") }.accessibilityLabel("稍后查看")
                } else if let failure = exportFailure {
                    Image(systemName:"exclamationmark.circle").foregroundStyle(.orange)
                    Text("生成失败：\(failure)").font(.caption)
                    Spacer()
                    Button { exportFailure = nil } label: { Image(systemName:"xmark") }.accessibilityLabel("关闭生成失败提示")
                }
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.regularMaterial)
        }
    }
    private func export() async {
        guard !exportBusy, ready else { return }
        let records = chosen
        let label = monthLabel
        exportMonth = label
        completedExport = nil
        exportFailure = nil
        exportBusy = true
        defer { exportBusy = false }
        do {
            completedExport = try await ReportExporter.render(records:records,month:label,store:store)
        } catch { exportFailure = error.localizedDescription }
    }
}
struct ShareItem:Identifiable {let id = UUID(); var urls:[URL]}
struct PreviewItem:Identifiable {let id = UUID(); var url:URL}

private enum GeneratedAction: Identifiable {
    case preview(PreviewItem)
    case share(ShareItem)
    var id: UUID {
        switch self {
        case .preview(let item): return item.id
        case .share(let item): return item.id
        }
    }
}
