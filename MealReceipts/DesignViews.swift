import SwiftUI
import QuickLook
import PDFKit

enum PaperStyle {
    static let background = Color(red:0.97,green:0.97,blue:0.955)
    static let violet = Color(red:0.47,green:0.40,blue:0.67)
    static let ink = Color(red:0.14,green:0.14,blue:0.17)
}
struct FolderCard: View {
    let kind: MealKind
    let count: Int
    var body: some View {
        VStack(spacing:0) {
            ZStack(alignment:.bottom) {
                RoundedRectangle(cornerRadius:8).fill(kind == .delivery ? Color(red:0.89,green:0.85,blue:0.78) : Color(red:0.79,green:0.75,blue:0.88)).frame(height:74).padding(.horizontal,6)
                ForEach(0..<3) { i in
                    VStack(alignment:.leading,spacing:6) {
                        Text(i == 1 ? "晚餐凭证" : "RECEIPT").font(.system(size:8,weight:.medium))
                        ForEach(0..<4) { _ in Capsule().fill(Color.gray.opacity(0.23)).frame(height:2) }
                    }.padding(10).frame(width:65,height:85).background(.white).rotationEffect(.degrees(Double(i-1)*12)).offset(x:CGFloat(i-1)*24,y:-12).shadow(color:.black.opacity(0.07),radius:3,y:2)
                }
            }.frame(height:105)
            HStack {
                VStack(alignment:.leading,spacing:7) { Text(kind == .delivery ? "外卖截图" : "堂食小票").font(.headline); Text("\(count) 笔").font(.caption).foregroundStyle(.secondary) }
                Spacer(); Image(systemName:"chevron.right").font(.caption)
            }.padding(16).background(kind == .delivery ? Color(red:0.93,green:0.90,blue:0.84) : Color(red:0.87,green:0.84,blue:0.93),in:RoundedRectangle(cornerRadius:12)).padding(.top,-28)
        }.foregroundStyle(PaperStyle.ink).shadow(color:.black.opacity(0.04),radius:5,y:3)
    }
}
struct ProfileEditor: View {
    @EnvironmentObject var store: ReceiptStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile = PersonalProfile()
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("姓名",text:$profile.name); TextField("部门",text:$profile.department) } header: { Text("本人报销资料") } footer: { Text("填写一次，所有报销明细自动使用。修改不影响已生成的历史报销包。资料保存在本机。") }
            }.navigationTitle("个人资料").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) { Button("保存") { do { try store.saveProfile(profile); dismiss() } catch { self.error = error.localizedDescription } }.disabled(!profile.complete) }
                }.onAppear { profile = store.archive.profile ?? PersonalProfile() }
                .alert("保存失败",isPresented:Binding(get:{error != nil},set:{if !$0 {error = nil}})) { Button("好") {} } message: { Text(error ?? "") }
        }
    }
}
struct FilePreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if url.pathExtension.lowercased() == "pdf" {
            NavigationStack {
                PDFPreview(url:url)
                    .navigationTitle("票据预览")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement:.topBarLeading) { ShareLink(item:url) { Label("导出",systemImage:"square.and.arrow.up") } }
                        ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } }
                    }
            }
        } else {
            QuickLookPreview(url:url)
        }
    }
}
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context:Context) -> QLPreviewController { let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller }
    func updateUIViewController(_ controller:QLPreviewController,context:Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(_ url:URL) { self.url = url }
        func numberOfPreviewItems(in controller:QLPreviewController) -> Int { 1 }
        func previewController(_ controller:QLPreviewController,previewItemAt index:Int) -> QLPreviewItem { url as NSURL }
    }
}
