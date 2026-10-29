import SwiftUI

@main struct MealReceiptsApp: App {
    @StateObject private var store = ReceiptStore()
    var body: some Scene { WindowGroup { ContentView().environmentObject(store).tint(PaperStyle.violet).preferredColorScheme(.light).task {
#if DEBUG
if ProcessInfo.processInfo.arguments.contains("--self-test") { await DebugChecks.run() }
#endif
} } }
}
struct ShareSheet: UIViewControllerRepresentable {
    var urls:[URL]
    func makeUIViewController(context:Context) -> UIActivityViewController { UIActivityViewController(activityItems:urls,applicationActivities:nil) }
    func updateUIViewController(_ uiViewController:UIActivityViewController,context:Context) {}
}
struct CameraPicker: UIViewControllerRepresentable {
    var completion:(Data?) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context:Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ uiViewController:UIImagePickerController,context:Context) {}
    final class Coordinator:NSObject,UINavigationControllerDelegate,UIImagePickerControllerDelegate {
        let parent:CameraPicker; init(_ parent:CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker:UIImagePickerController,didFinishPickingMediaWithInfo info:[UIImagePickerController.InfoKey:Any]) { parent.completion((info[.originalImage] as? UIImage)?.jpegData(compressionQuality:0.95)); parent.dismiss() }
        func imagePickerControllerDidCancel(_ picker:UIImagePickerController) { parent.dismiss() }
    }
}
struct PDFPreview:UIViewRepresentable {
    var url:URL
    func makeUIView(context:Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url:url)
        return view
    }
    func updateUIView(_ uiView:PDFView,context:Context) {
        if uiView.document?.documentURL != url { uiView.document = PDFDocument(url:url) }
    }
}
import PDFKit
