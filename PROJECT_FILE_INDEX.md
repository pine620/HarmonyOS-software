# 项目文件索引

按 2026-10-16 的现有发布文件结构整理，重点覆盖 `Application` 与 `CloudProgram`。先看下面的职责说明，完整文件清单在文末。首次运行见 [README](README.md)，后端操作见 [云端指南](CloudProgram/README.md)。

路径从项目根目录起算。GitHub 仓库包含 Application 与 CloudProgram 的源码；三个不含签名的 build profile 随源码共享；本地签名、SDK 和云工程关联配置另列，不提交配置值。

## 整体框架

```text
Application/
├── AppScope/                 应用身份、版本、全局资源
├── entry/                    可运行的应用 HAP
│   ├── src/main/ets/
│   │   ├── entryability/     UIAbility 生命周期、系统入口
│   │   ├── pages/            页面、Navigation 子页面
│   │   ├── repository/       卡片、好友/聊天、通知业务封装
│   │   ├── service/          会话、云调用、定位、图片、缓存、系统能力
│   │   ├── model/            端云请求/响应模型
│   │   ├── mapper/           云模型转展示数据
│   │   ├── components/       共用 UI 组件
│   │   ├── common/           错误、窗口断点
│   │   └── servicecard/      桌面服务卡片
│   └── src/main/resources/   文案、主题、图标、页面/卡片配置
├── cloud_objects/            生成的云对象调用代理 HAR
├── hvigor/                   构建配置
└── scripts/                  离线指标汇总
CloudProgram/
├── cloud-config.json         本地生成的团队/项目/应用关联元数据
├── cloudfunctions/           八个云对象与三个独立云函数
├── scripts/                  云对象、分享及维护打包工具
├── clouddb/objecttype/       当前数据库对象定义
├── clouddb/db-config.json    默认存储区与数据处理位置
└── AppScope/resources/       平台生成的历史 schema
```

主调用链：页面 → Repository/Service → CloudGateway → cloud_objects 代理 → AGC 云对象 TS 导出 → runtime.js → Cloud DB/Storage。端侧不直接读写业务数据库和存储。

## Application：工程文件

| 路径 | 职责与注意事项 |
| --- | --- |
| `entry/src/main/module.json5` | EntryAbility、设备类型、权限、URI/域名验证、服务卡片和接续声明 |
| `cloud_objects/Index.ets` | 四个云对象代理、importObject、CloudEnvelope 公共导出 |
| `cloud_objects/BuildProfile.ets` | 构建生成的 HAR 版本/模式常量，不是业务配置源 |
| `.idea/.gitignore` | 保留工程目录，供 DevEco 26.0 打开对话框识别；不共享 workspace、缓存或个人设置 |
| `.gitignore` | 忽略签名文件、SDK 配置、依赖和产物；共享 build profile 中不提交个人签名信息 |

以上路径相对于 `Application/`。三个 build-profile.json5 是共享的工程/模块构建配置，默认不带签名；首次需要下载的 rawfile/agconnect-services.json 单独说明于 README。

## Application：页面与生命周期

除第一行外，文件位于 `Application/entry/src/main/ets/pages/`。

| 文件 | 职责 |
| --- | --- |
| `entryability/EntryAbility.ets` | 主 Ability 生命周期、窗口与页加载、Want/分享入口、后台清理及接续 |
| `Index.ets` | 主容器、隐私门槛、游客双页签/我的登录入口、账号五页签、Navigation 路由、待处理分享/通知入口 |
| `NearbyPage.ets` | 公开推荐入口、能力门槛检查、发现页与旧列表回退 |
| `DiscoveryFeed.ets` | 原生地图与推荐列表、区域／上一地区、搜索／筛选／排序、商家抽屉、分页及异步代次 |
| `CreateCardPage.ets` | 外卖／到店发布和待审编辑、商家关联、金额、1–6 图、模式缓存、幂等重试与立即收窄 |
| `CardDetailPage.ets` | 详情/图片/评价、点赞收藏、举报删除及系统/近场分享生命周期；评论入口已退场 |
| `ShareCardPage.ets` | 单独的卡片分享页面和公开分享展示 |
| `FriendsPage.ets` | 好友、申请、会话与群聊入口 |
| `FriendSearchPage.ets` | 搜索食刻号与发起关系操作 |
| `FriendProfilePage.ets` | 用户资料、公开卡片、关系操作与聊天入口 |
| `ChatPage.ets` | 好友私信、文字/链接/卡片发送、分页和页面刷新 |
| `GroupChatPage.ets` | 群资料、消息、成员管理、邀请/移除/退出 |
| `ProfilePage.ets` | 本人主页与个人功能入口 |
| `FavoriteCardsPage.ets` | 本人收藏的公开卡片 |
| `CardHistoryPage.ets` | 本机访问历史及卡片打开 |

| `DeletedCardsPage.ets` | 软删除列表与恢复 |
| `MealPollPage.ets` | 群投票详情、选项和投票 |
| `ReportContentPage.ets` | 卡片/商家举报 |
| `SocialDiscoveryPages.ets` | 社交发现导航页面 |
| `UserProfileContent.ets` | 用户内容列表 |

| `FoodRankingPage.ets` | 高分/好友榜单、快照准备态与分页 |
| `RandomFoodPage.ets` | 随机吃什么轮盘、来源、轮次与选择 |
| `FoodChoiceHistoryPage.ets` | 本人选择历史、内容读取与删除 |
| `MyContentStatusPage.ets` | 本人内容状态与后续操作 |

| `CardReportListPage.ets`、`CardReportDetailPage.ets` | 举报列表、详情、图片与处理动作 |

| `MyPublishedPage.ets`、`PermissionsPrivacyPage.ets`、`ProfileSettingsPage.ets`、`ProfileEditPage.ets` | 从个人子页集合拆出的独立页面 |

## Application：业务封装、服务与模型

以下路径相对于 `Application/entry/src/main/ets/`。

