import SwiftUI

struct OCRSettings:View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("cloudOCREnabled") private var cloudEnabled = true
    var body:some View {
        NavigationStack {
            Form {
                Section("小票识别") {
                    Toggle("使用云端智能识别",isOn:$cloudEnabled)
                    Text(OCRConfiguration.endpoint == nil ? "当前版本尚未配置云端服务，暂用本机离线识别。" : "云端服务由餐费小袋统一提供，无需填写密钥。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("图片如何处理") {
                    Text("开启后，新上传的小票图片会通过加密连接发送至餐费小袋后台，再由 DeepSeek 提取商家、消费日期和实付金额。后台不保存图片和识别内容，原图及消费记录仍保存在本机。")
                    Text("后台使用不可直接识别你的设备安装标识和网络来源计数，以限制调用次数。你无需注册 DeepSeek 账户，也无需支付自己的 API 费用。")
                    Text("关闭后仅使用本机离线识别。云端失败会自动回退离线识别并提示核对；已有票据不会自动重新识别。")
                }
            }.navigationTitle("识别设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
