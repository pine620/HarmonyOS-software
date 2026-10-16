# 食刻

食刻是一款基于 **ArkTS / ArkUI + AppGallery Connect（AGC）云开发** 的 HarmonyOS 美食推荐应用：用户发布带实拍图、价格和口味评分的“美食卡片”，在推荐流、地图和榜单中发现好味道，并通过好友、私信、群聊和“今日吃什么”一起决定吃什么。

| 项 | 值 |
| --- | --- |
| 包名 | `com.wyq.shike` |
| 版本 | 1.2.0（versionCode 1020000） |
| SDK | targetSdk `26.0.0`，compatibleSdk `6.1.1(24)` |
| 设备 | phone、tablet、2in1 |
| 云端运行时 | Node.js 20.x，数据处理位置：中国 |
| 文档更新 | 2026-10-16（按当前源码核对；官方教程链接核对于 2026-10-04） |

> 本仓库只包含源码。签名、`agconnect-services.json`、云端秘密和构建产物都不在 Git 中；**Git 推送不会部署 AGC**，云端更新需由部署负责人按 [云端指南](CloudProgram/README.md) 操作。

---

## 1. 功能概览

### 导航

| 身份 | 底部页签 | 说明 |
| --- | --- | --- |
| 游客 | 推荐 · 榜单 · 我的 | 同意隐私后即可浏览公开内容，无需定位或登录 |
| 已登录 | 推荐 · 榜单 · 好友 · 我的 | “推荐”页右下角悬浮按钮进入发布；平板/2in1 宽屏改为侧边导航栏 |

### 发现与浏览（推荐页）

- 公开推荐流：按发布时间分页，分类筛选（最多 3 类）、价格区间（外卖单品 / 到店人均）筛选。
- 搜索菜品或店名，保留本机搜索记录。
- 地图浏览店铺与店铺推荐面板（受服务端开关控制，见 §6）。
- 游客首屏优先读取维护定时器生成的首页快照（建议每 5 分钟），未配置或失败时自动回落到常规列表。

### 卡片详情

- 实拍图浏览、发布者点评、商品与价格、店铺与来源链接。
- 互动：👍 / 🖕 反应与❤️收藏，即时生效并以回执校准计数。
- “发给好友”转发到私信或群聊；**碰一碰**通过 `shike://card?cardId=…` 分享，接收方需已安装食刻。
- 举报卡片；作者可直接修改已发布内容（修订提交 / 撤回）。

### 发布

- 名称、主分类、外卖 / 到店、价格、关联店铺、1–10 分口味评分、真实点评（≤600 字）。
- 最多 6 张实拍图，首张为封面；本地重编码并去除 EXIF/GPS 后上传。
- 可选补充：外卖平台（AGC Remote Config 下发列表）、订单总额、配送费、购买日期、HTTPS 来源链接。
- 本机草稿箱：按账号隔离，新建与编辑合计最多 10 个，30 天未编辑自动清理。

### 榜单

- 高分榜：全部公开可见卡片按口味评分排名，游客可看，不需要定位。
- 好友榜：好友发布的美食推荐，登录后可见。
- 榜单由服务端生成快照并分页返回，生成期间显示“准备中”。

### 今日吃什么

- 随机翻开三张美食卡片选一个，保存“选择记录”；也可从推荐页顶部和“我的”进入。
- 桌面“今日吃什么”2×2 服务卡片。

### 社交

- 搜索并添加好友、处理好友申请、删除 / 拉黑。
- 私信（文字 / 链接 / 卡片）与群聊（建群、成员管理、退出）；前台按退避策略轮询，收到 IM 推送时立即刷新。
- 群聊内发起“一起选餐”投票（具名或匿名、截止时间、候选卡片 / 店铺），同样按退避策略刷新。

### 我的

- 我的卡片、我的收藏、浏览记录（本机）、选择记录。
- 内容管理：我的举报、删除记录（30 天内可恢复）。
- 设置：编辑资料与主页背景、修改密码、关联邮箱 / 华为账号、权限与隐私、食刻通知、桌面卡片远程同步、注销账号。
- 设置中的“管理员系统”（卡片举报审核）只对服务端白名单 `SHIKE_CARD_REVIEW_ADMIN_UIDS` 中的账号显示，每次操作仍由云端校验权限。

### 账号与登录