| 文件 | 职责 |
| --- | --- |
| `repository/CardRepository.ets` | 公开推荐/游客详情、卡片发布、附近/榜单、互动、举报/删除业务封装 |
| `repository/FriendRepository.ets` | 用户搜索/资料、好友关系、私信与群聊业务封装 |
| `repository/CardEditRepository.ets` | 编辑上下文、Revision 提交／撤回及立即收窄 |
| `repository/MerchantRepository.ets` | 商家能力、官方点解析、用户点创建／更新与读取 |
| `repository/DiscoveryRepository.ets` | 地图商家、公开搜索、独立商家推荐和发现能力请求 |
| `service/AuthService.ets` | 邮箱登录、华为兼容授权、绑定、退出/切换与销户流程协调 |
| `service/AuthSessionStore.ets` | AGC SDK 初始化、验证码注册/登录、会话/Token、重认证与认证用户删除 |
| `service/PrivacyStore.ets` | 隐私同意状态及初始化门槛 |
| `service/CloudGateway.ets` | Cloud Foundation 初始化、方法分发、业务信封、响应错误处理与媒体故障隔离 |
| `service/LocationService.ets` | 双位置权限、单次定位、E3 舍入、行政区反查和短时定位缓存 |
| `service/ImagePreparationService.ets` | JPEG 重编码、缩放、去 EXIF/GPS、摘要计算与头像裁剪 |
| `service/PhotoUploadService.ets` | 鉴权媒体上传、游客/账号媒体读取、Base64 到本机文件、文件缓存与下载队列 |
| `service/NearbyPerformanceTrace.ets` | 附近/详情的固定指标与 trace，供人工采样 |
| `service/CardVisitStore.ets` | 按账号保存访问历史与数量控制 |
| `service/ContinuationState.ets` | 最小接续上下文、Want 路由参数与待处理通知；不迁移 Token |
| `service/PushNotificationService.ets` | 系统通知同意、Token/安装标识、云登记/解绑及重试 |
| `service/ServiceCardStore.ets` | 本地公开摘要、两种尺寸、封面身份匹配与 Form Kit 图片绑定 |
| `service/ServiceCardCoverCache.ets` | 前台准备受限大小的 JPEG 封面、缓存校验与过期清理 |
| `service/ServiceCardRemoteSyncService.ets` | 远程同步单独同意、Token/实例登记、更新和关闭清理 |
| `service/ServiceCardInteraction.ets` | 服务卡片本地刷新消息常量与 JSON 事件解析 |
| `service/DeliveryPlatformConfigService.ets` | 外卖平台 Remote Config、校验、默认值与有效缓存恢复 |
| `service/MerchantLocationPicker.ets` | 主动商家选点与上次选点中心；不自动请求设备位置 |
| `service/ModeFieldCache.ets` | 按账号／卡片保存两种模式的独立字段与 30 天期限 |
| `service/SafeSourceLink.ets` | 外部来源链接校验 |
| `service/MapViewportStore.ets` | 本机地图浏览中心与缩放保存 |
| `service/SearchHistoryStore.ets` | 本机成功搜索历史，去重并限制为 20 条 |
| `model/CloudContracts.ets` | 用户、认证、卡片、媒体、位置与服务卡片主要 DTO |
| `model/FriendModels.ets` | 好友、会话、私信和群聊模型 |
| `model/DiscoveryModels.ets` | 地图、区域、搜索、排序、分页和覆盖状态 DTO |
| `model/MerchantModels.ets` | 商家、坐标系、审核状态、选点和外卖平台配置 DTO |
| `model/PublishingModels.ets` | 11 分类、旧分类桥接、整数分／未知金额输入转换 |
| `model/CardPrice.ets`、`model/TasteScore.ets` | 价格和口味评分展示语义 |
| `mapper/CloudCardViewMapper.ets` | 云卡片转 ReviewCard 展示数据，统一价格/时间/评分等文案 |
| `components/review/ReviewDisplay.ets` | 评价卡、食物标签、价格/证据徽标和共用卡片布局 |
| `components/social/SocialDisplay.ets` | 好友/聊天共用头像 |
| `components/FoodCover.ets` | 分类封面资源与标签映射 |
| `common/BreakpointSystem.ets`、`common/ErrorKit.ets` | 窗口断点状态和统一错误文本 |
| `servicecard/ServiceCardFormAbility.ets`、`ServiceCardPresentation.ets`、`pages/ServiceCard.ets` | 卡片生命周期、尺寸回调、路由/展示格式和双规格布局 |
| `servicecard/pages/ServiceCard.ets` | 桌面卡片布局、刷新与打开操作 |

| `repository/PersonalCollectionRepository.ets`、`model/PersonalCollectionModels.ets` | 收藏/想吃集合及历史数据迁移 |
| `repository/MealRepository.ets`、`model/MealModels.ets` | 候选、选择历史与群投票 |
| `repository/SocialDiscoveryRepository.ets`、`model/SocialDiscoveryModels.ets` | 用户内容、商家榜与关系授权 |
| `service/DraftStore.ets`、`model/DraftModels.ets` | 本机草稿保存/恢复及账号隔离 |
| `service/CloudReadErrors.ets`、`service/ReadScheduler.ets` | 结构化读取错误、受控只读重试、并发与请求去重 |
| `service/PagedDataSource.ets`、`service/PersonalPreviewLoader.ets` | 稳定分页数据源与个人缩略图加载 |
| `service/FeaturePerformanceTrace.ets` | 地图、搜索、清单、审核等固定性能 trace |
| `service/MerchantNavigationService.ets` | 商家位置导航 |

| `model/ImageModels.ets`、`service/ImageDescriptors.ets` | 图片协议 DTO、响应描述符与会话内展示资格 |
| `service/ImageRepository.ets`、`service/ImageReadConfig.ets` | BATCH 图片队列、合并/去重、传输选择与受控兼容 |
| `service/ImageDiskCache.ets` | 文件摘要/长度校验、磁盘索引、预算与旧缓存迁移 |
| `service/DiscoveryFeedState.ets` | 发现列表状态与返回复用 |
| `service/SessionRestoreStore.ets` | 会话恢复状态 |

| `repository/FoodRankingRepository.ets`、`model/FoodRankingModels.ets` | 榜单请求、快照与分页 DTO |
| `repository/RandomFoodRepository.ets`、`model/RandomFoodModels.ets` | 候选池、轮盘内容、选择回执与历史 |
| `service/RandomFoodRoundStore.ets` | 按账号/来源保存轮次，校验本机恢复数据 |
| `repository/ContentStatusRepository.ets`、`model/ContentStatusModels.ets` | 本人内容状态 |
| `components/FoodRankingTile.ets`、`common/RandomFoodUi.ets`、`common/ContentStatusUi.ets` | 榜单/轮盘/状态共用 UI |

