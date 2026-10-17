# 食刻云端（CloudProgram）

本目录是食刻的 AGC 云开发源码：**7 个云对象、3 个事件函数、36 个 Cloud DB 对象定义**，以及统一打包脚本和 Node 契约测试。客户端第一次运行见 [项目 README](../README.md)，逐文件职责见 [索引](../PROJECT_FILE_INDEX.md)。

> 源码状态核对日期 2026-10-17。Git 推送不会部署 AGC；本 README 中的打包、部署、开关调整均由部署负责人执行。

---

## 1. 目录结构

```text
CloudProgram/
├── README.md                    本文件
├── package.json                 打包 / 检查 / 测试脚本入口（npm run …）
├── cloud-config.json            本地生成的团队 / 项目 / 应用关联元数据（不提交真实配置）
├── AppScope/resources/rawfile/schema.json   平台生成的 schema 快照（检查脚本以它对照 objecttype）
├── clouddb/
│   ├── db-config.json           默认存储区 shike 与数据处理位置
│   └── objecttype/*.json        36 个对象：字段、主键、索引、权限
├── cloudfunctions/
│   ├── shared/                  共享模块（唯一维护处，不单独部署）
│   ├── shike-service/           全部 90 个业务操作的维护源码 + 兼容回落入口
│   ├── shike-content/ …social/ …account/ …governance/   四个领域云对象（只有 TS 入口与配置）
│   ├── shike-auth/              华为账号兼容登录
│   ├── shike-media/             所有 Cloud Storage 读写、封面生成
│   ├── shike-image/             批量图片读取（事件函数）
│   ├── shike-prefetch/          首页快照预取（事件函数）
│   └── shike-maintenance/       定时维护（事件函数）+ timer-contract.json
├── env-templates/               环境变量占位模板（只有占位值）
├── scripts/                     prepare-deveco / 统一打包 / 产物与源码检查
└── tests/*.test.cjs             契约测试（node --test）
```

### 1.1 每个函数目录里有什么

| 文件 | 作用 |
| --- | --- |
| `shike*.ts` / `shike*.js` | 入口：云对象为 TS 类（方法名即客户端调用的方法），事件函数为 `handler` |
| `runtime.js` | 业务实现（auth / media / service 才有；领域函数运行 `service/` 下的副本） |
| `function-config.json` | handler、functionType（1 云对象 / 0 事件函数）、HTTP 触发器鉴权 |
| `package.json` + `package-lock.json` | 该函数独立的生产依赖（Node 20.x），两者 dependencies 必须一致 |
| `tsconfig.json` | 云对象 TS 入口编译为 CommonJS |

### 1.2 共享源码与生成副本

- **唯一维护源码**：`cloudfunctions/shared/`、`shike-service/`、`shike-media/`。
- **生成副本（已 Git 忽略，不要手改）**：各函数内的 `shared/`；`shike-{content,social,account,governance,maintenance}/service/`；`shike-maintenance/media/`；编译出的 `shike*.js(.map)`。
- 生成方式：打包器和 `prepare-deveco` 从入口文件出发递归跟踪 `require('./…')`，把 `./shared/` 映射到 `cloudfunctions/shared/`、`./service/` 映射到 `shike-service/`、`./media/` 映射到 `shike-media/`（规则在 `scripts/function-layout.mjs`）。新增共享模块只要被 `require`，就会自动随包。
- 改了 `shared/` 或 `shike-service/` 后，**所有用到它们的函数都要重新生成并部署**；否则线上会运行旧副本。

### 1.3 shared/ 模块

| 文件 | 职责 |
| --- | --- |
| `cloud-operation.js` | service 与四个领域云对象共用的“执行操作 + 包装响应”（请求号、构建信息、昵称登录错误脱敏、互动耗时日志） |
| `content-policy.js` | 内容可见性策略（卡片 / 作者 / 图片 / 修订 / 审核读取资格）；其 sha256 即响应中的 `policyHash` |
| `image-models.js` | Cloud DB 模型基类 `CloudDbModel` 与 `CardMedia` 模型 |
| `image-reader.js` | 图片读取与权限校验（`shike-image` 与旧接口共用） |
| `media-descriptor.js` | 图片描述符（原图 / 480 封面的 sha256、大小）与字节校验 |
| `public-snapshot.js` | 游客首页快照的生成、校验与读取 |
| `read-errors.js` | 统一错误响应、请求号、读取指标采样 |
| `release-info.js` | 构建信息（buildId / policyHash / protocolVersion） |
| `card-review-access.js` | 审核员图片准入 |