| 方式 | 用途 |
| --- | --- |
| 昵称 + 密码 | 主登录方式；服务端由 `SHIKE_NICKNAME_AUTH_ENABLED` 等开关控制开放 |
| 邮箱验证码 | 登录、注册、忘记密码，以及既有账号验证 |
| 华为账号 | 兼容入口，经 `shike-auth` 换取 AGC 会话，不作为业务凭据 |

### 桌面服务卡片

| 卡片 | 规格 | 内容 |
| --- | --- | --- |
| 食刻推荐 | 2×2 / 2×4 | 公开卡片摘要与封面；可选开启基于 Push 的远程更新 |
| 今日吃什么 | 2×2 | 本机候选与封面 |

---

## 2. 架构

```text
页面 (pages/components)
  → Repository / Service
    → CloudGateway ──┬─ CloudRoutes 路由表（92 个业务操作）
                     │    └─ cloudFunction.call → shike-content / shike-social / shike-account / shike-governance
                     │                            （领域函数不可用时，读操作回落到 shike-service；
                     │                              写操作只在函数模块加载失败时回落，避免重复写入）
                     ├─ cloud_objects 代理 → shike-auth（华为账号交换）、shike-media（图片准备 / 上传）
                     └─ cloudFunction.call → shike-image（批量图片读取）
                          ↓
                     Cloud DB（存储区 shike） / Cloud Storage
```

- 端侧**不直接读写 Cloud DB**；所有对象只授予 Administrator 权限，由云函数校验 AGC 用户 Token 后访问。
- 公开封面（`public/approved/**.cover-v1.jpg`）与首页快照（`public/snapshot/home-v1.json`）允许端侧经 Cloud Storage 直读，读取结果按描述符（sha256 + 大小）校验，失败回落到 `shike-image`。
- 原生邮箱会话的实拍图可直传到 `private/pending/{uid}/`，再由 `shike-media` 校验并提升为公开对象。
- 四个领域函数与 `shike-service` 运行**同一份** service runtime（由 `npm run prepare:deveco` 复制生成），只是按领域拆分扩缩与故障隔离。
- 定位只用于地图“定位到我”与权限说明，端侧不缓存、不持久化坐标。
- 客户端始终调用各函数的 `$latest` 版本；本项目不上架应用市场，不维护发布别名。

---

## 3. 目录结构

```text
shikeclouddev/
├── README.md
├── PROJECT_FILE_INDEX.md            # 文件职责索引
├── Application/                     # HarmonyOS 客户端：用 DevEco Studio 打开此目录
│   ├── AppScope/                    # 包名、版本、全局资源
│   ├── entry/src/main/
│   │   ├── ets/
│   │   │   ├── entryability/        # UIAbility：窗口、Deep Linking、接续、Push
│   │   │   ├── pages/               # 页面与 Navigation 子页（Index.ets 为主容器）
│   │   │   ├── components/          # 共用组件
│   │   │   ├── common/              # 主题、页面样式、断点、错误文本
│   │   │   ├── repository/          # 按业务封装云调用
│   │   │   ├── service/             # 会话、网关、路由、图片、缓存、定位、Push 等
│   │   │   ├── model/ mapper/       # 端云 DTO 与展示映射
│   │   │   ├── servicecard/         # 食刻推荐桌面卡片
│   │   │   └── randomfoodcard/      # 今日吃什么桌面卡片
│   │   ├── resources/               # 文案、亮/暗色、图标、页面与卡片配置
│   │   └── module.json5
│   ├── cloud_objects/               # DevEco 生成的调用代理 HAR（仅 shike-auth、shike-media）
│   └── scripts/summarize_preload_metrics.py   # 离线性能日志汇总
└── CloudProgram/                    # AGC 云端源码
    ├── README.md                    # 云端搭建、部署与环境变量
    ├── clouddb/                     # db-config.json 与 36 个对象定义
    ├── cloudfunctions/              # 10 个函数目录 + shared/ 共享模块
    ├── env-templates/               # 环境变量占位模板（无真实值）
    ├── scripts/                     # DevEco 同步、统一打包与发布检查
    └── tests/                       # Node 契约测试
```

### 云函数