| `service/CardDeepLink.ets` | 应用内分享链接与待处理卡片入口 |
| `service/CardInteractionController.ets`、`repository/CardInteractionRepository.ets`、`model/CardInteractionModels.ets` | 卡片互动协调、意图持久化、写回执与计数 |
| `repository/CardReportRepository.ets`、`model/CardReportModels.ets`、`components/CardReportPhoto.ets` | 举报请求、响应模型和图片读取 |
| `common/AppPageUi.ets`、`PagePaletteUi.ets`、`WarmNoteUi.ets`、`CreateCardUi.ets` | 页面、色板、笔记与制作共用 UI |
| `components/CardInteractionButton.ets`、`NotePreviewTile.ets`、`DiscoveryVisuals.ets` | 互动按钮、笔记预览与发现页视觉组件 |

| `service/CloudRoutes.ets`、`CloudTimeouts.ets`、`CloudFunctionVersion.ets` | 分域操作路由、超时与 debug/release 云版本 |
| `service/HomeSnapshotReader.ets`、`PublicCoverDirectReader.ets` | 首页快照/预取与公开封面直读，失败回退 |
| `service/PollBackoff.ets` | 前台轮询退避与停止 |
| `service/RandomFoodWidgetStore.ets`、`randomfoodcard/` | 轮盘桌面卡片数据、封面、Ability 和布局 |
| `common/ChatUi.ets`、`StateViewUi.ets` | 聊天与状态共用 UI |

## Application：代理、资源与脚本

| 路径 | 职责 |
| --- | --- |
| `cloud_objects/src/main/ets/ImportObject.ts` | 生成的 importObject 与代理调用包装 |
| `cloud_objects/src/main/ets/shike-*/Shike*.ts` | auth/media/service/location 四类调用代理；Generated/DO NOT EDIT 文件通过 Generate Invoke Interface 更新 |
| `entry/src/main/resources/base/profile/main_pages.json` | 普通应用入口，Index 内管理子页面导航 |
| `entry/src/main/resources/base/element/`、`entry/src/main/resources/dark/element/` | 字符串、亮/暗色主题颜色 |
| `entry/src/main/resources/base/media/create_category_*.svg` | 制作页六种分类图标 |
| `entry/src/main/resources/base/media/food_*.png` | 分类兜底封面；staple=米饭、bakery=汤粉、drink=饮品、snack=炸鸡、fresh=烧烤、other=其他，文件名为兼容保留 |
| `entry/src/main/resources/base/media/ic_*.svg`、`nav_*.svg` | 操作、个人功能与五页签图标；dark/media 提供部分暗色覆盖 |
| `AppScope/resources/base/`、`entry/.../media/app_icon.png` | 应用名称/图标资源 |
| `scripts/summarize_preload_metrics.py` | 成员执行的离线日志聚合，按阶段/场景/网络计算 P50/P95，不连接设备或云端 |
| `AppScope/resources/rawfile/schema.json` | 历史平台 schema，不能用来替代当前 DB 部署目录 |

## CloudProgram：工程、云对象与配置

| 路径 | 职责与注意事项 |
| --- | --- |
| `AppScope/resources/rawfile/schema.json` | 平台生成 schema 快照；当前部署以 clouddb/objecttype 为准 |
| `README.md` | 从零后端准备、部署/调试与变量说明 |

云对象位于 `CloudProgram/cloudfunctions/`：

| 目录 | TS 入口 / handler | runtime 职责 |
| --- | --- | --- |
| `shike-auth/` | shikeAuth.ts / shikeAuth.ShikeAuth | 华为兼容授权校验、AGC 会话交换、迁移票据 |
| `shike-media/` | shikeMedia.ts / shikeMedia.ShikeMedia | 图片准备、上传/读取、内部委托提升与删除 |
| `shike-service/` | shikeService.ts / shikeService.ShikeService | 资料、卡片、好友/群聊、通知/卡片登记、身份绑定和清理 |
| `shike-location/` | shikeLocation.ts / shikeLocation.ShikeLocation | 定位检查与旧附近接口；现行附近主链路走 service，不直接删除旧对象 |

每个目录均有 `runtime.js`（实际 JS 实现）、`function-config.json`（类型/handler/超时/鉴权）、`package.json` 与 `package-lock.json`（该对象独立依赖）、`tsconfig.json`（CommonJS 入口编译）。TS 导出负责包装响应，部署包必须带相邻 runtime 和生产依赖。media 另有 `check-deployment.mjs`供成员预检源码包/解包产物。

共享策略、错误与图片协议统一维护在 `cloudfunctions/shared/`；service 另带 当前保留的 `stage1-services.js`、`stage2-services.js`、`stage3-services.js`、`stage6-services.js`、`stage7-services.js`、`stages47-common.js`、`personal-collections.js`、`content-status-services.js`、`food-ranking-services.js`、`random-food-services.js`、`lifecycle-services.js`、`authentication-cleanup.js`。部署时必须随 runtime 同包，完整打包/已知问题见云端指南。`CloudProgram/scripts/package-cloud-object.mjs` 为部署成员准备编译入口、随包 JS 模块和独立依赖；不会自动部署 AGC。

新增 `shike-content` / `shike-social` / `shike-account` / `shike-governance` 四个领域云对象，派生 service 副本不提交。独立入口为 `shike-image` 图片读取、`shike-prefetch` 首页预取和 `shike-maintenance` 维护函数。旧分享函数/网站已移除，端侧采用 `service/CardDeepLink.ets` 的应用内分享路由。

环境变量名称、用途及团队配置流程见云端指南；秘密只保存在 AGC 配置或团队约定的安全渠道。

`cloudfunctions/shike-image/` 为鉴权图片事件入口，`cloudfunctions/shared/` 为唯一维护的共享模块。media 增加封面 converter/worker。`scripts/package-functions.mjs` / `function-layout.mjs` / `check-artifact.mjs` 统一准备独立部署产物；`prepare-deveco.mjs` 为 IDE 生成函数内依赖，副本不提交。`tests/*.test.cjs` 是负责人手动执行的契约测试源码。

## CloudProgram：36 个当前数据库对象

均位于 `CloudProgram/clouddb/objecttype/<对象名>.json`，包含字段、主键、索引和权限。

