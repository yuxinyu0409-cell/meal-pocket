# 餐费小袋 · Meal Pocket

从随手收好票据，到月底下载一份报销包。一个围绕真实个人报销需求设计并开发的 iOS App，以及无需安装的在线体验版。

## 在线体验

部署完成后此处将提供作品链接。打开后点 **一键体验示例报销包**，完成后点 **查看结果 → 下载 ZIP 报销包**。可实际下载 PDF 与 Excel，并非模拟下载。

也可以逐步体验：收集票据 → 核对异常信息 → 填写加班结束时间 → 选择报销范围 → 生成报销包。

## 能力与边界

| 功能 | 网页体验版 | iPhone App |
| --- | --- | --- |
| 收集与核对 | 示例识别结果、图片上传、手动补全 | 相机/相册、云端识别与 Vision 离线识别 |
| 报销规则 | 按天合计，晚餐每日最高 30 元，住宿费另列 | 相同规则 |
| 导出 | 真实 PDF + Excel + ZIP，浏览器内生成 | 原生 PDF + Excel + ZIP |
| 票据排版 | 外卖/堂食分类，每页最多四张原图 | 相同排版 |
| 数据 | 当前浏览器 localStorage，可重置 | 本机文件与归档、完整备份恢复 |
| 生成过程 | 非阻塞状态提示，完成后主动查看 | 可离开当前页面，稍后查看历史 |

**公开网页版不调用付费云端 OCR，不上传访客的图片。** 示例票据明确标注“示例”，不可用于实际报销。真实图片上传后可手动核对；macOS 本地预览可启用 Vision。iPhone 云端识别需要部署自己的后台并配置公开服务地址，仓库不包含任何密钥。

## 项目结构

- `MealReceipts/`：SwiftUI iOS App，包含 OCR、数据归档与报销文件生成。
- `MealReceipts.xcodeproj/`：Xcode 工程（签名 Team 和后台地址留空）。
- `backend/`：可部署到 Vercel 的 Python OCR API，密钥仅在服务端环境变量中配置。
- `prototype/`：独立静态网页体验版；`export.js` 生成 PDF、OOXML Excel 和 ZIP。
- `Tests/`：Swift 核心逻辑与识别适配器检查。

## 本地运行网页

```sh
python3 -m http.server 8877 --directory prototype
```

打开 `http://localhost:8877`。导出依赖已固定版本并随仓库提供，不依赖外部 CDN。生产环境部署的是静态站点；API 保持独立部署。

## 运行 iPhone App

需要 Xcode 和 iOS 17 或更新版本。打开工程后选择自己的 Bundle ID 与 Signing Team；如需云端识别，按 [后台部署说明](backend/README.md) 设置 `MEAL_OCR_BASE_URL`。免费签名的本机安装与正式 App Store/TestFlight 分发不同。

## 验证

```sh
swiftc -module-cache-path /tmp/meal-swift-cache MealReceipts/Models.swift MealReceipts/SpreadsheetExporter.swift Tests/CoreTests.swift -o /tmp/meal-tests
/tmp/meal-tests
python3 -m unittest discover -s backend -p 'test_*.py' -v
```

iOS Debug 参数 `--self-test` 使用独立测试目录验证真实导出、四张同页与第五张换页、快照、备份恢复、历史删除且保留原图及发票。不会向正常票夹写入示例数据。

网页版已验证一键示例、真实 ZIP 下载、Excel 日期/餐补汇总，以及 PDF 图片渲染。浏览器本地存储容量有限，不作为长期备份使用。

## 部署到 Vercel

导入此仓库，Framework 选择 Other，仓库根目录的 `vercel.json` 会将 `prototype/` 作为静态站点部署。无需配置密钥、安装或构建命令。OCR 后台另外以 `backend` 为 Root Directory 部署，详见其 README。

## 许可证

项目代码采用 [MIT](LICENSE)。第三方库 JSZip 3.10.1、pdf-lib 1.17.1 的许可证位于 `prototype/vendor/`。未包含个人票据、签名证书、环境凭证或本机 Git 历史。