| 函数 | 类型 / handler | 职责 | 端侧是否直接调用 |
| --- | --- | --- | --- |
| `shike-content` | 云对象 · `shikeContent.ShikeContent` | 推荐、搜索、地图、详情、互动、发布与修订、收藏、榜单、今日吃什么 | 是 |
| `shike-social` | 云对象 · `shikeSocial.ShikeSocial` | 好友、私信、群聊、选餐投票 | 是 |
| `shike-account` | 云对象 · `shikeAccount.ShikeAccount` | 昵称密码登录、邮箱绑定、资料、Push 与桌面卡片登记、注销 | 是 |
| `shike-governance` | 云对象 · `shikeGovernance.ShikeGovernance` | 卡片举报、审核处理与审核用图片 | 是 |
| `shike-service` | 云对象 · `shikeService.ShikeService` | 上述全部操作的维护源码与兼容回落入口 | 回落时 |
| `shike-auth` | 云对象 · `shikeAuth.ShikeAuth` | 华为账号授权码校验与 AGC 会话交换 | 是 |
| `shike-media` | 云对象 · `shikeMedia.ShikeMedia` | 图片准备、上传 / 直传确认、封面生成、内部委托 | 是 |
| `shike-image` | 事件函数 · `shikeImage.handler` | 批量图片读取与权限校验 | 是 |
| `shike-prefetch` | 事件函数 · `shikePrefetch.handler` | Cloud Foundation 预取目标，只返回首页快照 | 系统预取 |
| `shike-maintenance` | 事件函数 · `shikeMaintenance.handler` | 定时维护：首页快照、封面回填、生命周期清理、历史迁移 | 否（定时器） |

`shike-location` 已于 2026-10-16 从源码下线；已部署的旧函数可由部署负责人在 AGC 删除。

全部 HTTP 触发器保留 `HDA-SYSTEM / apigw-client` 平台鉴权，不开放免认证公网 API。`cloudfunctions/shared/` 是共享源码，不单独部署。

---

## 4. 快速开始（客户端联调）

> 接手团队已有后端时，**不需要**每人部署一套云资源。以下步骤只需“管理员已部署好测试后端”。

### 4.1 准备工具与账号