| 对象 | 职责 |
| --- | --- |
| NicknameClaim | 昵称占用与账号归属 |
| PasswordCredential | 昵称密码认证材料，仅受控服务端访问 |
| PasswordThrottle | 登录节流状态 |
| UserProfile | 用户资料、食刻号、头像/头图媒体引用 |
| FoodCard | 商品、价格、口味、E3 发布位置、归属和公开状态 |
| Merchant | 商家来源、坐标系、审核、地图资格与三类公开推荐计数 |
| CardMedia | 媒体归属/卡片关联、对象路径、摘要、尺寸与状态 |
| Report | 卡片举报与下架治理 |
| CardAction | 旧 LIKE 兼容与独立收藏关系 |
| CardReaction | 新赞踩权威记录 |
| CardRating | 评分记录；字段与索引以当前定义及真实云端导出为准 |
| MealChoiceHistory | 今天吃什么选择历史 |
| FoodCardRevision | 待审编辑版本、基准与图片清单 |
| PublishRequestRecord | 请求幂等回执 |
| MaintenanceJob | 迁移、会话清理及生命周期任务 |
| CardComment | 评论与回复关系 |
| CommentReaction | 评论反应与用户去重 |
| Friendship | 好友申请/关系状态 |
| FriendReport | 用户举报 |
| Conversation | 私信会话、摘要与未读 |
| ChatMessage | TEXT/CARD/LINK 私信与密文内容 |
| GroupConversation | 群资料与摘要 |
| GroupMember | 群成员、角色、未读 |
| GroupMessage | 群消息与密文内容 |
| IdentityBinding | provider UID 到 canonical 业务 UID |
| AuthMigrationTicket | 一次性迁移/绑定票据消费记录 |
| PushRegistration | 通知设备/安装标识、加密 Token |
| WidgetRegistration | 桌面卡片实例、设备、加密 Token |
| NotificationEvent | 通知来源/对象/接收者/已读，不存正文 |

| TastePreference | 个人口味偏好 |
| FoodList | 私人清单元信息 |
| FoodListItem | 清单条目和顺序 |
| PersonalFoodState | 收藏/想吃等个人状态 |
| MealPoll | 群投票状态与生命周期 |
| MealPollOption | 投票候选项 |
| MealPollVote | 成员投票与去重 |

对象均只开放 Administrator 直读写。线上若有历史 CardRating，先保留数据；不能因为当前目录没有该定义而直接删线上对象。

## 修改入口与维护

- 改接口：runtime + TS 导出 → 正式生成代理 → CloudGateway → DTO/Repository → 页面和人工验收。
- 改图片链路：ImagePreparationService/PhotoUploadService → media runtime → service 媒体状态确认 → CardMedia/Storage。
- 改账号边界：PrivacyStore/AuthSessionStore/AuthService → auth/service → IdentityBinding/票据/清理流程。
- 新增、移动或删除文件后更新本索引；完整清单仅保留 .idea/.gitignore 工程目录占位文件，不包含 .git、其他 .idea 文件、.hvigor、依赖、构建、日志、证书和系统缓存。


## 完整文件清单

以下按当前源码重新生成，排除依赖、构建产物、缓存、日志和本地配置。克隆 GitHub 仓库可获得下列文件；首次需补齐的两个 AGC 配置路径单独列在末尾。

<details>
<summary>Application：268 个文件</summary>

