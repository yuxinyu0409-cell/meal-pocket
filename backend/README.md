# 餐费小袋 · 统一识别后台（Vercel）

使用者不需要 DeepSeek 账号或 API Key。App 发送 JPEG 至你的 `/api/recognize`，后台统一调用 DeepSeek，返回商家、消费日期、实际支付金额。密钥只在 Vercel 环境变量中。

## 你需要准备的东西

- Vercel 账号和这个项目的代码。
- DeepSeek API Key（确保 API 账户可用）。
- 一份 Upstash Redis 数据库，用于所有函数实例共享调用额度。可从 Vercel Marketplace 连接 Upstash，或使用自己的 Upstash 数据库。这里使用 REST URL 和标准读写 Token。

通过 Vercel 集成连接时，自动生成的 `KV_REST_API_URL` / `KV_REST_API_TOKEN` 也受支持，无需额外复制凭证。

Redis 保存的是经过 HMAC 的网络来源/安装标识计数，不保存小票内容。不能用 Vercel 函数的 `/tmp` 文件做生产额度存储，那样扩容或冷启动会让计数失效。

## 部署步骤

1. 在 Vercel 导入代码仓库，**Root Directory 选择 `backend`**，Framework Preset 选择 Other。入口 `index.py` 显式声明 `BaseHTTPRequestHandler` 子类，适配当前 Vercel Python 入口检测。无需填写 Build Command 和 Output Directory。也可以在本目录使用 Vercel CLI 部署。
2. 在项目的 Environment Variables 中设置：

   | 名称 | 填什么 |
   |---|---|
   | `DEEPSEEK_API_KEY` | 你的 DeepSeek 密钥 |
   | `UPSTASH_REDIS_REST_URL` | Upstash 控制台提供的 HTTPS REST URL |
   | `UPSTASH_REDIS_REST_TOKEN` | Upstash 的标准读写 Token，不能用只读 Token |
   | `QUOTA_HASH_SECRET` | 至少32字符的随机值；生成后持续复用 |

   随机值可在本机生成：`python3 -c 'import secrets; print(secrets.token_hex(32))'`。不要放入 App，不要把密钥写入代码仓库。Preview 和 Production 建议用不同 Redis 数据库。
3. 默认每天全局1000次、同IP30次、同安装30次、同IP每分钟6次。可通过 `.env.example` 中相应变量调整。每天以 UTC 零点重置；失败调用也消耗次数。此上限限制的是模型调用次数，不是人民币金额。
4. Deploy。修改环境变量后重新部署。这个后台不提供网页首页，根路径404是正常的；访问 `https://你的域名/api/health` 应返回 `{"ready":true}`。这只说明必要配置已加载，不代表密钥、余额和 Redis 连通性已实测。
5. 使用手机 App 调用时，Production 接口必须可公开访问；如果有 Vercel Deployment Protection，按项目设置为生产 API 放行。**不要把 Vercel 管理员访问令牌或绕过令牌嵌入 App**。接口本身有调用额度保护。
6. 可绑定自己的域名改善域名可控性，但无法保证中国大陆可达。用手机流量和宽带分别实测。

Vercel 请求体上限4.5MB，本项目 JPEG 上限4,000,000字节；iPhone 上传前自动缩放压缩副本，保留本机原图。函数最长60秒，DeepSeek超时40秒，不自动重试付费请求。

## 把 App 指向后台

在 Xcode 的 MealReceipts target → Build Settings → User-Defined，将 Debug/Release 的 **`MEAL_OCR_BASE_URL`** 设为部署后的 HTTPS 源站地址，例如 `https://你的项目.vercel.app`，末尾不要添加 `/api/recognize`。

也可在构建时传入公开服务地址：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project MealReceipts.xcodeproj -scheme MealReceipts \
  -configuration Debug -sdk iphonesimulator -arch arm64 \
  -derivedDataPath /tmp/meal-managed-ocr-build CODE_SIGNING_ALLOWED=NO \
  MEAL_OCR_BASE_URL=https://你的项目.vercel.app build
```

这个命令应在仓库根目录运行。发布给用户之前同样要为 Release 配好地址并重新构建安装包。用户下载后无需设置地址或密钥；App 内「识别设置」只有云端识别开关。没有后台地址时仍可离线使用，但会说明云端不可用并提示核对。

## 接口与检查

`POST /api/recognize`，`Content-Type: image/jpeg`，`X-Installation-ID: UUID`，请求体为 JPEG 原始字节。成功返回：

```json
{"merchant":"测试餐厅","date":"2026-10-29","amount":"28.50"}
```

不确定字段返回 null。429 为额度/繁忙，502/503 为识别或配置不可用。App 会回退本机识别并将票据标为待核对。接口不会接受客户端指定模型、提示词或上游 URL。

无需真实密钥的本机测试，在仓库根目录运行：

```sh
python3 -m unittest discover -s backend -p 'test_*.py' -v
swiftc -module-cache-path /tmp/meal-swift-cache MealReceipts/Models.swift MealReceipts/DeepSeekOCR.swift Tests/DeepSeekTests.swift -o /tmp/meal-managed-ocr-tests
/tmp/meal-managed-ocr-tests
```

可用 `python3 backend/http_adapter.py` 启动本机 HTTP 调试服务（仅本机测试，App 生产配置只接受 HTTPS）。本地可使用 `QUOTA_DB` 指定 SQLite 数据文件；Vercel 生产没有 Redis 配置时拒绝调用，绝不回退到临时 SQLite。

## 当前保护范围

这是无账号试用版本。安装 UUID 可重新生成，IP限额会影响共用网络的用户，也可能被多IP绕过；每天全局硬上限仍在 Redis 中原子执行。想正式面向大量用户发布时，应增加用户认证或 Apple App Attest。计数上限不覆盖 Vercel、Redis 自身的请求费用；公网刷请求仍可能消耗托管额度，建议同时配置平台预算通知和流量保护。

后台代码不记录图片、小票内容、密钥或上游响应正文。Vercel/模型服务各自的基础设施日志和数据处理仍受其服务政策约束，正式发布时应在隐私政策中说明。

官方参考：[Vercel Python](https://vercel.com/docs/functions/runtimes/python)、[函数限制](https://vercel.com/docs/functions/limitations)、[大陆可达性](https://vercel.com/kb/guide/accessing-vercel-hosted-sites-from-mainland-china)、[Upstash REST](https://upstash.com/docs/redis/features/restapi)。