### 1.4 shike-service 内部模块

`runtime.js` 是请求入口与通用能力（身份校验与缓存、模型、私信加密、Push、卡片读取组装、推荐流、好友 / 私信 / 群聊、操作表），其余按业务拆分并通过依赖注入装配：

| 模块 | 业务 |
| --- | --- |
| `stage1-services.js` | 发布回执、作者修改（修订 / 撤回）、软删除、注销、历史数据维护 |
| `stage2-services.js` | 商家（官方点 / 用户点）、价格与分类字段、商家计数对账 |
| `stage3-services.js` | 地图商家、公开搜索、店铺推荐与开放门槛 |
| `stage6-services.js` | 群内选餐投票 |
| `stage7-services.js` | 用户主页、赞踩 |
| `stages47-common.js` | 游标签名、分页、哈希等共用工具 |
| `card-interaction-services.js` | 卡片互动（反应 / 收藏）状态、回执与计数 |
| `personal-collections.js` | 收藏集合与历史迁移、卡片预览 |
| `food-ranking-services.js` / `random-food-services.js` | 榜单 / 今日吃什么 |
| `card-report-services.js` | 卡片举报与审核处理 |
| `lifecycle-services.js` / `authentication-cleanup.js` | 删除记录恢复、生命周期清理、认证用户删除 |
| `nickname-auth.js` | 昵称密码登录 |

### 1.5 增删一个业务操作

同步修改 4 处并保持一致：`shike-service/runtime.js` 的 `operations` 表 → `shikeService.ts` 方法 → 对应领域函数 TS 方法 → 客户端 `Application/entry/src/main/ets/service/CloudRoutes.ets`。`npm run check:release-source` 会核对方法表、已退役操作不被加回。service 与领域函数由客户端 `cloudFunction.call` 调用，**不要**为它们生成调用代理；只有改了 `shike-auth` / `shike-media` 的导出方法或参数模型，才右击该云对象 **Generate Invoke Interface**，目标选 `Application/cloud_objects`。

---

## 2. 团队、项目与分工

| 成员工作 | 需要的访问范围 | 首次应看到的结果 |
| --- | --- | --- |
| 客户端联调 | 测试项目与 `com.wyq.shike` 应用、配置下载、调试证书 / Profile；模拟器凭据可由管理员登记 | 应用可见、SDK 配置可下载、关联应用签名能完成 |
| 云函数开发 / 部署 | 云开发角色及目标项目权限、函数配置 / 部署 / 日志权限 | CloudDev 指向正确项目，10 个函数可见 |
| 数据 / 存储维护 | Cloud DB / Storage 资源管理权限 | 可核对 shike 存储区、对象定义、存储实例与规则 |
| 团队 / 协议管理 | 管理用户及访问权限；云开发协议由持有者 / 法务签署 | 成员授权与服务协议已完成 |

- AGC 成员角色与 Cloud DB 对象里的 Administrator 权限是两回事：后者只供受控服务端访问，不能为联调而开放设备用户直接读写。
- 开发前由负责人给出团队、测试项目 / 应用标识、区域、端云分支和云端生效版本，并明确谁部署、谁维护 DB、谁管理秘密。
- 同一函数的 `$latest` 被更新会影响所有连接该后端的成员，部署前同步变更范围，完成后记录版本。

**打开 CloudDev**：本仓库外层含 README 和索引，不满足 DevEco Studio 26.0.0.821 的端云双目录识别条件。需要 IDE 内云端开发 / 部署时，另建外层只有 `Application`、`CloudProgram` 两个非隐藏条目的规范端云工程再引入源码，关联团队已有应用；进入 `Tools > CloudDev` 用个人团队账号 `Sign in`，经 `Serverless > Cloud Functions / Cloud DB > Go to console` 核对项目。`cloud-config.json` 的 `teamId`、`projectId`、`appId` 必须与负责人提供的一致，且不上传 GitHub。