```text
Application/.gitignore
Application/.idea/.gitignore
Application/AppScope/app.json5
Application/AppScope/resources/base/element/string.json
Application/AppScope/resources/base/media/app_icon.png
Application/AppScope/resources/rawfile/schema.json
Application/build-profile.json5
Application/cloud_objects/BuildProfile.ets
Application/cloud_objects/Index.ets
Application/cloud_objects/build-profile.json5
Application/cloud_objects/hvigorfile.ts
Application/cloud_objects/oh-package.json5
Application/cloud_objects/src/main/ets/ImportObject.ts
Application/cloud_objects/src/main/ets/shike-auth/ShikeAuth.ts
Application/cloud_objects/src/main/ets/shike-location/ShikeLocation.ts
Application/cloud_objects/src/main/ets/shike-media/ShikeMedia.ts
Application/cloud_objects/src/main/ets/shike-service/ShikeService.ts
Application/cloud_objects/src/main/module.json5
Application/docs/service-card-redesign-20261003/IMPLEMENTATION.md
Application/docs/service-card-redesign-20261003/PLAN.md
Application/docs/service-card-redesign-20261003/direction-a-cover.png
Application/docs/service-card-redesign-20261003/direction-a-cover.svg
Application/docs/service-card-redesign-20261003/direction-a.png
Application/docs/service-card-redesign-20261003/direction-a.svg
Application/docs/service-card-redesign-20261003/direction-b.png
Application/docs/service-card-redesign-20261003/direction-b.svg
Application/entry/build-profile.json5
Application/entry/hvigorfile.ts
Application/entry/oh-package-lock.json5
Application/entry/oh-package.json5
Application/entry/src/main/ets/common/AppPageUi.ets
Application/entry/src/main/ets/common/BreakpointSystem.ets
Application/entry/src/main/ets/common/ChatUi.ets
Application/entry/src/main/ets/common/ContentStatusUi.ets
Application/entry/src/main/ets/common/CreateCardUi.ets
Application/entry/src/main/ets/common/ErrorKit.ets
Application/entry/src/main/ets/common/PagePaletteUi.ets
Application/entry/src/main/ets/common/RandomFoodUi.ets
Application/entry/src/main/ets/common/Stage47Ui.ets
Application/entry/src/main/ets/common/StateViewUi.ets
Application/entry/src/main/ets/common/WarmNoteUi.ets
Application/entry/src/main/ets/components/CardInteractionButton.ets
Application/entry/src/main/ets/components/CardReportPhoto.ets
Application/entry/src/main/ets/components/DiscoveryCard.ets
Application/entry/src/main/ets/components/DiscoveryMap.ets
Application/entry/src/main/ets/components/DiscoveryVisuals.ets
Application/entry/src/main/ets/components/EmailLoginPage.ets
Application/entry/src/main/ets/components/FoodCover.ets
Application/entry/src/main/ets/components/FoodRankingTile.ets
Application/entry/src/main/ets/components/MerchantRecommendationSheet.ets
Application/entry/src/main/ets/components/NotePreviewTile.ets
Application/entry/src/main/ets/components/PersonalPreviewTile.ets
Application/entry/src/main/ets/components/review/ReviewDisplay.ets
Application/entry/src/main/ets/components/social/SocialDisplay.ets
Application/entry/src/main/ets/entryability/EntryAbility.ets
Application/entry/src/main/ets/mapper/CloudCardViewMapper.ets
Application/entry/src/main/ets/model/CardInteractionModels.ets
Application/entry/src/main/ets/model/CardPrice.ets
Application/entry/src/main/ets/model/CardReportModels.ets
Application/entry/src/main/ets/model/CloudContracts.ets
Application/entry/src/main/ets/model/ContentStatusModels.ets
Application/entry/src/main/ets/model/DiscoveryModels.ets
Application/entry/src/main/ets/model/DraftModels.ets
Application/entry/src/main/ets/model/FoodRankingModels.ets
Application/entry/src/main/ets/model/FriendModels.ets
Application/entry/src/main/ets/model/ImageModels.ets
Application/entry/src/main/ets/model/MealModels.ets
Application/entry/src/main/ets/model/MerchantModels.ets
Application/entry/src/main/ets/model/PersonalCollectionModels.ets
Application/entry/src/main/ets/model/PublishingModels.ets
Application/entry/src/main/ets/model/RandomFoodModels.ets
Application/entry/src/main/ets/model/SocialDiscoveryModels.ets
Application/entry/src/main/ets/model/TasteScore.ets
Application/entry/src/main/ets/pages/CardDetailPage.ets
Application/entry/src/main/ets/pages/CardHistoryPage.ets
Application/entry/src/main/ets/pages/CardReportDetailPage.ets
Application/entry/src/main/ets/pages/CardReportListPage.ets
Application/entry/src/main/ets/pages/ChatPage.ets
Application/entry/src/main/ets/pages/CreateCardPage.ets
Application/entry/src/main/ets/pages/DeletedCardsPage.ets
Application/entry/src/main/ets/pages/DiscoveryFeed.ets
Application/entry/src/main/ets/pages/FavoriteCardsPage.ets
Application/entry/src/main/ets/pages/FoodChoiceHistoryPage.ets
Application/entry/src/main/ets/pages/FoodRankingPage.ets
Application/entry/src/main/ets/pages/FriendProfilePage.ets
Application/entry/src/main/ets/pages/FriendSearchPage.ets
Application/entry/src/main/ets/pages/FriendsPage.ets
Application/entry/src/main/ets/pages/GroupChatPage.ets
Application/entry/src/main/ets/pages/Index.ets
Application/entry/src/main/ets/pages/MealPollPage.ets
Application/entry/src/main/ets/pages/MyContentStatusPage.ets
Application/entry/src/main/ets/pages/MyPublishedPage.ets
Application/entry/src/main/ets/pages/NearbyPage.ets
Application/entry/src/main/ets/pages/PermissionsPrivacyPage.ets
Application/entry/src/main/ets/pages/ProfileEditPage.ets
Application/entry/src/main/ets/pages/ProfilePage.ets
Application/entry/src/main/ets/pages/ProfileSettingsPage.ets
Application/entry/src/main/ets/pages/RandomFoodPage.ets
Application/entry/src/main/ets/pages/ReportContentPage.ets
Application/entry/src/main/ets/pages/ShareCardPage.ets
Application/entry/src/main/ets/pages/SocialDiscoveryPages.ets
Application/entry/src/main/ets/pages/UserProfileContent.ets
Application/entry/src/main/ets/randomfoodcard/RandomFoodFormAbility.ets
Application/entry/src/main/ets/randomfoodcard/pages/RandomFoodCard.ets
Application/entry/src/main/ets/repository/CardEditRepository.ets
Application/entry/src/main/ets/repository/CardInteractionRepository.ets
Application/entry/src/main/ets/repository/CardReportRepository.ets
Application/entry/src/main/ets/repository/CardRepository.ets
Application/entry/src/main/ets/repository/ContentStatusRepository.ets
Application/entry/src/main/ets/repository/DiscoveryRepository.ets
Application/entry/src/main/ets/repository/FoodRankingRepository.ets
Application/entry/src/main/ets/repository/FriendRepository.ets
Application/entry/src/main/ets/repository/MealRepository.ets
Application/entry/src/main/ets/repository/MerchantRepository.ets
Application/entry/src/main/ets/repository/PersonalCollectionRepository.ets
Application/entry/src/main/ets/repository/RandomFoodRepository.ets
Application/entry/src/main/ets/repository/SocialDiscoveryRepository.ets
Application/entry/src/main/ets/service/AccountRequestGuard.ets
Application/entry/src/main/ets/service/AuthService.ets
Application/entry/src/main/ets/service/AuthSessionStore.ets
Application/entry/src/main/ets/service/CardDeepLink.ets
Application/entry/src/main/ets/service/CardInteractionController.ets
Application/entry/src/main/ets/service/CardVisitStore.ets
Application/entry/src/main/ets/service/CloudFunctionVersion.ets
Application/entry/src/main/ets/service/CloudGateway.ets
Application/entry/src/main/ets/service/CloudReadErrors.ets
Application/entry/src/main/ets/service/CloudRoutes.ets
Application/entry/src/main/ets/service/CloudTimeouts.ets
Application/entry/src/main/ets/service/ContentPageGuard.ets
Application/entry/src/main/ets/service/ContinuationState.ets
Application/entry/src/main/ets/service/DeliveryPlatformConfigService.ets
Application/entry/src/main/ets/service/DiscoveryFeedState.ets
Application/entry/src/main/ets/service/DraftStore.ets
Application/entry/src/main/ets/service/FeaturePerformanceTrace.ets
Application/entry/src/main/ets/service/HomeSnapshotReader.ets
Application/entry/src/main/ets/service/ImageDescriptors.ets
Application/entry/src/main/ets/service/ImageDiskCache.ets
Application/entry/src/main/ets/service/ImagePreparationService.ets
Application/entry/src/main/ets/service/ImageReadConfig.ets
Application/entry/src/main/ets/service/ImageRepository.ets
Application/entry/src/main/ets/service/LocationService.ets
Application/entry/src/main/ets/service/MapViewportStore.ets
Application/entry/src/main/ets/service/MerchantLocationPicker.ets
Application/entry/src/main/ets/service/MerchantNavigationService.ets
Application/entry/src/main/ets/service/ModeFieldCache.ets
Application/entry/src/main/ets/service/NearbyPerformanceTrace.ets
Application/entry/src/main/ets/service/PagedDataSource.ets
Application/entry/src/main/ets/service/PersonalPreviewLoader.ets
Application/entry/src/main/ets/service/PhotoUploadService.ets
Application/entry/src/main/ets/service/PollBackoff.ets
Application/entry/src/main/ets/service/PrivacyStore.ets
Application/entry/src/main/ets/service/PublicCoverDirectReader.ets
Application/entry/src/main/ets/service/PushNotificationService.ets
Application/entry/src/main/ets/service/RandomFoodRoundStore.ets
Application/entry/src/main/ets/service/RandomFoodWidgetStore.ets
Application/entry/src/main/ets/service/ReadScheduler.ets
Application/entry/src/main/ets/service/SafeSourceLink.ets
Application/entry/src/main/ets/service/SearchHistoryStore.ets
Application/entry/src/main/ets/service/ServiceCardCoverCache.ets
Application/entry/src/main/ets/service/ServiceCardInteraction.ets
Application/entry/src/main/ets/service/ServiceCardRemoteSyncService.ets
Application/entry/src/main/ets/service/ServiceCardStore.ets
Application/entry/src/main/ets/service/SessionRestoreStore.ets
Application/entry/src/main/ets/servicecard/ServiceCardFormAbility.ets
Application/entry/src/main/ets/servicecard/ServiceCardPresentation.ets
Application/entry/src/main/ets/servicecard/pages/ServiceCard.ets
Application/entry/src/main/module.json5
Application/entry/src/main/resources/base/element/color.json
Application/entry/src/main/resources/base/element/string.json
Application/entry/src/main/resources/base/media/app_icon.png
Application/entry/src/main/resources/base/media/food_bakery.png
Application/entry/src/main/resources/base/media/food_drink.png
Application/entry/src/main/resources/base/media/food_fresh.png
Application/entry/src/main/resources/base/media/food_other.png
Application/entry/src/main/resources/base/media/food_ranking_steam.svg
Application/entry/src/main/resources/base/media/food_snack.png
Application/entry/src/main/resources/base/media/food_staple.png
Application/entry/src/main/resources/base/media/ic_card_share.svg
Application/entry/src/main/resources/base/media/ic_chevron_right.svg
Application/entry/src/main/resources/base/media/ic_create_chevron.svg
Application/entry/src/main/resources/base/media/ic_create_photo.svg
Application/entry/src/main/resources/base/media/ic_discovery_all.svg
Application/entry/src/main/resources/base/media/ic_discovery_bakery.svg
Application/entry/src/main/resources/base/media/ic_discovery_dessert.svg
Application/entry/src/main/resources/base/media/ic_discovery_drink.svg
Application/entry/src/main/resources/base/media/ic_discovery_filter.svg
Application/entry/src/main/resources/base/media/ic_discovery_grill.svg
Application/entry/src/main/resources/base/media/ic_discovery_history.svg
Application/entry/src/main/resources/base/media/ic_discovery_hotpot.svg
Application/entry/src/main/resources/base/media/ic_discovery_more.svg
Application/entry/src/main/resources/base/media/ic_discovery_noodles.svg
Application/entry/src/main/resources/base/media/ic_discovery_other.svg
Application/entry/src/main/resources/base/media/ic_discovery_packaged.svg
Application/entry/src/main/resources/base/media/ic_discovery_refresh.svg
Application/entry/src/main/resources/base/media/ic_discovery_rice.svg
Application/entry/src/main/resources/base/media/ic_discovery_search.svg
Application/entry/src/main/resources/base/media/ic_discovery_snack.svg
Application/entry/src/main/resources/base/media/ic_discovery_western.svg
Application/entry/src/main/resources/base/media/ic_me_cards.svg
Application/entry/src/main/resources/base/media/ic_me_chevron.svg
Application/entry/src/main/resources/base/media/ic_me_choice.svg
Application/entry/src/main/resources/base/media/ic_me_deleted.svg
Application/entry/src/main/resources/base/media/ic_me_draft.svg
Application/entry/src/main/resources/base/media/ic_me_favorite.svg
Application/entry/src/main/resources/base/media/ic_me_history.svg
Application/entry/src/main/resources/base/media/ic_me_report.svg
Application/entry/src/main/resources/base/media/ic_me_settings.svg
Application/entry/src/main/resources/base/media/ic_message.svg
Application/entry/src/main/resources/base/media/ic_more.svg
Application/entry/src/main/resources/base/media/ic_profile_settings_light.svg
Application/entry/src/main/resources/base/media/ic_random_food_back.svg
Application/entry/src/main/resources/base/media/ic_random_food_delete.svg
Application/entry/src/main/resources/base/media/ic_service_card_chevron.svg
Application/entry/src/main/resources/base/media/ic_service_card_photo.svg
Application/entry/src/main/resources/base/media/ic_service_card_refresh.svg
Application/entry/src/main/resources/base/media/map_marker.svg
Application/entry/src/main/resources/base/media/map_marker_selected.svg
Application/entry/src/main/resources/base/media/nav_friends.svg
Application/entry/src/main/resources/base/media/nav_profile.svg
Application/entry/src/main/resources/base/media/nav_ranking.svg
Application/entry/src/main/resources/base/media/nav_recommend.svg
Application/entry/src/main/resources/base/profile/form_config.json
Application/entry/src/main/resources/base/profile/main_pages.json
Application/entry/src/main/resources/base/profile/random_food_form_config.json
Application/entry/src/main/resources/dark/element/color.json
Application/entry/src/main/resources/dark/media/food_ranking_steam.svg
Application/entry/src/main/resources/dark/media/ic_card_share.svg
Application/entry/src/main/resources/dark/media/ic_chevron_right.svg
Application/entry/src/main/resources/dark/media/ic_create_chevron.svg
Application/entry/src/main/resources/dark/media/ic_create_photo.svg
Application/entry/src/main/resources/dark/media/ic_discovery_all.svg
Application/entry/src/main/resources/dark/media/ic_discovery_bakery.svg
Application/entry/src/main/resources/dark/media/ic_discovery_dessert.svg
Application/entry/src/main/resources/dark/media/ic_discovery_drink.svg
Application/entry/src/main/resources/dark/media/ic_discovery_filter.svg
Application/entry/src/main/resources/dark/media/ic_discovery_grill.svg
Application/entry/src/main/resources/dark/media/ic_discovery_history.svg
Application/entry/src/main/resources/dark/media/ic_discovery_hotpot.svg
Application/entry/src/main/resources/dark/media/ic_discovery_more.svg
Application/entry/src/main/resources/dark/media/ic_discovery_noodles.svg
Application/entry/src/main/resources/dark/media/ic_discovery_other.svg
Application/entry/src/main/resources/dark/media/ic_discovery_packaged.svg
Application/entry/src/main/resources/dark/media/ic_discovery_refresh.svg
Application/entry/src/main/resources/dark/media/ic_discovery_rice.svg
Application/entry/src/main/resources/dark/media/ic_discovery_search.svg
Application/entry/src/main/resources/dark/media/ic_discovery_snack.svg
Application/entry/src/main/resources/dark/media/ic_discovery_western.svg
Application/entry/src/main/resources/dark/media/ic_me_cards.svg
Application/entry/src/main/resources/dark/media/ic_me_chevron.svg
Application/entry/src/main/resources/dark/media/ic_me_choice.svg
Application/entry/src/main/resources/dark/media/ic_me_deleted.svg
Application/entry/src/main/resources/dark/media/ic_me_draft.svg
Application/entry/src/main/resources/dark/media/ic_me_favorite.svg
Application/entry/src/main/resources/dark/media/ic_me_history.svg
Application/entry/src/main/resources/dark/media/ic_me_report.svg
Application/entry/src/main/resources/dark/media/ic_me_settings.svg
Application/entry/src/main/resources/dark/media/ic_message.svg
Application/entry/src/main/resources/dark/media/ic_more.svg
Application/entry/src/main/resources/dark/media/ic_random_food_back.svg
Application/entry/src/main/resources/dark/media/ic_random_food_delete.svg
Application/entry/src/main/resources/dark/media/ic_service_card_chevron.svg
Application/entry/src/main/resources/dark/media/ic_service_card_photo.svg
Application/entry/src/main/resources/dark/media/ic_service_card_refresh.svg
Application/hvigor/hvigor-config.json5
Application/hvigorfile.ts
Application/oh-package.json5
Application/package-lock.json
Application/scripts/summarize_preload_metrics.py
```

