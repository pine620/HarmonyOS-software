# 云端搭建与部署

本目录包含 4 个 AGC 云对象、3 个独立云函数（图片读取 / 公开分享 HTTP / 定时维护）、32 个 Cloud DB 对象定义及环境变量配置说明。客户端第一次运行见 [项目 README](../README.md)，各文件职责见 [索引](../PROJECT_FILE_INDEX.md)。源码状态更新日期为 2026-10-09，官方操作资料核对日期仍为 2026-10-02。

## 0. 先确定团队、项目与分工

### 加入已有团队后端

管理员添加成员、授予角色/项目/应用/调试签名权限，新成员切换团队的完整步骤见 [README：加入 AGC 团队](../README.md#agc-team)。先完成授权，再登录 DevEco；克隆 Git 仓库不自动获得云端权限。

| 成员工作 | 需要确认的访问范围 | 首次应看到的结果 |
| --- | --- | --- |
| 客户端联调 | 测试项目与 com.wyq.shike 应用、配置下载、调试证书/Profile；模拟器凭据可由管理员登记 | 应用可见、SDK 配置可下载、关联应用签名能完成 |
| 云对象开发/部署 | 云开发对应角色及目标项目权限、函数配置/部署/日志权限 | CloudDev 指向正确项目，四个对象可见，承担部署的成员能执行相应操作 |
| 数据/存储维护 | Cloud DB/Storage 资源管理权限及管理员约定的操作范围 | 可核对 shike 存储区、对象定义、存储实例与规则 |
| 团队/协议管理 | 管理用户及访问权限；云开发协议签署由持有者/法务负责 | 成员授权与服务协议已完成 |

角色以控制台的实际权限列表为准，不把“已选开发角色”当成所有操作都已授权。AGC 成员角色与 Cloud DB 数据对象里的 Administrator 权限属于不同层次：后者供受控服务端访问，不能为了让成员联调而开放设备用户直接读写。

开发开始前，由负责人给出团队、测试项目/应用标识、区域、端云分支/提交和云端生效版本；明确谁部署、谁维护 DB、谁管理秘密。同一函数的 `$latest` 被更新会影响所有连接该后端的成员，部署前同步变更范围与兼容性，完成后记录版本。个人本地修改不会自动更新云端。

### 打开和核对 CloudDev

首次客户端运行打开 `Application`。本仓库外层含 README 和索引，不满足 DevEco Studio 26.0.0.821 的端云双目录识别条件；不要仅补一个 cloud-config.json 后就打开外层。需要 IDE 内云端开发/部署时，按第 1 节创建或按官方流程迁移规范端云工程，保留外层仅有 `Application`、`CloudProgram` 两个非隐藏条目的结构，再引入本项目源码并关联团队已有应用。进入 `Tools > CloudDev`，用个人团队账号 `Sign in`，通过 `Serverless > Cloud Functions / Cloud DB > Go to console`核对项目。

`cloud-config.json`里 appSelected 的 appId/projectId 和 teamId 应与负责人提供的身份一致。这份本地关联配置不上传 GitHub。首次接手可由管理员通过安全渠道提供测试项目的配置，也可使用下面官方创建向导关联同一应用并生成；成员登录/权限由平台处理，不手写 uid 来授权。

参考官方[团队帐号管理](https://developer.huawei.com/consumer/cn/doc/app/agc-help-manageaccount-0000002306610129)、[CloudDev 管理面板](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-console)。

## 1. 创建 AGC 项目与应用

已有后端且只做联调时跳过本节。以下用于负责人从零初始化一套后端；同包名应用的归属由平台规则约束，若需不同包名的隔离测试应用，先统一客户端身份与平台配置，不随意更改主项目包名。

1. 在约定团队中登录 [AGC](https://developer.huawei.com/consumer/cn/service/josp/agc/index.html)，从“开发与服务”创建项目，启用数据处理位置**中国**；创建/选择 HarmonyOS **应用**，包名与 `Application/AppScope/app.json5`一致：`com.wyq.shike`，并确认应用已归属该项目。
2. 在 DevEco 欢迎页 `Create Project`或 `File > New > Create Project`选择 **Application > [CloudDev]Empty Ability**。若需为现有源码补生成关联配置，使用单独的临时工程目录，不覆盖本项目。
3. 在工程信息页填相同 Bundle name，点击 Next；登录自己的开发者账号，`Team`选约定团队。向导按包名查询应用，核对其 APP ID、所属项目和中国数据处理位置，再选择 Finish。查询不到时排查包名、团队、应用授权；游离应用需先由管理员关联项目。
4. 团队尚未签署云开发协议时，请持有者/法务签署。等待初始化、OHPM/npm 同步；在 Notifications 检查云函数/DB/Storage 开通状态。失败从 CloudDev 控制台入口处理；欠费/服务协议问题交负责人。
5. 用向导生成的 `CloudProgram/cloud-config.json`作为这套后端的关联配置。临时模板中的 Post、示例数据和 id-generator 不是食刻资源；保留本项目的 Application 源码、四个云对象及二十五个对象定义，不整体用模板替换。
6. AGC 项目认证服务开启**邮箱认证**。从正确应用下载 agconnect-services.json，按根 README 放入 `Application/AppScope/resources/rawfile`；当前 AGC SDK 默认初始化读取应用级资源。客户端生成自己的关联应用调试签名。华为兼容登录、Push 和缓存按后文另配置。

官方资料：[创建/关联 HarmonyOS 云开发工程](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-create-appproject)、[已有端工程迁移](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-project-migration)。客户端接手无需重新迁移；需要 IDE 内云端开发时，先满足第 0 节的端云工程识别条件，并复用团队已有 AGC 资源。

## 2. Cloud DB 和 Storage

1. 建立中国区 Cloud DB 存储区 **`shike`**，与 `clouddb/db-config.json` 及服务端默认值一致。
2. DevEco 右击 **clouddb > Deploy Cloud DB**，等待 `Deploy successfully`；从 `Tools > CloudDev > Serverless > Cloud DB > Go to console`检查“对象类型”“存储区”“数据”页签，确认 `objecttype/`下 32 个对象与目标 shike 存储区。部署前核对项目，不覆盖结构不同的已有对象。
3. 所有对象仅给 **Administrator：Read/Upsert/Delete**，World/Authenticated/Creator 不开放权限。
4. 创建一个中国区 AGC Cloud Storage 实例，把完整实例名用于 `SHIKE_STORAGE_BUCKET`。不使用 OBS，不开放客户端或匿名直接读写/列举 `public/approved/` 图片目录。
5. 图片由 shike-media 使用平台项目凭证处理；设备只通过鉴权媒体接口访问。`PROJECT_CREDENTIAL` 由 AGC 注入，不自行创建或复制。

| 对象组 | 对象与职责 |
| --- | --- |
| 用户/身份 | UserProfile：资料与媒体引用；IdentityBinding：provider UID 到业务 UID；AuthMigrationTicket：一次性票据消费审计 |
| 内容/媒体 | FoodCard：商品、价格、口味、E3 位置与状态；CardMedia：图片归属、路径、摘要、尺寸和卡片关联 |
| 商家 | Merchant：官方点／用户点、坐标系、审核状态、地图资格与公开推荐计数 |
| 卡片互动 | Report：举报；CardAction：旧 LIKE 与独立收藏；CardReaction：新赞踩；CardComment / CommentReaction：保留历史评论数据和旧接口 |
| 版本/权限/任务 | FoodCardRevision：待审编辑版本；FriendContentAccessGrant：方向授权；PublishRequestRecord：请求回执；MaintenanceJob：迁移、会话及生命周期任务 |
| 好友/私信 | Friendship：关系/申请；FriendReport：用户举报；Conversation：会话/未读；ChatMessage：TEXT/CARD/LINK |
| 群聊 | GroupConversation：群资料/摘要；GroupMember：角色/未读；GroupMessage：文字/卡片 |
| 个人内容 | TastePreference：口味偏好；FoodList / FoodListItem：私人清单；PersonalFoodState：个人食物状态 |
| 群投票 | MealPoll / MealPollOption / MealPollVote：投票、选项与投票记录 |
| 通知/卡片 | NotificationEvent：站内事件；PushRegistration：系统通知设备登记；WidgetRegistration：桌面卡片实例登记 |

**已有数据的项目：**保留历史 CardRating 及其数据。AppScope/schema.json 是平台生成的快照，客户端与云端快照可能处于不同代次；当前部署以 `clouddb/objecttype/` 的 32 个定义为准。已部署字段的类型、主键和敏感属性不能直接更改；新增结构先制定迁移方案，由管理员操作并导出核对。当前 FoodCard 定义含 16 个索引，Merchant 含 4 个索引，核对时包含字段顺序与 ASC/DESC。

String 字段有 200 字符上限，正文/长链接采用 Text。UserProfile.nickname/avatarUrl、CardMedia.objectKey/sha256、Report.reason、FriendReport.reason 保持已有敏感属性；查询用镜像字段依既有模型处理。消息正文、链接、摘要和 Token 的 Text 字段采用服务端 AES-256-GCM 密文，不改成明文或用 isSensitive 代替。对象定义与各 runtime 的 fieldTypes、主键、索引和销户清理必须同步。

部署 DB 会由 IDE 下载/更新 schema。若对象在控制台改动，按平台导出并对齐工程快照；本项目端侧通过云对象访问业务数据，不能为解决 schema 差异而开放直接读写。官方明确已有字段类型等不能直接改；有数据的对象/存储区不采用“删除重建”作为修复方案。参见[部署云数据库](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-deploydatabase)。

游客首页需要将 FoodCard 的新增索引 `status_createdAt_desc`、`status_category_createdAt` 同步部署并确认生效，保留所有已有数据和索引。对象权限仍只开放 Administrator，由云对象筛选 APPROVED 数据，不开放客户端直接读取。

## 3. 准备云对象环境变量

环境变量只放入对应 AGC 云对象配置，秘密使用秘密变量。以下按名称列出必需配置，值由管理员在控制台填写或通过安全渠道交接；仓库不保存环境文件。接手已有后端时先核对当前配置，不覆盖已有的完整变量集。

| 云对象 | 配置 |
| --- | --- |
| shike-media | `SHIKE_DB_ZONE=shike`、`SHIKE_STORAGE_BUCKET`、`SHIKE_MEDIA_INTERNAL_KEY` |
| shike-service | `SHIKE_DB_ZONE=shike`、相同 bucket、相同 `SHIKE_MEDIA_INTERNAL_KEY`、`SHIKE_MESSAGE_ENCRYPTION_KEY`；身份迁移另配置票据 key |
| shike-location | 可选 `SHIKE_DB_ZONE=shike` |
| shike-auth（华为兼容登录） | `SHIKE_ACCOUNT_CLIENT_ID/SECRET`、`SHIKE_AGC_PROJECT_ID`、`SHIKE_AGC_CLIENT_ID/SECRET`、`SHIKE_IDENTITY_TICKET_KEY`；可选 `SHIKE_ACCOUNT_REDIRECT_URI`、`SHIKE_AGC_AUTH_BASE` |

- 媒体内部 key 是 service/media 相同的高熵秘密，用于 60 秒有效期的 HMAC 委托。须分别配置到两个云对象。
- 消息加密 key 是 **Base64 编码的 32 字节随机密钥**，只配置到 service；稳定保管，直接换值会使已有密文无法解密。
- 票据 key 在 auth/service 完全一致，迁移票据有效期 10 分钟、一次性消费。Account Kit 与 AGC 客户端秘密用途不同，不互相替代。
- 华为账号功能还需 AGC/Account Kit 中应用包名、证书指纹和实际使用的 Redirect URI 匹配；普通业务接口不接受华为 Token。

### 可选：Push 和桌面卡片远程更新

在 AGC 开通 Push Kit，创建服务账号/密钥，重新申请含 Push 权益的调试或发布 Profile。给 service 配置：

| 变量 | 内容 |
| --- | --- |
| `SHIKE_PUSH_PROJECT_ID` | AGC 项目 ID |
| `SHIKE_PUSH_SUB_ACCOUNT` | 服务账号标识，秘密变量 |
| `SHIKE_PUSH_KEY_ID` | 服务账号密钥 ID |
| `SHIKE_PUSH_PRIVATE_KEY_BASE64` | 服务账号 PEM 私钥的 Base64，秘密变量 |
| `SHIKE_SERVICE_CARD_DAILY_PUSH_LIMIT` | 可选，每实例每日 1–5 次，默认 2 |
| `SHIKE_SERVICE_CARD_TEST_MESSAGE` | 仅联调可设 true，发布前关闭 |

通知与桌面卡片同步由用户分别开启，Token 密文存储。每设备最多登记 16 张、每账号最多 100 张卡片。远程摘要重新从当前 APPROVED 卡片生成，客户端不提交任意商品文本或模块/Ability 名称。关闭/退出前须确认云端登记删除，Push 失败不回滚业务消息或站内事件。

## 4. 编译并部署四个云对象

| 目录 | handler | 用途 |
| --- | --- | --- |
| cloudfunctions/shike-auth | shikeAuth.ShikeAuth | 华为授权码校验、AGC 会话交换与迁移 |
| cloudfunctions/shike-media | shikeMedia.ShikeMedia | 图片准备、Base64 上传/读取，内部委托提升/删除 |
| cloudfunctions/shike-service | shikeService.ShikeService | 卡片、资料、好友/群聊、通知、绑定及清理 |
| cloudfunctions/shike-location | shikeLocation.ShikeLocation | 保留的定位/旧附近接口 |

每个对象选择 **Node.js 20.x**，保留 `function-config.json` 的 **functionType=1**、`HDA-SYSTEM / apigw-client` 平台鉴权。不要额外开放免认证公网 HTTP API。

1. 在外层端云工程确认 CloudDev 指向约定测试项目，各对象依赖同步完成。实际业务逻辑在同目录 runtime.js；TS 负责导出方法和包装响应。手工打包另用符合各 package.engines 的 Node.js 20.x/npm，不把客户端 IDE 内置工具版本当成云运行时版本。
2. 当前统一维护的共享模块在 `cloudfunctions/shared/`。先按下文“图片读取与统一打包”准备独立 ZIP，或生成函数内 DevEco 依赖；源码目录缺少这些生成副本时不能直接右键部署。
3. 数据库/环境就绪后按 **auth → media → service → location** 部署对应已核验产物，并单独部署 `shike-image`。ZIP 根目录须包含 handler、同包 runtime/共享模块、配置和生产依赖；已有后端优先更新涉及的函数。
4. `Tools > CloudDev > Serverless > Cloud Functions > Go to console`，核对函数名称、handler、Node 运行时、变量和实际生效版本/`$latest`。记录部署人、Git 提交与云版本，通知使用同一后端的成员。
5. 改过导出类、方法或参数模型时，右击相应云对象选 **Generate Invoke Interface**，弹窗目标选择 `Application/cloud_objects`，确认后核对生成代理、Index.ets 公共导出、Gateway/DTO/Repository。无签名变化的 runtime 修复不需每次重生成。
6. 按根 README 生成签名、注册模拟器凭据，由成员验证邮箱登录、图片、附近与发布；控制台部署成功不等于端云联调已成功。

批量 `cloudfunctions > Deploy Cloud Functions`会部署目录内全部对象；`CloudProgram > Deploy Cloud Program`还涉及整套云资源。团队已有数据时优先有范围的单对象部署。**Sync '对象' / Sync Cloud Functions / Sync Cloud Program 是从云端下载，Overwrite 会覆盖本地源码并生成备份，不是上传发布。**确需同步时先保存 Git 改动、对比云端版本，再选择 Skip/Overwrite；同步 DB 当前支持对象类型，不是业务数据备份。

**从旧版升级到本版：**核对 `clouddb/objecttype/` 当前 32 个对象及真实 AGC 导出，保留已有数据、主键、字段类型和索引排序。本地已移除 `MealChoiceHistory` 定义，但不能据此删除线上历史对象或数据。service 的 stage1–stage7、个人集合、审核、生命周期模块，以及共享 policy/read-errors/image-reader 均由统一打包器递归收集。service 导出或代理变动后仍应执行 **Generate Invoke Interface**；客户端新增动态调用走 `cloudFunction.call`。编译入口 JS/map 和函数内派生副本不随 Git 发布。

管理接口从 `SHIKE_ADMIN_UIDS` 读取受控管理员 canonical UID；迁移还需 `SHIKE_MIGRATION_ANCHOR_UID` 指定存在且活跃的共享管理员锚点。`SHIKE_INDEXED_QUERY_VERIFIED` 仅在历史迁移覆盖完成、实际索引查询验收后启用。秘密和项目身份仍通过团队安全渠道配置。

本版标签为 **图片优化前版**。Stage 2、Stage 3 阶段验收此前已由负责人确认，Stage 4–9 运行验收待负责人完成；本次 Git 发布未执行构建、运行验证或 AGC 部署。源码已包含 30 天软删除恢复、持久生命周期任务和独立维护 Worker，实际开启仍受服务端开关与平台定时配置控制。服务卡片继续同步公开摘要与图片身份，应用前台准备封面缓存。

地图／搜索门槛继续保留：`SHIKE_STAGE3_SEARCH_VERIFIED`、`SHIKE_STAGE3_MAP_VERIFIED` 分别控制开放，且仍须历史覆盖与索引条件就绪。地图首发要求 `SHIKE_STAGE3_MAP_COORDINATE_SYSTEM=GCJ02`；可靠可见商家混入 WGS84 时不开放地图。好友发布、选点坐标与官方 POI 仍按 `SHIKE_FRIENDS_PUBLISH_VERIFIED`、`SHIKE_MAP_PICKER_COORDINATE_SYSTEM`、`SHIKE_HUAWEI_POI_VERIFIED`、`SHIKE_HUAWEI_POI_COORDINATE_SYSTEM` 核对；官方查询密钥 `SHIKE_HUAWEI_SITE_API_KEY` 使用秘密变量。部署成员逐项确认环境资格，不能仅凭这次发布替生产环境开放门槛。

外卖平台读取 AGC Remote Config 的 `shike_delivery_platforms`，文档格式为 version=1 与 platforms 数组；缺失、无效或请求失败时保留有效缓存／默认配置。端侧依赖新增 `@hw-agconnect/remoteconfig-ohos`，成员同步 OHPM 锁文件后再构建。

部署成员也可在 `CloudProgram/` 执行 `npm run package:cloud -- shike-service`（单对象）或 `npm run package:cloud:all`（全部对象）。该脚本安装锁定依赖、编译入口、复制随包功能模块并准备独立 ZIP，输出到 `CloudProgram/build/cloud/`；只准备本地产物，不自动部署 AGC。本次提交没有执行打包脚本。

以上操作参见官方[部署云对象](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-deploycloudobj)、[生成调用代理](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-invokecloudobj)、[整工程部署](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-deploy)与[同步云端代码](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-sync)。

<details>
<summary>手工准备 shike-media 上传包的例子（由部署成员执行）</summary>

由部署成员在 `CloudProgram/` 使用 `npm run package:cloud -- shike-media`，该包装命令会调用统一打包器并准备包含共享依赖的独立 ZIP。上传脚本输出的 ZIP，不手工只复制 runtime；本次未执行该命令。

</details>

部署后 `Cannot find module './runtime'` 优先检查文件同级、大小写、包层级及生效版本；`Cannot find package` 检查生产依赖。记录云版本、函数名和首条脱敏错误，不回传凭证或 Base64 图片。

### 图片读取与统一打包

当前客户端 `ImageReadConfig.ets` 使用 `BATCH`，默认关闭 `NOT_SUPPORTED` 自动回退；新入口未部署或关闭时，图片会显示可重试占位。`shike-image` 是普通事件函数，handler=`shikeImage.handler`、functionType=0，保留配置中的 `HDA-SYSTEM / apigw-client` 鉴权，不能开放匿名图片读取。业务公开/审核/修订图片的可见资格仍由服务端检查。

共享源码仅维护于 `cloudfunctions/shared/`，维护/分享函数复用原 service/media 模块。函数内 `shared/`、maintenance 的 `service/` 与 `media/`、share 的 `service/` 是生成副本，不提交 Git。部署成员任选下面一种准备方式，运行与云端验收由负责人执行：

1. **ZIP 部署**：在 `CloudProgram/` 使用 Node.js 20.x，执行 `node scripts/package-functions.mjs shike-image` 或替换为需要更新的函数名。打包器编译 TS 入口、复制/重定位本地依赖、安装生产依赖、生成产物清单并准备 ZIP。既有 `package:cloud`、`package:share`、`package:maintenance` 命令已转入这一流程。上传输出的独立 ZIP，记录对应 buildId / policyHash / schemaHash。
2. **DevEco 右键部署**：在 `CloudProgram/` 先执行 `npm run prepare:deveco`，再执行 `npm run check:deveco`，然后由成员在 IDE 部署涉及的函数。每次共享或原 service/media 源码更新后重新同步并检查；不要用旧生成副本作为打包输入。
3. 根据 `env-templates/shike-image.env.example.json` 配置测试环境。模板只有占位值；平台凭据按现有资源管理，不将实际凭据填回 Git。先保持 `SHIKE_IMAGE_READ_ENABLED=false`，确认关闭响应，再在隔离测试环境通过负责人验收后开启。
4. 所有活跃函数需使用一致的共享策略源码。部署成功后由负责人核对 SDK 成功/错误包络、图片权限、批次大小、换号及后台取消、缓存损坏与服务卡片封面。新缓存复用只代表文件有效，展示权限仍需重新确认。没有运行结果前不宣称图片性能达标。

图片原图读取、上传和封面生成职责分离：`shared/image-reader.js` 读取并校验权限；media 的 `cover-converter.js` / `cover-worker.js` 处理封面；maintenance 保留回填与定时职责。Node.js 打包/源码检查、契约测试均由负责人执行，本次 Git 提交未执行这些脚本。

### 本版已知问题

本次按现有源码提交，以下两项静态问题尚未修改：

- `shike-service/runtime.js` 的 `FriendReport.fieldTypes/indexes` 与 `clouddb/objecttype/FriendReport.json` 不一致：模型缺少业务写入的 `targetUid`，却包含卡片举报字段及索引。用户举报与相关账号清理需先对齐模型，再由负责人验证。
- media/service runtime 的 `IdentityBinding.indexes` 是对象，而公共 `getIndexList()` 使用列表展开，会存在不可迭代的风险；统一的 `shared/content-policy.js` 对应索引列表还缺少 `canonicalUid,id`。应统一索引表示并对齐正式定义，验证登录、身份绑定、媒体读取与销户任务。

这些问题不改变 Git 源码归档的范围，但本标签不能作为生产就绪结论。

### 独立分享服务与维护 Worker

四个业务云对象保持平台鉴权。新增 `shike-share` 是独立、受限的公开只读 HTTP 入口，`shike-maintenance` 是独立定时入口，不能将 service 云对象改为免认证 HTTP 来替代它们。

| 源码 / 命令（由部署成员执行） | 作用与部署条件 |
| --- | --- |
| `cloudfunctions/shike-share/shikeShare.js`；`npm run package:share` | 准备分享 HTTP 包；在实际网关映射 `gateway-contract.json`，核对入口、路径、允许来源、限流和大小限制 |
| `hosting/share/`；`npm run package:share:web -- --api-base https://YOUR_GATEWAY_BASE --web-origin https://YOUR_SHARE_ORIGIN` | 将真实 HTTPS API 与站点 origin 写入 `build/hosting/share/` 的配置；源配置 `apiBase` 为空，不直接作为已可运行站点发布 |
| `cloudfunctions/shike-maintenance/shikeMaintenance.js`；`npm run package:maintenance` | 准备定时 Worker 包；handler 为 `shikeMaintenance.handler`，不开放 HTTP 触发 |
| `npm run check:release-source` | 供负责人手动执行的发布源码检查，不等于构建、模拟器或端云验收 |

`hosting-contract.json`、`gateway-contract.json`、`timer-contract.json` 是部署约定，不能当作厂商 CLI 已部署配置。分享托管需在选用平台配置 `/card` 与 `/card/**` 回退、CSP / no-store 等响应头；为分享函数配置与站点一致的 `SHIKE_SHARE_ALLOWED_ORIGINS`，再核对 App Linking 的 Web fallback。

维护函数的 `function-config.json` 默认 `triggers=[]`。由部署负责人在平台设置定时器，按 `timer-contract.json` 配置事件，并将高熵 `SHIKE_MAINTENANCE_TRIGGER_KEY` 以秘密变量保存；事件中的 `workerToken` 必须匹配实际秘密，仓库占位值不可直接使用。建议间隔 5 分钟；单轮最多 3 个任务、每阶段最多 10 行、45 秒工作预算。`SHIKE_LIFECYCLE_VERIFIED` 与 `SHIKE_MAINTENANCE_ENABLED` 默认不启用，通过人工验收后才开启。认证用户清理还需 service 的 AGC 项目/客户端配置和受控授权，失效时进入 `AUTH_ACTION_REQUIRED`，不能仅删业务数据就宣布销户完成。

部署及验收顺序：先修复已知模型问题并核对 DB → 更新云对象与必要变量 → 单独部署分享/维护函数和网页 → 由负责人验证游客公开可见性、私有内容拒绝、审核权限、30 天恢复和任务续跑 → 达到门槛后再开相应功能。Git 推送和打包脚本均不代替平台部署。

### 云对象断点与远程调用调试

手机模拟器调试客户端；云对象使用下面的独立调试入口。先确保测试 DB、服务配置/环境变量已就绪；项目代码仍校验 AGC 用户 Token，开发成员登录 IDE 不会绕过业务鉴权。

1. **本地断点**：右击目标云对象选 `Debug 'shike-xxx'`，底部 cloudfunctions 窗口出现 `Cloud Functions loaded successfully`后，在 TS 包装层或 runtime 的可执行代码行设置断点。停止并重新 Debug 才应用修改。
2. `View > Tool Windows > Cloud Functions Requestor`，选择目标 Cloud Function、`Environment=Local`、导出 Method，Event 填**方法参数数组**。要查云端生效代码则选 `Remote`，必须先部署，Remote 本身不会命中本地断点。
3. 例如 service 的只读 `listMyCards(input: CloudEnvelope)`，Event 是数组内一个对象，不能填短横线业务操作名，也不能把对象写成 JSON 字符串：

   ```json
   [{ "accessToken": "<自己的有效测试用户 AGC Access Token>", "payload": {} }]
   ```

4. 有效 Token 只在成员自己的受控调试环境使用，不保存带真实 Token 的触发事件，不放代码/截图/聊天。普通联调直接由已登录客户端触发即可；无效占位 Token 得到拒绝属于正常结果。
5. 点击 Trigger，看 Result；Remote 的 Logs 查看云日志。本地 runtime 若无法取得资源配置/平台凭证，先排查云开发调试环境，或使用已部署测试后端 Remote；不手工复制全局管理凭证绕过。

预期：本地调用进入对应断点，远程调用读取约定云版本；成功响应 `ok=true`，无本人卡片时允许空数据。失败反馈 Method/Local 或 Remote、首个错误、文件/行号、云版本和脱敏日志。官方指南：[调试云对象](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-debugcloudobj)。

## 5. 可选：附近云缓存

先保持 `SHIKE_NEARBY_CLOUD_CACHE_ENABLED=false` 跑通数据库路径。需要灰度时，在 AGC 建立可从 service 访问的云缓存实例，按 `shike-service-nearby-cache.env.example.json` 增量配置：

- 普通变量：HOST、PORT、USERNAME；秘密变量：PASSWORD、至少 32 字符的独立 KEY_SECRET，前缀均为 `SHIKE_NEARBY_CACHE_`。
- 功能开关 `SHIKE_NEARBY_CLOUD_CACHE_ENABLED=true`；指标开关 `SHIKE_NEARBY_CACHE_METRICS_ENABLED=true` 可单独用于关闭缓存时的基线。
- Redis v3 仅缓存最多 200 条候选 ID，每次响应重新查询卡片并核对当前读取资格；TTL 25 秒、单连接/命令限时 400ms；失败回 Cloud DB，实例冷却 30 秒。key 使用 HMAC，不含明文坐标/UID；完整个性化响应、Token和图片不缓存。
- 只减少候选查询，不能消除逐卡资料/媒体组装；无跨写路径主动失效，客户端还可能显示旧快照，不能承诺界面 25 秒内更新。
- 先采集基线，再验证 hit/miss、故障回源、分页、新鲜度和费用。回滚将功能开关设 false 并发布生效，键自行过期。

指标回归由成员在固定设备/数据/网络下采冷开、热开、刷新、分页、详情基线，再对比开启/关闭缓存后的读取、延迟和费用。至少 21 张卡验证分页，两个账号验证最终响应隔离；故障注入只在测试环境，确认 fallback/cooldown 及恢复。客户端图片解码指标不等于屏幕实际首帧；云候选查询计数不等于全部计费读取，结合 AGC 统计。

离线汇总由成员使用 `Application/scripts/summarize_preload_metrics.py`，必填 phase（baseline/cache/rollback）、scenario（cold/warm/refresh/paging/detail/offline/fault/isolation）、network（wifi/cellular/offline/other）。不要混组或重复导入；临时开启客户端 NearbyPerformanceTrace 指标后，验收结束恢复开关。CloudProgram 根 package 的 test 是占位失败脚本，不是自动化验收套件。

## 6. 分享域名与正式发布

需要系统/碰一碰分享时，在 AGC App Linking 中配置 `shike.drcn.agconnect.link` 的 `/card` 规则、动态 cardId、`com.wyq.shike` 与当前签名关联。客户端 module 已声明 HTTPS URI/domainVerify；声明存在不证明平台配置生效。先验证已安装应用链接直达，再做双设备近场验证。

正式发布前由负责人核对：正式证书/Profile 与开放能力、端云版本、数据库/Storage 权限、稳定加密 key、关闭卡片测试消息、隐私政策/SDK 说明、内容治理与删除回归、真机和分享/跨设备能力结果。签名、秘密和构建产物不进入 Git；正式发布由已获授权成员操作。

AGC 服务接入参考：[邮箱认证](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-auth-harmonyts-login-email-0000001522426989)、[云服务模拟器调试](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/cloudfoundation-emulator)、[云缓存](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-cloudcache-use-0000001485525416)。