参考：[团队帐号管理](https://developer.huawei.com/consumer/cn/doc/app/agc-help-manageaccount-0000002306610129) · [CloudDev 管理面板](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-console)

---

## 3. 从零搭建一套后端

已有后端且只做联调时跳过本节。

### 3.1 AGC 项目与应用

1. 在约定团队登录 [AGC](https://developer.huawei.com/consumer/cn/service/josp/agc/index.html)，创建项目并启用数据处理位置**中国**；创建 HarmonyOS 应用，包名与 `Application/AppScope/app.json5` 一致：`com.wyq.shike`。
2. DevEco `File > New > Create Project` 选 **Application > [CloudDev]Empty Ability**，在**单独的临时目录**用相同包名关联该应用，生成 `CloudProgram/cloud-config.json`。模板里的示例对象和函数不是食刻资源，不要整体覆盖本项目。
3. 团队未签署云开发协议时由持有者 / 法务签署；在 Notifications 检查云函数 / DB / Storage 开通状态。
4. 项目认证服务开启**邮箱认证**；从正确应用下载 `agconnect-services.json` 放入 `Application/AppScope/resources/rawfile/`。

参考：[创建 / 关联云开发工程](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-create-appproject) · [已有端工程迁移](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-project-migration)

### 3.2 Cloud DB

1. 建立中国区存储区 **`shike`**（与 `clouddb/db-config.json` 及服务端默认值一致）。
2. 右击 **clouddb > Deploy Cloud DB**，等待 `Deploy successfully`，在控制台核对 36 个对象与存储区。
3. 所有对象只给 **Administrator：Read / Upsert / Delete**，World / Authenticated / Creator 不开放。

| 对象组 | 对象 |
| --- | --- |
| 用户 / 身份 | `UserProfile`、`IdentityBinding`（provider UID → 业务 UID）、`AuthMigrationTicket`、`NicknameClaim`、`PasswordCredential`、`PasswordThrottle` |
| 内容 / 媒体 | `FoodCard`、`CardMedia`、`FoodCardRevision`、`PublishRequestRecord`（幂等回执） |
| 商家 | `Merchant` |
| 互动 / 治理 | `CardReaction`（新赞踩）、`CardAction`（旧 LIKE 与收藏）、`CardRating`（历史保留）、`Report`、`CardComment` / `CommentReaction`（历史评论数据） |
| 好友 / 私信 / 群聊 | `Friendship`、`FriendReport`、`Conversation`、`ChatMessage`、`GroupConversation`、`GroupMember`、`GroupMessage` |
| 个人内容 / 投票 | `PersonalFoodState`、`TastePreference`、`FoodList`、`FoodListItem`、`MealChoiceHistory`、`MealPoll`、`MealPollOption`、`MealPollVote` |
| 通知 / 卡片 / 任务 | `NotificationEvent`、`PushRegistration`、`WidgetRegistration`、`MaintenanceJob` |

**已有数据的项目**：已部署字段的类型、主键、敏感属性不能直接改；有数据的对象 / 存储区不采用“删除重建”。新增结构先制定迁移方案，由管理员操作并导出核对。当前部署以 `clouddb/objecttype/` 为准（FoodCard 含 15 个索引、Merchant 含 5 个，核对时包含字段顺序与 ASC/DESC）。String 字段上限 200 字符，正文 / 长链接用 Text；消息正文、链接、摘要和 Token 是服务端 AES-256-GCM 密文，不改成明文。对象定义与各 runtime 的 `fieldTypes`、主键、索引和销户清理必须同步。参见 [部署云数据库](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-deploydatabase)。

### 3.3 Cloud Storage

1. 创建一个中国区 AGC Cloud Storage 实例，完整实例名用于 `SHIKE_STORAGE_BUCKET`（不使用 OBS）。
2. 存储规则只开放：生成的公开封面 `public/approved/**.cover-v1.jpg` 与精确的首页快照 `public/snapshot/home-v1.json` 匿名读；已认证用户只能写本人 `private/pending/{uid}/`。原图、其他私有对象和目录列举保持受限。
3. 存储访问使用 AGC 注入的 `PROJECT_CREDENTIAL`，不要自行创建或复制。
4. 客户端 `service/ImageReadConfig.ets` 的 `HOME_SNAPSHOT_BUCKET` 要等于该实例名。

---

## 4. 环境变量

只放入对应函数的 AGC 配置，秘密使用秘密变量；仓库不保存真实值，`env-templates/` 只有占位。接手已有后端时先核对现有配置，不覆盖完整变量集。

| 函数 | 必需 | 可选 / 开关 |
| --- | --- | --- |
| `shike-service` 与 4 个领域函数（**变量集必须完全相同**） | `SHIKE_DB_ZONE=shike`、`SHIKE_STORAGE_BUCKET`、`SHIKE_MEDIA_INTERNAL_KEY`、`SHIKE_MESSAGE_ENCRYPTION_KEY`、`SHIKE_CURSOR_SIGNING_KEY`、`SHIKE_IDENTITY_TICKET_KEY`、`SHIKE_CARD_REVIEW_ADMIN_UIDS`；昵称登录另需 `SHIKE_AGC_PROJECT_ID / CLIENT_ID / CLIENT_SECRET`、`SHIKE_ACCOUNT_SIGNING_PRIVATE_KEY`（可选 `SHIKE_AGC_AUTH_BASE`） | 功能开关（见根 README §5）；Push（§7）；地图选点 / POI：`SHIKE_MAP_PICKER_COORDINATE_SYSTEM`、`SHIKE_HUAWEI_POI_VERIFIED`、`SHIKE_HUAWEI_POI_COORDINATE_SYSTEM`、`SHIKE_HUAWEI_SITE_API_KEY`（秘密）；扫描预算：`SHIKE_STAGE3_MAP_SCAN_BUDGET`、`SHIKE_STAGE3_CARD_SCAN_BUDGET`、`SHIKE_STAGE3_MAX_VIEWPORT_SPAN`；读取指标：`SHIKE_READ_METRICS_ENABLED`、`SHIKE_READ_METRICS_SAMPLE_RATE`；测试环境恢复期：`SHIKE_ENVIRONMENT=test` + `SHIKE_TEST_RECOVERY_SECONDS` |
| `shike-media` | `SHIKE_DB_ZONE`、`SHIKE_STORAGE_BUCKET`、`SHIKE_MEDIA_INTERNAL_KEY`（与 service 相同）；`PROJECT_CREDENTIAL` 由平台注入 | `SHIKE_MEDIA_COVERS_VERIFIED` |
| `shike-auth` | `SHIKE_ACCOUNT_CLIENT_ID / CLIENT_SECRET`、`SHIKE_AGC_PROJECT_ID / CLIENT_ID / CLIENT_SECRET`、`SHIKE_IDENTITY_TICKET_KEY`（与 service 相同） | `SHIKE_ACCOUNT_REDIRECT_URI`、`SHIKE_AGC_AUTH_BASE` |
| `shike-image` | `SHIKE_IMAGE_READ_ENABLED`、`SHIKE_DB_ZONE`、`SHIKE_STORAGE_BUCKET`、`PROJECT_CREDENTIAL`（模板 `env-templates/shike-image.env.example.json`） | — |
| `shike-prefetch` | `SHIKE_STORAGE_BUCKET`、`PROJECT_CREDENTIAL` | — |
| `shike-maintenance` | `SHIKE_MAINTENANCE_TRIGGER_KEY`（≥32 位）及 service 同组变量 | `SHIKE_MAINTENANCE_ENABLED`、`SHIKE_LIFECYCLE_VERIFIED`、`SHIKE_MEDIA_COVERS_VERIFIED`、`SHIKE_NICKNAME_MIGRATING` |

要点：

- 四个领域函数运行的是 service runtime，**缺少变量时请求在领域函数内失败，不会自动回落**。
- `SHIKE_MEDIA_INTERNAL_KEY`：service / media 相同的高熵秘密，用于 60 秒有效的 HMAC 委托。
- `SHIKE_MESSAGE_ENCRYPTION_KEY`：**Base64 编码的 32 字节随机值**，稳定保管；换值会导致已有密文无法解密。
- `SHIKE_IDENTITY_TICKET_KEY`：auth / service 完全一致，迁移票据 10 分钟有效、一次性消费。Account Kit 与 AGC 客户端秘密用途不同，不互相替代；华为账号功能还需包名、证书指纹和 Redirect URI 匹配。
- `SHIKE_CARD_REVIEW_ADMIN_UIDS`：JSON 字符串数组，最多 100 个 canonical UID，配置到 service 与 governance（模板 `shike-tester-review-access.env.example.json`）。
- 昵称登录：按 `shike-service-nickname-auth.env.example.json` 与 maintenance 模板配置；开始保持 `SHIKE_NICKNAME_AUTH_ENABLED=false`、`SHIKE_NICKNAME_MIGRATING=true`，迁移验证后再调整。
- 地图首发要求 `SHIKE_STAGE3_MAP_COORDINATE_SYSTEM=GCJ02`；可靠可见商家混入 WGS84 时不开放地图。`SHIKE_INDEXED_QUERY_VERIFIED` 只在历史迁移覆盖完成、索引查询验收后启用。

---

## 5. 打包与部署

所有命令在 `CloudProgram/` 用 **Node.js 20.x** 执行，只准备本地产物，不会自动部署 AGC。

| 目的 | 命令 |
| --- | --- |
| 为 DevEco 右键部署生成函数内副本 / 检查是否最新 | `npm run prepare:deveco` / `npm run check:deveco` |
| 打包单个 / 全部云对象（ZIP） | `npm run package:cloud -- shike-service` / `npm run package:cloud:all` |
| 打包事件函数 | `npm run package:image`、`npm run package:prefetch`、`npm run package:maintenance`（或 `node scripts/package-functions.mjs <函数名>`） |
| 校验已解压的产物 | `node scripts/check-artifact.mjs <目录>`（`npm run check:artifact`） |
| 发布前源码检查 | `npm run check:release-source` |

统一打包器（`scripts/package-functions.mjs`）会：校验 function-config 与 package/lock → `npm ci` 并编译 TS 入口 → 递归复制本地依赖 → 安装生产依赖 → 生成含每个文件 sha256 的 `shared/release-manifest.json`（buildId / policyHash / schemaHash）→ 压缩到 `build/cloud/` 并自检。

部署步骤：

1. 每个函数选 **Node.js 20.x**，保留 `function-config.json` 的 functionType 与 `HDA-SYSTEM / apigw-client` 鉴权，不开放免认证 HTTP。
2. 数据库 / 环境就绪后按 **auth → media → service → content / social / account / governance** 部署，再单独部署 `shike-image`、`shike-prefetch`、`shike-maintenance`。已有后端只更新涉及的函数。
3. 控制台核对函数名、handler、运行时、变量和生效版本，记录部署人、Git 提交与云版本，通知同一后端的成员。
4. 由成员验证邮箱登录、图片、推荐流与发布；控制台“部署成功”不等于端云联调成功。

注意：

- 批量 `Deploy Cloud Functions` 会部署目录内全部对象，`Deploy Cloud Program` 还涉及整套云资源；已有数据时优先单函数部署。
- **`Sync … / Overwrite` 是从云端下载覆盖本地**（会生成备份），不是上传发布。
- 部署后 `Cannot find module './runtime'` 或 `./shared/…`：检查产物是否由最新源码生成、文件同级与大小写；`Cannot find package`：检查生产依赖。

参考：[部署云对象](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-deploycloudobj) · [生成调用代理](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-invokecloudobj) · [整工程部署](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-deploy) · [同步云端代码](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-sync)

---

## 6. 定时维护、首页快照与图片读取

### shike-maintenance

无 HTTP 触发器，由 AGC 控制台定时器调用；请求体须带与 `SHIKE_MAINTENANCE_TRIGGER_KEY` 一致的 `workerToken`。推荐配置见 `shike-maintenance/timer-contract.json`（只是约定，**不会自动创建定时器**）。

| action | 作用 |
| --- | --- |
| `home-snapshot` | 生成游客首页快照 `public/snapshot/home-v1.json`（建议每 5 分钟） |
| `lifecycle`（默认） | 执行到期清理任务（删卡、注销、会话清理），每次最多 3 个任务 |
| `media-covers` | 逐张回填旧图片的 480px 封面（需 `SHIKE_MEDIA_COVERS_VERIFIED=true`） |
| `card-history` / `reaction-history` | 历史卡片 / 赞踩数据维护（`mode`：status / initialize / run / retry） |
| `public-content` | 公开内容整理与商家计数对账（按 `cursor` 分批） |
| `nickname-claims` | 昵称数据迁移 |

### 首页快照

客户端 `HomeSnapshotReader.ets` 优先用 Cloud Foundation 预取结果（`shike-prefetch`）或直读快照文件，超过 15 分钟、格式不对或读取失败时回落到常规列表。快照内容与匿名调用 `list-nearby-cards` 第一页完全相同，不含任何查看者数据。

### 图片读取

- 客户端 `ImageReadConfig.ets` 使用 `BATCH` 模式经 `shike-image` 批量读图，默认关闭 `NOT_SUPPORTED` 自动回退；未部署或 `SHIKE_IMAGE_READ_ENABLED=false` 时图片显示可重试占位。先在测试环境保持关闭、确认关闭响应，再验收后开启。
- 公开 / 审核 / 修订图片的可见资格始终由服务端检查；新缓存复用只代表文件有效，展示权限仍需重新确认。
- 职责分离：`shared/image-reader.js` 读取并校验权限；`shike-media/cover-converter.js`、`cover-worker.js` 生成封面；maintenance 负责回填与定时。

---

## 7. 可选：Push 与桌面卡片远程更新

在 AGC 开通 Push Kit，创建服务账号 / 密钥，重新申请含 Push 权益的 Profile，然后给 service 与四个领域函数（变量集保持一致）配置：

| 变量 | 内容 |
| --- | --- |
| `SHIKE_PUSH_PROJECT_ID` | AGC 项目 ID |
| `SHIKE_PUSH_SUB_ACCOUNT` | 服务账号标识（秘密） |
| `SHIKE_PUSH_KEY_ID` | 服务账号密钥 ID |
| `SHIKE_PUSH_PRIVATE_KEY_BASE64` | 服务账号 PEM 私钥的 Base64（秘密） |
| `SHIKE_SERVICE_CARD_DAILY_PUSH_LIMIT` | 每卡片实例每日 1–5 次，默认 2 |
| `SHIKE_SERVICE_CARD_TEST_MESSAGE` | 仅联调可设 true，平时保持 false |

通知与桌面卡片同步由用户分别开启，Token 加密存储；每设备最多登记 16 张、每账号最多 100 张卡片。远程摘要从当前 APPROVED 卡片重新生成，客户端不提交任意文本或模块 / Ability 名。Push 失败不回滚业务消息。未配置 Push 时社交通知与卡片远程更新静默跳过。

---

## 8. 调试云对象

1. **本地断点**：右击目标云对象选 `Debug 'shike-xxx'`，出现 `Cloud Functions loaded successfully` 后在 TS 包装层或 runtime 设断点；修改后需停止并重新 Debug。
2. `View > Tool Windows > Cloud Functions Requestor`：选择函数、`Environment=Local`、导出 Method，Event 填**方法参数数组**；要查线上代码选 `Remote`（需先部署，不会命中本地断点）。
3. 示例（service 的只读 `listMyCards`）——Event 是数组内一个对象，不能填短横线操作名，也不能写成 JSON 字符串：

   ```json
   [{ "accessToken": "<自己的有效测试用户 AGC Access Token>", "payload": {} }]
   ```

4. 有效 Token 只在自己的受控调试环境使用，不保存、不截图、不贴到聊天；无效占位 Token 被拒绝是正常结果。
5. 预期：成功响应 `ok=true`（无本人卡片时允许空数据）。失败时反馈 Method、Local / Remote、首个错误、文件 / 行号、云版本和脱敏日志。

参考：[调试云对象](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-debugcloudobj)

---

## 9. 测试

契约测试位于 `tests/`，由负责人手动运行（`npm run test:*`，完整列表见根 README §6）。部分测试会按函数名截取 `shike-service/runtime.js` 等源码片段在 `vm` 沙箱中执行，或用正则读取模型的 `fieldTypes` / `indexes` 单行定义——**重命名、移动这些函数或把模型定义改成多行时，要同步测试中的锚点**。根 `npm test` 是占位脚本，不是验收套件。

---

## 10. 历史与兼容说明

- 已下线：`shike-location` 函数、旧分享函数与托管网页（端侧改用 `shike://card?cardId=…` 应用内分享）、按发布位置的旧“附近”接口及其可选 Redis 候选缓存（`SHIKE_NEARBY_*` 变量不再有任何作用，可在 AGC 删除）。已部署的旧函数 / 资源是否删除由部署负责人确认兼容范围后处理。
- `FriendContentAccessGrant` 已从源码移除，但不能据此删除线上历史对象或数据；`CardRating`、`CardComment` / `CommentReaction` 同样保留历史数据。
- `ioredis` 依赖目前仍保留在 service、四个领域函数与 maintenance 的 `package.json` 中，代码已不再加载它；移除需在 Node 20 下重新 `npm install` 更新 lock 后再打包。

AGC 服务接入参考：[邮箱认证](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-auth-harmonyts-login-email-0000001522426989) · [云服务模拟器调试](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/cloudfoundation-emulator)