</details>

<details>
<summary>CloudProgram：152 个文件</summary>

```text
CloudProgram/AppScope/resources/rawfile/schema.json
CloudProgram/README.md
CloudProgram/clouddb/db-config.json
CloudProgram/clouddb/objecttype/AuthMigrationTicket.json
CloudProgram/clouddb/objecttype/CardAction.json
CloudProgram/clouddb/objecttype/CardComment.json
CloudProgram/clouddb/objecttype/CardMedia.json
CloudProgram/clouddb/objecttype/CardRating.json
CloudProgram/clouddb/objecttype/CardReaction.json
CloudProgram/clouddb/objecttype/ChatMessage.json
CloudProgram/clouddb/objecttype/CommentReaction.json
CloudProgram/clouddb/objecttype/Conversation.json
CloudProgram/clouddb/objecttype/FoodCard.json
CloudProgram/clouddb/objecttype/FoodCardRevision.json
CloudProgram/clouddb/objecttype/FoodList.json
CloudProgram/clouddb/objecttype/FoodListItem.json
CloudProgram/clouddb/objecttype/FriendReport.json
CloudProgram/clouddb/objecttype/Friendship.json
CloudProgram/clouddb/objecttype/GroupConversation.json
CloudProgram/clouddb/objecttype/GroupMember.json
CloudProgram/clouddb/objecttype/GroupMessage.json
CloudProgram/clouddb/objecttype/IdentityBinding.json
CloudProgram/clouddb/objecttype/MaintenanceJob.json
CloudProgram/clouddb/objecttype/MealChoiceHistory.json
CloudProgram/clouddb/objecttype/MealPoll.json
CloudProgram/clouddb/objecttype/MealPollOption.json
CloudProgram/clouddb/objecttype/MealPollVote.json
CloudProgram/clouddb/objecttype/Merchant.json
CloudProgram/clouddb/objecttype/NicknameClaim.json
CloudProgram/clouddb/objecttype/NotificationEvent.json
CloudProgram/clouddb/objecttype/PasswordCredential.json
CloudProgram/clouddb/objecttype/PasswordThrottle.json
CloudProgram/clouddb/objecttype/PersonalFoodState.json
CloudProgram/clouddb/objecttype/PublishRequestRecord.json
CloudProgram/clouddb/objecttype/PushRegistration.json
CloudProgram/clouddb/objecttype/Report.json
CloudProgram/clouddb/objecttype/TastePreference.json
CloudProgram/clouddb/objecttype/UserProfile.json
CloudProgram/clouddb/objecttype/WidgetRegistration.json
CloudProgram/cloudfunctions/shared/card-review-access.js
CloudProgram/cloudfunctions/shared/content-policy.js
CloudProgram/cloudfunctions/shared/image-models.js
CloudProgram/cloudfunctions/shared/image-reader.js
CloudProgram/cloudfunctions/shared/media-descriptor.js
CloudProgram/cloudfunctions/shared/public-snapshot.js
CloudProgram/cloudfunctions/shared/read-errors.js
CloudProgram/cloudfunctions/shared/release-info.js
CloudProgram/cloudfunctions/shike-account/function-config.json
CloudProgram/cloudfunctions/shike-account/package-lock.json
CloudProgram/cloudfunctions/shike-account/package.json
CloudProgram/cloudfunctions/shike-account/shikeAccount.ts
CloudProgram/cloudfunctions/shike-account/tsconfig.json
CloudProgram/cloudfunctions/shike-auth/function-config.json
CloudProgram/cloudfunctions/shike-auth/package-lock.json
CloudProgram/cloudfunctions/shike-auth/package.json
CloudProgram/cloudfunctions/shike-auth/runtime.js
CloudProgram/cloudfunctions/shike-auth/shikeAuth.ts
CloudProgram/cloudfunctions/shike-auth/tsconfig.json
CloudProgram/cloudfunctions/shike-content/function-config.json
CloudProgram/cloudfunctions/shike-content/package-lock.json
CloudProgram/cloudfunctions/shike-content/package.json
CloudProgram/cloudfunctions/shike-content/shikeContent.ts
CloudProgram/cloudfunctions/shike-content/tsconfig.json
CloudProgram/cloudfunctions/shike-governance/function-config.json
CloudProgram/cloudfunctions/shike-governance/package-lock.json
CloudProgram/cloudfunctions/shike-governance/package.json
CloudProgram/cloudfunctions/shike-governance/shikeGovernance.ts
CloudProgram/cloudfunctions/shike-governance/tsconfig.json
CloudProgram/cloudfunctions/shike-image/function-config.json
CloudProgram/cloudfunctions/shike-image/image-request.js
CloudProgram/cloudfunctions/shike-image/package-lock.json
CloudProgram/cloudfunctions/shike-image/package.json
CloudProgram/cloudfunctions/shike-image/shikeImage.js
CloudProgram/cloudfunctions/shike-location/function-config.json
CloudProgram/cloudfunctions/shike-location/package-lock.json
CloudProgram/cloudfunctions/shike-location/package.json
CloudProgram/cloudfunctions/shike-location/runtime.js
CloudProgram/cloudfunctions/shike-location/shikeLocation.ts
CloudProgram/cloudfunctions/shike-location/tsconfig.json
CloudProgram/cloudfunctions/shike-maintenance/function-config.json
CloudProgram/cloudfunctions/shike-maintenance/package-lock.json
CloudProgram/cloudfunctions/shike-maintenance/package.json
CloudProgram/cloudfunctions/shike-maintenance/shikeMaintenance.js
CloudProgram/cloudfunctions/shike-maintenance/timer-contract.json
CloudProgram/cloudfunctions/shike-media/check-deployment.mjs
CloudProgram/cloudfunctions/shike-media/cover-converter.js
CloudProgram/cloudfunctions/shike-media/cover-worker.js
CloudProgram/cloudfunctions/shike-media/function-config.json
CloudProgram/cloudfunctions/shike-media/package-lock.json
CloudProgram/cloudfunctions/shike-media/package.json
CloudProgram/cloudfunctions/shike-media/runtime.js
CloudProgram/cloudfunctions/shike-media/shikeMedia.ts
CloudProgram/cloudfunctions/shike-media/tsconfig.json
CloudProgram/cloudfunctions/shike-prefetch/function-config.json
CloudProgram/cloudfunctions/shike-prefetch/package-lock.json
CloudProgram/cloudfunctions/shike-prefetch/package.json
CloudProgram/cloudfunctions/shike-prefetch/shikePrefetch.js
CloudProgram/cloudfunctions/shike-service/authentication-cleanup.js
CloudProgram/cloudfunctions/shike-service/card-interaction-services.js
CloudProgram/cloudfunctions/shike-service/card-report-services.js
CloudProgram/cloudfunctions/shike-service/content-status-services.js
CloudProgram/cloudfunctions/shike-service/food-ranking-services.js
CloudProgram/cloudfunctions/shike-service/function-config.json
CloudProgram/cloudfunctions/shike-service/lifecycle-services.js
CloudProgram/cloudfunctions/shike-service/nickname-auth.js
CloudProgram/cloudfunctions/shike-service/package-lock.json
CloudProgram/cloudfunctions/shike-service/package.json
CloudProgram/cloudfunctions/shike-service/personal-collections.js
CloudProgram/cloudfunctions/shike-service/random-food-services.js
CloudProgram/cloudfunctions/shike-service/runtime.js
CloudProgram/cloudfunctions/shike-service/shikeService.ts
CloudProgram/cloudfunctions/shike-service/stage1-services.js
CloudProgram/cloudfunctions/shike-service/stage2-services.js
CloudProgram/cloudfunctions/shike-service/stage3-services.js
CloudProgram/cloudfunctions/shike-service/stage6-services.js
CloudProgram/cloudfunctions/shike-service/stage7-services.js
CloudProgram/cloudfunctions/shike-service/stages47-common.js
CloudProgram/cloudfunctions/shike-service/tsconfig.json
CloudProgram/cloudfunctions/shike-social/function-config.json
CloudProgram/cloudfunctions/shike-social/package-lock.json
CloudProgram/cloudfunctions/shike-social/package.json
CloudProgram/cloudfunctions/shike-social/shikeSocial.ts
CloudProgram/cloudfunctions/shike-social/tsconfig.json
CloudProgram/env-templates/shike-image.env.example.json
CloudProgram/env-templates/shike-maintenance-nickname-auth.env.example.json
CloudProgram/env-templates/shike-service-nickname-auth.env.example.json
CloudProgram/env-templates/shike-tester-review-access.env.example.json
CloudProgram/package-lock.json
CloudProgram/package.json
CloudProgram/scripts/check-artifact.mjs
CloudProgram/scripts/check-release-source.mjs
CloudProgram/scripts/function-layout.mjs
CloudProgram/scripts/package-cloud-object.mjs
CloudProgram/scripts/package-functions.mjs
CloudProgram/scripts/package-maintenance.mjs
CloudProgram/scripts/prepare-deveco.mjs
CloudProgram/tests/admin-notification-removal.test.cjs
CloudProgram/tests/author-direct-edit.test.cjs
CloudProgram/tests/card-history-maintenance.test.cjs
CloudProgram/tests/card-interaction-optimization.test.cjs
CloudProgram/tests/card-interaction-v3.test.cjs
CloudProgram/tests/card-report-image-access.test.cjs
CloudProgram/tests/card-report-services.test.cjs
CloudProgram/tests/feature-reduction.test.cjs
CloudProgram/tests/food-ranking-contracts.test.cjs
CloudProgram/tests/home-detail-prefetch.test.cjs
CloudProgram/tests/image-handler-contracts.test.cjs
CloudProgram/tests/image-read-contracts.test.cjs
CloudProgram/tests/nickname-auth.test.cjs
CloudProgram/tests/optimization-contracts.test.cjs
CloudProgram/tests/random-food.test.cjs
CloudProgram/tests/repair-contracts.test.cjs
```

</details>

### 首次搭建的本地配置（不在 GitHub 中）

| 路径 | 获取方式 |
| --- | --- |
| `Application/AppScope/resources/rawfile/agconnect-services.json` | 从目标 AGC 应用下载；当前 AGC SDK 默认从应用级 rawfile 读取 |