1. 安装 Git 与支持 `26.0.0` SDK 的 [DevEco Studio](https://developer.huawei.com/consumer/cn/download/deveco-studio)（已内置 HarmonyOS SDK、Node.js、Hvigor、OHPM；模拟器镜像需另下载）。
2. 注册并实名认证自己的华为开发者账号（云开发要求账号注册地为中国境内，不含港澳台）。
3. 由管理员在 [团队账号](https://developer.huawei.com/consumer/cn/console/setting/teamAccountInfoList) 添加你，并在 AGC“用户与权限”中授予：开发角色、测试项目与 `com.wyq.shike` 应用权限（两者独立）、调试证书 / Profile 权限。登录 AGC 后在右上角切换到项目所属团队。

### 4.2 获取代码并打开工程

```sh
git clone https://github.com/pine620/HarmonyOS-software.git shikeclouddev
```

1. DevEco Studio `File > Open` 选择 **`shikeclouddev/Application`**（不要打开仓库外层）。使用 ZIP 时须完整解压，确认 `Application/.idea/.gitignore` 与三个 `build-profile.json5` 存在。
2. 等待 OHPM 同步，确认识别 `entry` 与 `cloud_objects` 两个模块；`npm install` 不能代替 OHPM 同步。
3. `File > Project Structure` 核对 product `default`、target SDK `26.0.0`、compatible SDK `6.1.1(24)`，不要为消除提示降低版本。

### 4.3 补齐本地配置

| 文件 / 设置 | 获取方式 |
| --- | --- |
| `Application/AppScope/resources/rawfile/agconnect-services.json` | AGC → 开发与服务 → 约定项目 → 项目设置 → 下载。每次新克隆都要放入；缺失时发送验证码会报 `9001005 / GetRawFileContent failed` |
| 调试签名 | `Project Structure > Signing Configs` 勾选 **Associate with registered application**，登录后 `Team` 选约定团队、包名 `com.wyq.shike`。云调用要求关联注册应用的签名 |
| `CloudProgram/cloud-config.json` | 仅云端开发 / 部署成员需要，由管理员安全提供或通过 CloudDev 向导生成；核对 `teamId`、`projectId`、`appId` |

三者必须指向同一 AGC 项目与应用。提交前检查 `build-profile.json5` 差异，不提交证书路径、口令或本机签名信息。

### 4.4 运行并注册模拟器调试凭据

1. `Tools > Device Manager` 创建 API 24 及以上的手机模拟器并启动。
2. 选择模块 `entry`、构建模式 `debug`，点击 Run。同意隐私后进入游客首页；**新模拟器首次云调用失败是预期现象**。
3. 打开 HiLog，切到 **No filters**，搜索 `clouddevelopproxy.debugToken`，复制 `[clouddevelopproxy.debugToken=xxx]` 中的 `xxx`。
4. AGC → 证书、APP ID 和 Profile → **模拟器调试凭据 → 注册凭据**，选择应用并粘贴。凭据不要提交到 GitHub。
5. 重新运行：游客应能看到公开推荐与图片（无公开数据时显示空状态），再从“我的 → 登录 / 注册”用测试账号登录。

**完成标志**：同步与安装成功 → 调试凭据已注册 → 游客推荐 / 图片 / 详情可用 → 测试账号登录并读取资料 → 断点可在 Debug 会话中暂停。

验证地图浏览或发布时的店铺选点，再用模拟器 GPS 设置测试位置并授予模糊与精确位置权限；碰一碰、跨设备接续与真实性能须在真机验证。

参考：[创建模拟器](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-emulator-create) · [自动签名](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto) · [使用模拟器调试云服务](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/cloudfoundation-emulator) · [注册模拟器调试凭据](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/agc-help-add-credential-0000002415343501)

---

## 5. 云端开发与部署（部署负责人）

完整步骤见 [CloudProgram/README.md](CloudProgram/README.md)。要点：

1. **端云工程识别**：DevEco Studio 26.0.0.821 要求端云工程外层只有 `Application` 与 `CloudProgram` 两个非隐藏条目；本仓库外层含 README 与索引，需要在 IDE 内部署时按云端指南另建规范端云工程再引入源码。
2. **Cloud DB**：存储区 `shike`，部署 `clouddb/objecttype/` 的 36 个对象；只授予 Administrator 读写。已有数据的对象不得删除重建，不得修改已部署字段的类型、主键或敏感属性。历史 `CardRating` 保留。
3. **准备产物**（在 `CloudProgram/`，Node.js 20.x）：

   | 方式 | 命令 |
   | --- | --- |
   | DevEco 右键部署前同步共享源码 | `npm run prepare:deveco` → `npm run check:deveco` |
   | 打包单个云对象 / 全部云对象 | `npm run package:cloud -- shike-service` / `npm run package:cloud:all` |
   | 打包事件函数 | `npm run package:image`、`npm run package:prefetch`、`npm run package:maintenance` |
   | 部署前检查 | `npm run check:release-source`、`npm run check:artifact` |

   函数内的 `service/`、`shared/`、`media/` 目录与编译出的入口 JS 都是生成物，已被 Git 忽略，不要手改；修改 `shike-service` 或 `shared/` 后，所有使用它们的函数都要重新生成并部署。
4. **增删业务操作**时，同步修改 `shike-service/runtime.js` 操作表、`shikeService.ts`、对应领域函数 TS 和端侧 `CloudRoutes.ets` 四处（`npm run check:release-source` 会核对）。只有改了 `shike-auth` / `shike-media` 的导出方法，才需要 **Generate Invoke Interface** 更新 `Application/cloud_objects`。
5. `Sync / Overwrite` 是从云端**下载覆盖本地**，不是上传发布。

### 环境变量（名称）

秘密只放 AGC 秘密变量或团队安全渠道；`env-templates/` 仅含占位值。

| 函数 | 变量 |
| --- | --- |
| `shike-service` 及四个领域函数 | `SHIKE_DB_ZONE`、`SHIKE_STORAGE_BUCKET`、`SHIKE_MEDIA_INTERNAL_KEY`、`SHIKE_MESSAGE_ENCRYPTION_KEY`、`SHIKE_CURSOR_SIGNING_KEY`、`SHIKE_IDENTITY_TICKET_KEY`、`SHIKE_AGC_PROJECT_ID / CLIENT_ID / CLIENT_SECRET / AUTH_BASE`、`SHIKE_ACCOUNT_SIGNING_PRIVATE_KEY`、`SHIKE_CARD_REVIEW_ADMIN_UIDS`；可选 Push（`SHIKE_PUSH_*`、`SHIKE_SERVICE_CARD_*`）、附近缓存（`SHIKE_NEARBY_*`）、地图 POI（`SHIKE_HUAWEI_*`、`SHIKE_MAP_PICKER_COORDINATE_SYSTEM`）及功能开关（见下表） |
| `shike-media` | `SHIKE_DB_ZONE`、`SHIKE_STORAGE_BUCKET`、`SHIKE_MEDIA_INTERNAL_KEY`（与 service 相同）、`SHIKE_MEDIA_COVERS_VERIFIED`；`PROJECT_CREDENTIAL` 由平台注入 |
| `shike-auth` | `SHIKE_ACCOUNT_CLIENT_ID / CLIENT_SECRET`、`SHIKE_AGC_PROJECT_ID / CLIENT_ID / CLIENT_SECRET`、`SHIKE_IDENTITY_TICKET_KEY`；可选 `SHIKE_ACCOUNT_REDIRECT_URI`、`SHIKE_AGC_AUTH_BASE` |
| `shike-image` | `SHIKE_IMAGE_READ_ENABLED`、`SHIKE_DB_ZONE`、`SHIKE_STORAGE_BUCKET` |
| `shike-maintenance` | `SHIKE_MAINTENANCE_TRIGGER_KEY`（≥32 位）及 service 同组变量；定时器约定见 `timer-contract.json`（首页快照建议每 5 分钟） |

四个领域函数运行的是 service runtime，**必须配置与 `shike-service` 相同的变量**，否则相关操作会在领域函数内失败而不会自动回落。消息加密密钥为 Base64 编码的 32 字节随机值，换值会导致已有密文无法解密。

---

## 6. 功能开关与环境相关配置

### 服务端开关（环境变量）

| 开关 | 控制内容 |
| --- | --- |
| `SHIKE_NICKNAME_AUTH_ENABLED`、`SHIKE_NICKNAME_MIGRATING` | 昵称密码登录开放与迁移期 |
| `SHIKE_STAGE3_SEARCH_VERIFIED`、`SHIKE_STAGE3_MAP_VERIFIED`、`SHIKE_STAGE3_MAP_COORDINATE_SYSTEM` | 搜索与地图开放（地图要求 `GCJ02`） |
| `SHIKE_FOOD_RANKINGS_VERIFIED` | 榜单开放 |
| `SHIKE_COLLECTIONS_VERIFIED`、`SHIKE_REACTION_VERIFIED`、`SHIKE_INDEXED_QUERY_VERIFIED` | 个人集合、互动与索引查询路径 |
| `SHIKE_LIFECYCLE_VERIFIED`、`SHIKE_MAINTENANCE_ENABLED` | 生命周期清理与维护写入 |
| `SHIKE_NEARBY_CLOUD_CACHE_ENABLED` | 附近候选云缓存（默认关闭） |
| `SHIKE_IMAGE_READ_ENABLED` | `shike-image` 读取开放 |

开关在对应索引、历史数据覆盖和测试验收完成后再打开。

### 客户端常量（切换后端环境时必须核对）

| 位置 | 内容 |
| --- | --- |
| `entry/src/main/module.json5` → `metadata.client_id` | AGC 应用 ID |
| `service/ImageReadConfig.ets` → `HOME_SNAPSHOT_BUCKET` | 首页快照所在 Storage 实例，须等于目标环境的 `SHIKE_STORAGE_BUCKET` |
| `service/ImageReadConfig.ets` | 公开封面直读、首页快照、客户端直传、图片传输模式开关 |
| `service/CloudRoutes.ets` → `CLOUD_SERVICE_SPLIT_ENABLED` | 关闭后所有业务操作改走 `shike-service` |
| `service/CloudFunctionVersion.ets` | 云函数版本，固定为 `$latest` |

AGC Remote Config 键 `shike_delivery_platforms`（`version: 1` + `platforms` 数组）下发外卖平台列表；缺失或无效时使用内置默认值。

Cloud Storage 规则只开放生成的公开封面和精确的首页快照路径供匿名读取；原图、私有目录和列举保持受限；直传只允许已认证用户写入本人 `private/pending/{uid}/`。

---

## 7. 测试与验证

- 云端契约测试（在 `CloudProgram/`）：`npm run test:optimization`、`test:repair`、`test:feature-reduction`、`test:random-food`、`test:admin-notification-removal`、`test:author-direct-edit`、`test:home-prefetch`、`test:image`、`test:food-ranking`、`test:card-history`、`test:card-report`、`test:card-interaction`。`tests/nickname-auth.test.cjs` 与 `tests/card-interaction-optimization.test.cjs` 暂无脚本，可用 `node --test tests/<文件名>` 运行。根 `npm test` 是占位脚本。
- 客户端没有自动化测试，功能以真机 / 模拟器人工验收为准。
- 性能采样：临时开启 `NearbyPerformanceTrace` 后导出日志，用 `Application/scripts/summarize_preload_metrics.py` 按 phase / scenario / network 汇总 P50 / P95，验收后恢复开关。

---

## 8. 常见问题

| 现象 | 优先检查 |
| --- | --- |
| 打开后提示“目录不包含项目” | 是否打开了 `Application`；ZIP 是否完整解压、`.idea/.gitignore` 与三个 build profile 是否存在 |
| 没有 `entry` 模块 / 同步失败 | SDK 与工程要求是否配套，OHPM 同步首条错误 |
| 签名时找不到应用或无权限 | 登录团队、包名、项目 / 应用授权与有效期，调试证书 / Profile 权限 |
| 安装 `9568320 / no signature file` | 当前 product 的签名绑定与实际安装的 HAP |
| 安装 `9568332 / install sign info inconsistent` | 切换签名后卸载旧应用（不保留数据）再装 |
| 启动提示“无法验证应用，需要先联网验证” | 实际使用的 Profile 是否为调试类型 |
| 云调用 401 / 403、`create http task error`、`verify signature failed` | 模拟器调试凭据是否注册且绑定正确应用；绑错需删除后重新绑定并等待 30 分钟 |
| 找不到 `debugToken` | HiLog 是否为 No filters；是否触发了业务云调用（只发验证码不算） |
| 收不到邮箱验证码 | AGC 邮箱认证开关、垃圾箱、发送间隔 |
| 昵称登录不可用 | 服务端 `SHIKE_NICKNAME_AUTH_ENABLED` 与迁移状态 |
| 首页为空 | 区分空状态与错误；`shike-content` 版本、FoodCard 公开状态与索引；首页不需要定位 |
| 首页快照始终未命中 | `HOME_SNAPSHOT_BUCKET` 与目标环境一致、Storage 规则、maintenance 定时器 `action=home-snapshot` |
| 日志出现 `domain-unavailable` | 领域函数缺少生成的 `service/` 目录或依赖；重新 `prepare:deveco` / 打包后部署 |
| 图片显示可重试占位 | `shike-image` 是否部署并开启、`shike-media` 产物是否含共享模块与生产依赖 |
| 地图或搜索入口不出现 | 对应 `SHIKE_STAGE3_*` 开关与坐标系配置 |
| 设置里没有“管理员系统” | 当前账号 canonical UID 是否在 shike-service / shike-governance 的 `SHIKE_CARD_REVIEW_ADMIN_UIDS` 中 |

反馈问题时提供：操作步骤、预期 / 实际、首条完整错误及前后约 20 行脱敏日志、DevEco / SDK / 镜像版本与截图。遮盖邮箱、Token、调试凭据、验证码、密钥与密码。

---

## 9. 协作约定

- 从约定开发分支创建功能分支，通过 Pull Request 合并。
- 不提交：签名材料、`agconnect-services.json`、`cloud-config.json`、环境变量值、`node_modules` / `oh_modules`、`build` 产物、函数内生成副本。
- 新增、移动或删除源码文件后同步更新 [PROJECT_FILE_INDEX.md](PROJECT_FILE_INDEX.md)。
- 新增业务操作：runtime → `shikeService.ts` 与对应领域函数 → `CloudRoutes.ets` → Repository / DTO → 页面；各处方法表保持一致。
- 部署后记录函数名、云版本、Git 提交与部署人，并通知共用同一后端的成员。

## 10. 文档与参考

| 文档 | 内容 |
| --- | --- |
| [CloudProgram/README.md](CloudProgram/README.md) | 从零搭建后端、部署、环境变量、调试云对象 |
| [PROJECT_FILE_INDEX.md](PROJECT_FILE_INDEX.md) | 目录与文件职责 |

官方资料：[DevEco Studio 安装](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-software-install) · [云开发账号准备](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-account) · [管理团队帐号](https://developer.huawei.com/consumer/cn/doc/app/agc-help-manageaccount-0000002306610129) · [获取 SDK 配置文件](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/harmony-api6-obtain-files-0000001553463638) · [CloudDev 管理面板](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-console) · [创建 / 关联端云工程](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-create-appproject) · [ArkTS 调试](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-debug-arkts-debug) · [模拟器与真机差异](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-emulator-specification)
