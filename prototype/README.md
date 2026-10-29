# 网页在线体验版

浏览器本地存储票据和报销快照，不上传图片到云端；示例识别与真实 OCR 能力在页面中明确区分。

一键示例生成真实 PDF 和 Excel，并可打包 ZIP 下载。PDF 每页最多四张，按外卖/堂食分类；Excel 每天合计最高30元，同日不重复申报。上传的发票原件随 ZIP 保留，示例发票不打包为真实发票。

生成时可继续浏览，完成后点顶部“查看结果”；历史导出支持确认删除，不影响原票据。

运行：`python3 -m http.server 8877 --directory prototype`。

本机 macOS Vision 模式：在仓库根目录编译 `swiftc MealReceipts/Models.swift prototype/ReceiptOCR.swift -o prototype/.runtime/receipt-ocr`（先创建 `.runtime` 目录），运行 `python3 prototype/server.py`。公开站点不使用此本机服务。
