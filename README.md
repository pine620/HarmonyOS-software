# 食刻

食刻是使用 **ArkTS / ArkUI + AppGallery Connect（AGC）** 开发的 HarmonyOS 美食推荐应用。客户端在 `Application/`，云端源码在 `CloudProgram/`。

这份说明用于新协作者从零获取代码、加入团队并完成**手机模拟器端云联调**。先按下面顺序操作，源码职责另查 [文件索引](PROJECT_FILE_INDEX.md)。

当前提交主题为 **stage3完成版**。项目负责人已确认 Stage 2、Stage 3 阶段验收完成，执行验证由负责人进行。本次包含外卖／到店发布、商家关联与待审编辑，以及原生地图、区域查询、商家推荐抽屉、关键词搜索、模式／分类／价格筛选、四种排序和本机搜索历史。地图与搜索仍受服务端验收门槛控制，不因 Git 推送自动开放。完整物理清理 Worker、恢复界面和定时调度仍属于后续阶段。

游客公开预览和 2×2 / 2×4 桌面服务卡片仍保留。升级成员须先核对当前 25 个数据库对象定义及索引，再由部署成员更新云对象、重生成 service 调用代理，详见 [云端部署说明](CloudProgram/README.md#4-编译并部署四个云对象)。仓库不包含编译后的云对象 JS／map；每位成员需从当前 TS 源码自行准备产物。Git 推送不会自动部署 AGC。

> 本次源码状态更新日期：2026-10-06；项目配置与官方联调教程核对日期仍为 2026-10-04。下文保留官方英文菜单名，中文界面的名称可能略有不同。SDK/包名按项目要求使用，IDE 的新版本号不等于项目 targetSdkVersion。

## 1. 安装开发工具

1. 安装 Git。
2. 到华为 [DevEco Studio 下载中心](https://developer.huawei.com/consumer/cn/download/deveco-studio)登录华为账号，按电脑系统和 CPU 架构下载安装包，选择能支持本项目 `26.0.0` SDK 的版本。Windows 运行安装向导；macOS 将应用拖入 Applications。新版 DevEco Studio 已打包 HarmonyOS SDK、Node.js、Hvigor、OHPM 和模拟器平台，无需单独下载 HarmonyOS SDK；模拟器镜像仍需要下载。首次启动不迁移他人的设置。
3. 注册自己的华为开发者账号并实名认证。当前官方云开发准备要求账号注册地为中国境内（不含港澳台）；确认符合条件后由管理员加入团队。AGC、IDE 都使用这个成员账号登录。

依据官方[安装教程](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-software-install)、[网络配置](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-environment-config)和[云开发账号准备](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-account)。硬件要求和可下载版本以下载页为准。

## 2. 获取代码

GitHub 仓库一次克隆即可获得客户端和云端源码：

```sh
git clone https://github.com/pine620/HarmonyOS-software.git shikeclouddev
cd shikeclouddev
```

目录结构如下；标注“本地生成”的文件不会随 Git 下载，按后面的步骤补齐：

```text
shikeclouddev/
├── README.md
├── PROJECT_FILE_INDEX.md
├── Application/         # HarmonyOS 客户端工程：用 DevEco 打开此目录运行
│   ├── AppScope/
│   ├── entry/           # 要运行的 HAP 模块
│   ├── cloud_objects/   # 调用云对象的代理 HAR
│   └── hvigorfile.ts
└── CloudProgram/        # AGC 云端源码；端云工程导入条件见第 5 节
    ├── README.md
    ├── cloud-config.json # 本地生成的 AGC 关联配置
    ├── cloudfunctions/
    └── clouddb/
```

团队协作时，从管理员约定的开发分支创建自己的功能分支，提交后通过 Pull Request 合并。不要提交签名证书、口令、AGC SDK 配置、云端秘密或依赖/构建目录；云端部署另按团队分工执行，Git 推送不会自动部署 AGC。

<a id="agc-team"></a>

## 3. 加入 AGC 团队并取得权限

AGC 团队成员权限、应用用户登录、GitHub 仓库权限是三件事，分别配置。团队账号用于开发和资源管理；后面应用里的邮箱账号用于测试业务。

### 管理员操作

1. 账号持有者或有“管理用户及访问权限”的成员登录 [AGC](https://developer.huawei.com/consumer/cn/service/josp/agc/index.html)，进入 `用户与权限 > 用户 > 所有用户 > 添加`，按提示前往[开发者联盟团队账号页面](https://developer.huawei.com/consumer/cn/console/setting/teamAccountInfoList)。也可从开发者联盟管理中心的[团队账号](https://developer.huawei.com/consumer/cn/console/setting/teamAccountInfoList)进入。
2. 添加协作者**自己的华为账号**，按页面填写成员信息与角色；无需分享持有者密码。成员收到邀请/确认提示时，完成相应确认。
3. 回到 AGC 的该成员“编辑”页，在角色管理中按职责配置“开发”等角色，并检查实际权限；承担云端部署的成员必须有云开发服务相应操作权限。
4. 在“项目与应用权限”里分别确认测试项目和 `com.wyq.shike` 应用的授权范围。**项目权限与应用权限独立**，不能仅凭看得到应用就认为能管理该项目的云资源。
5. 在证书与 Profile 权限中授予联调所需调试证书、调试 Profile 权限；确认允许管理模拟器调试凭据。无法授权或缺少入口时，由具备该权限的管理员完成对应操作。
6. 保存，检查成员权限有效期。将团队标识、测试项目名称/ID、应用名称/APP ID/包名、数据处理位置、部署负责人交给成员；分享秘密值使用团队约定的安全渠道。

### 新成员操作

**加入开发团队**：登录华为开发者联盟后，进入 [团队账号列表](https://developer.huawei.com/consumer/cn/console/setting/teamAccountInfoList)，确认能列出并切换到项目所属团队。若列表中还没有该团队，须先由管理员在 `开发者中心 > 团队账号` 中添加你的账号（见上文“管理员操作”），待收到邀请并确认后，该团队才会出现在你的列表中。

1. 用被添加的账号登录 AGC，点击右上角账号菜单，**切换到项目所属团队**；控制台可能默认打开个人团队或上次访问的团队。
2. 在“用户与权限”的个人信息中确认角色、项目/应用范围和有效期；进入“开发与服务”选择约定项目，核对应用包名 `com.wyq.shike`，数据处理位置含**中国**。
3. 应能看到对应云函数/云对象、Cloud DB、Storage，以及应用配置。缺少项目、按钮灰色或无签名权限时，回传缺失入口与页面错误给管理员，逐项补授权，不另建个人项目替代。
4. IDE 的登录账号和签名页面 `Team` 也要选同一团队。GitHub 仓库读写权限另由仓库管理员分配。

以上参照官方[团队账号说明](https://developer.huawei.com/consumer/cn/Team-account/)与[管理团队帐号](https://developer.huawei.com/consumer/cn/doc/app/agc-help-manageaccount-0000002306610129)。云开发协议若尚未签署，须由**账号持有者或法务角色**完成；开发成员的项目授权不能替代签约。参见[关联云开发资源](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-create-appproject)。

## 4. 打开客户端工程，补齐 AGC 配置

仓库已经包含不带签名信息的三个 `build-profile.json5`，用于声明 SDK、产品和 entry/cloud_objects 模块。首次下载无需手工创建这些文件；每位成员随后在 IDE 中配置自己的调试签名，提交前检查构建配置差异，移除证书路径、口令和本机签名信息。

**使用 GitHub Download ZIP 时：**完整解压后，选择解压目录中的 `Application`，例如 `HarmonyOS-software-main/Application`。本仓库外层还包含 README 和索引，不作为首次客户端导入目录；`entry` 是模块目录。请选择包含下列文件的 `Application`：

```text
Application/
├── .idea/
│   └── .gitignore        # 仅保留工程目录，不包含个人 IDE 配置
├── build-profile.json5
├── hvigorfile.ts
├── oh-package.json5
├── AppScope/
├── entry/
│   └── build-profile.json5
└── cloud_objects/
    └── build-profile.json5
```

DevEco Studio 26.0.0.821 的打开对话框会先检查工程目录，再检查 Hvigor 配置。本仓库仅共享 `Application/.idea/.gitignore`，确保 ZIP 解压后保留 `.idea`；其余 IDE 配置、缓存和签名均不共享。若旧 ZIP 缺少 `.idea/.gitignore` 或三个 build profile，请重新下载最新 main，并解压到一个新目录后打开 `Application`。不要把新 ZIP 覆盖到已打开过的旧目录。

1. `File > Open`选择 **`shikeclouddev/Application`**，作为客户端运行窗口。
2. 等待工程同步和 OHPM 安装完成，确认识别 `entry`、`cloud_objects`。未自动同步时使用工具栏工程同步按钮；只执行终端 `npm install`不能替代端侧 OHPM 同步。
3. `File > Project Structure`核对 product `default`，target SDK `26.0.0`、compatible SDK `6.1.1(24)`。若 IDE 缺少相应 HarmonyOS SDK，换用配套 IDE/SDK，不能为消除提示直接降低工程版本。
4. AGC → **开发与服务 → 约定项目 → 约定应用 → 项目设置**，下载 `agconnect-services.json`，放到：

   ```text
   Application/AppScope/resources/rawfile/agconnect-services.json
   ```

   当前 `@hw-agconnect/core-ohos` 默认通过初始化时传入的 Context 的资源管理器读取 rawfile，本项目按 SDK 说明将配置放在 `AppScope/resources/rawfile`。每次新克隆或新解压工程都要补齐该文件，并确认本次生成的 HAP 包含它；另一份工程已有配置不能替代这一步。配置缺失时，获取邮箱验证码可能出现 `9001005 / GetRawFileContent failed`。该配置包含本地凭据，继续由 Git 忽略。

5. 保持项目现有依赖：entry 的 AGC SDK 与 `@shike/cloud-objects`本地 HAR 由 OHPM 安装；不要把云端 Node.js 依赖装进客户端。若下载时开启“不包含密钥”，SDK 还需要额外初始化配置；当前工程没有这条手动注入流程，首次联调不能仅去掉字段而不调整初始化。

配置下载参见官方[获取 HarmonyOS SDK 配置信息](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/harmony-api6-obtain-files-0000001553463638)。完成标志：工程显示两个模块，同步无错误，rawfile 配置属于约定 AGC 应用。此时尚不代表签名和云调用已通过。

<a id="clouddev"></a>

## 5. 确认云端关联和已部署资源

**接手团队已有后端：**复用约定测试项目，不要求每位成员部署一套资源。管理员需先确认已开通邮箱认证、Cloud DB、Cloud Storage，并部署四个项目云对象。

**仅做客户端模拟器联调：**管理员确认团队后端已经部署可用后，补齐第 4 节的 SDK 配置，直接按第 6～8 节继续。无需为每位成员新建后端，也无需先取得 `cloud-config.json`；下面的端云工程关联步骤供需要在 IDE 中开发或部署云端的成员使用。

1. 客户端先打开 `Application`。不要直接将仓库外层当作端云工程打开：26.0.0.821 的端云识别逻辑要求外层只有 `Application` 与 `CloudProgram` 两个非隐藏条目，本仓库外层的 README 和索引会影响该识别。需要 IDE 内云端开发/部署时，按 [云端指南](CloudProgram/README.md#1-创建-agc-项目与应用)先创建或迁移一个规范端云工程，再引入本项目源码、关联团队已有应用；仅补齐 cloud-config.json 不能解决目录识别。
2. `Tools > CloudDev`打开云开发管理面板；未登录时点击 `Sign in`，使用已获团队授权的账号。通过 `Serverless > Cloud Functions > Go to console`或面板中的控制台入口进入资源页。
3. 首次克隆没有 `CloudProgram/cloud-config.json`。由管理员通过安全渠道提供目标测试项目的关联配置，或按 [云端指南](CloudProgram/README.md#1-创建-agc-项目与应用)的向导关联已有应用并生成配置；不需要另建个人后端。补齐后，在自己的界面核对 `CloudProgram/cloud-config.json`的 `teamId`、`appSelected.projectId`、`appSelected.appId`，与管理员给出的团队、项目和应用相符。该文件是 IDE 生成的关联元数据，不是团队授权或运行 Token，不通过手写 ID/uid 来“加入团队”。
4. 控制台应有 `shike-auth`、`shike-media`、`shike-service`、`shike-location`；Cloud DB 存储区应为 `shike`。确认配置、生效版本和服务端秘密已由负责人设置，再继续客户端联调。

**需要新建独立测试后端、或缺少云关联配置：**按 [CloudProgram/README](CloudProgram/README.md)的从零步骤，由负责人创建/关联资源。官方向导在创建 `[CloudDev]Empty Ability`工程时，按 `Team + Bundle name`查找同包名 AGC 应用；不要用示例 Post/id-generator 代替本项目数据和函数。

`cloud-config.json`（IDE 部署关联）、`agconnect-services.json`（端侧 AGC SDK 配置）、调试 Profile（应用身份）必须指向一致资源。只放 SDK JSON 文件不会替代云工程关联、团队权限或签名。

参考官方[CloudDev 管理面板](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-console)与[创建/关联端云工程](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-create-appproject)。

## 6. 创建手机模拟器和调试签名

1. 进入 `Tools > Device Manager > Local Emulator`。首次使用可选择预置手机模拟器并下载镜像；自己创建则点击 `New Emulator`。
2. 选择手机模板和 **API24 或以上的 HarmonyOS 镜像**，根据工具支持选择与电脑 CPU 架构匹配的镜像，首次点击 `Image`下载。设置模拟器名称等参数后 `Finish`。
3. 在 Device Manager 启动模拟器，等待进入系统桌面，确认 IDE 顶部设备列表能选到它。新版也可从预置/已创建设备列表一键启动。
4. 在客户端窗口进入 `File > Project Structure > Project > Signing Configs`，选择 **`Associate with registered application`**，点击 `Sign In`登录成员账号。
5. 在 `Team`下拉框选约定团队；IDE 按 `com.wyq.shike`查询同包名注册应用。选择正确应用，按提示完成签名；需要时由管理员确认 Location/Account 等开放能力，Push 留待相应能力联调。
6. 保存后检查**调试 Profile** 的包名、有效期与当前模拟器；确认 product `default` 的 `signingConfig` 引用这套调试签名。构建模式 debug 与签名配置是两个设置；配置名叫 default 或 release 也不能代替检查 Profile 的实际类型。使用发布类型 Profile 时可能出现“无法验证应用，需要先联网验证”的启动拦截。若提示找不到应用，先排查团队、包名、应用授权；若提示无权创建证书/Profile，返回第 3 步补授权。

普通模拟器页面调试可能无需签名，但本项目 Cloud Foundation 云调用要求**关联注册应用的自动签名或匹配应用的手动签名**。不要只勾未关联应用的自动签名，也不要复制其他成员的证书路径/口令。系统时间异常时，按[官方签名指引](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto)校准。

参见官方[创建模拟器](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-emulator-create)、[自动签名](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto)。

## 7. 首次运行并注册模拟器云调试凭据

1. 客户端窗口顶部选择模块 **`entry`**、构建模式 **debug**、刚启动的手机模拟器，点击 Run。若没有运行配置，用 `Run > Edit Configurations`创建/选择 HarmonyOS 应用运行配置，模块选 entry。
2. 等待 Build 与安装完成；应用内同意隐私后直接进入游客首页。首页公开列表会触发云对象调用，无需登录或定位；**新模拟器尚未注册云调试凭据时，该调用失败是此步骤的预期现象**。
3. 打开 IDE 底部 **HiLog**，选对应设备，切换为 **`No filters`**，搜索 **`clouddevelopproxy.debugToken`**。应用日志过滤可能把系统输出的凭据隐藏掉。
4. 找到 `[clouddevelopproxy.debugToken=xxx]`，只复制其中 `xxx`。
5. AGC → **证书、APP ID和Profile → 模拟器调试凭据 → 注册凭据**：选择应用名称，确认自动填充包名为 `com.wyq.shike`，粘贴调试凭据，填写备注，点击“注册”。成员没有入口时交由管理员在控制台登记，凭据不要放到 GitHub。
6. 注册成功后重新运行应用或刷新首页。应能以游客身份读取全部公开推荐及图片；没有公开数据时允许为空。游客导航仅保留“推荐、我的”，随后通过“我的 → 登录 / 注册”使用测试邮箱验证账号功能；登录后恢复“推荐、榜单、好友、制作、我的”五个页签。

找不到凭据：检查模拟器网络、签名方式，并确保触发了 Cloud Foundation **业务云调用**；只发邮箱验证码不能代替该调用。401/403 或 `create http task error`：检查是否未注册、绑定错应用、团队/签名/SDK 配置不一致。绑定错应用时，删除错误凭据、重新绑定，按官方要求等待 30 分钟再试。新建模拟器或重置后重新检查实际凭据，不假定已登记其他模拟器就自动生效。

**补充提醒：**

- 改过签名后若报 `9568332 / install sign info inconsistent`，卸载模拟器里的旧应用且不保留数据，再安装；卸载会清除本地数据和登录状态。
- 报 `9568320 / no signature file` 时，检查当前 product 的签名绑定，以及 Run 实际部署的是否为本次生成的签名包。
- 只有原凭据绑定错应用、删除后重新绑定的情况，按[官方要求](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/agc-help-add-credential-0000002415343501)等待 **30 分钟**再调试。更换或重置模拟器后，重新核对实际凭据。
- 找不到凭据时，确认已触发云调用且使用无过滤器；只发送邮箱验证码不会触发这项云调用。仍失败时提供对应操作前后约 10 秒的日志，并遮盖凭据与业务 Token。

参见官方[使用模拟器调试云服务](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/cloudfoundation-emulator)和[注册模拟器调试凭据](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/agc-help-add-credential-0000002415343501)。

## 8. 设置测试位置，进行断点调试

1. 游客首页无需配置 GPS 或授予位置权限，直接显示所有 APPROVED 卡片，按发布时间分页。拒绝定位或模拟器没有位置也应能浏览；若云端没有公开卡片，页面会显示空状态。
2. 验证发布或已登录的“附近口碑榜”时，再通过模拟器 **GPS 定位** 设置测试区域经纬度，开启定位服务，并授予**模糊位置和精确位置**。附近榜仍使用 20 km 查询，首页不受这项限制。没有公开数据时，用测试账号制作发布一张卡后切回游客浏览。
3. 准备有权使用的测试图片，通过模拟器的文件上传能力放入设备，并确认系统 Photo Picker 能选到。测试邮箱需真实可收验证码，团队成员账号不会自动成为应用测试账号。
4. 在 `entry/src/main/ets/pages/Index.ets`、`NearbyPage.ets`或目标 Service 的可执行代码行左侧点击设置断点。仍选择 entry/debug/目标模拟器，点击 **Debug**。
5. 触发对应操作；暂停后看 **Frames/Variables**，使用 Step Over/Step Into/Resume 检查流程。Run 只启动应用，要命中调试断点需启动 Debug 会话。
6. 客户端错误看 HiLog/Build Output；云对象错误到 CloudDev/AGC 查看对应函数和生效版本的日志。端侧断点不会暂停 AGC 远端 runtime；云对象本地/远程调用调试见云端 README。

第一轮客户端联调完成标志：**同步/安装成功 → 注册模拟器调试凭据 → 游客列表与图片/详情可用（无数据时允许正常空状态）→ 邮箱登录和资料读取成功 → 目标断点可暂停**。验证发布或附近口碑榜时再配置定位；近场分享、跨设备、真实性能需按平台能力用真机验证。

参考官方[GPS 扩展能力](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-emulator-more-features)、[ArkTS debug 调试](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-debug-arkts-debug)、[模拟器与真机差异](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-emulator-specification)。也可观看官方[HarmonyOS 第一课：DevEco Studio 的使用](https://developer.huawei.com/consumer/cn/training/course/slightMooc/C101717494752698457?pathId=101667550095504391)中的环境搭建、模拟器与真机调试章节。

## 常见问题与反馈

| 现象 | 优先检查 |
| --- | --- |
| 克隆后没有客户端 | 是否克隆完整仓库并切到正确分支；仓库根目录应有 Application 与 CloudProgram |
| 提示“目录不包含项目” | 完整解压后打开 Application；确认 `.idea/.gitignore` 和三个 build-profile.json5 存在，旧 ZIP 请重新下载最新 main |
| 工程已打开但没有 entry/同步失败 | SDK 是否与工程要求配套，OHPM 同步是否成功；保留首条同步错误 |
| AGC/IDE 找不到团队或应用 | 被添加的个人账号、团队切换、项目/应用授权范围和有效期；签名 Team 与包名 |
| 签名按钮报无权限 | 调试证书/Profile 权限；由管理员授予或完成操作 |
| 安装失败 `9568320 / no signature file` | 当前 product 的签名绑定、SignHap 任务和实际安装包路径；见第 6 节及第 7 节补充提醒 |
| 安装失败 `9568332 / install sign info inconsistent` | 切换签名后旧应用仍保留，或模块间签名不一致；卸载不保留数据后重装，见第 7 节补充提醒 |
| 系统弹出“无法验证应用，需要先联网验证” | 实际 Profile 是否为调试类型、当前产品的签名绑定；见第 6 节 |
| CloudDev 资源页与约定不同 | 外层工程、cloud-config 关联、登录团队、应用所属项目与中国数据处理位置 |
| SDK 配置读取失败 | rawfile 文件是否来自正确 AGC 应用，文件名与位置是否准确 |
| 云调用 401/403 | 凭据注册/绑定、关联应用签名、网络；同时检查业务用户 Token 是否有效 |
| 邮箱登录提示“食刻资料初始化失败”且 `401 ... verify signature failed` | 已进入邮箱认证后的云端资料读取阶段，先核对模拟器调试凭据登记和应用绑定；见第 7 节 |
| 邮箱无验证码 | AGC 邮箱认证开关、邮箱/反垃圾、发送间隔；和云对象调试凭据分别排查 |
| 游客首页列表为空 | 先区分正常空状态与加载错误；确认 shike-service 为最新版、FoodCard 公开状态及两个公开列表索引，参见云端指南；首页无需定位 |
| 附近口碑榜空/定位失败 | GPS、系统定位开关、双权限、20km 内公开带图测试数据；位置缓存 90 秒，改位置后刷新或等过期 |
| 图片上传/详情失败 | shike-media 云版本、runtime 同级打包和生产依赖；不要用 Sync 当作部署修复 |
| 断点没停 | 是否 Debug、可执行代码行、正确模块/设备；云端代码需单独调试 |

回传：**操作到第几步、预期/实际、首条完整错误及前后约 20 行脱敏日志、DevEco/SDK/镜像/API 版本、对应页面截图**。保留错误码/文件/行号，遮盖邮箱、Token、调试凭据、验证码、私钥和密码；不要发送完整 AGC/签名配置。

## 文档入口

| 文档 | 用途 |
| --- | --- |
| [PROJECT_FILE_INDEX.md](PROJECT_FILE_INDEX.md) | 当前 Application/CloudProgram 的目录、文件职责和修改入口 |
| [CloudProgram/README.md](CloudProgram/README.md) | 新建测试后端、云开发部署/调试与环境变量 |

## 官方资料速查

以下按主题汇总本文引用的华为官方文档与控制台入口，便于直接跳转核对。

### 开发工具与账号

| 资料 | 链接 |
| --- | --- |
| DevEco Studio 下载中心 | https://developer.huawei.com/consumer/cn/download/deveco-studio |
| 安装教程 | https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-software-install |
| 网络配置 | https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-environment-config |
| 云开发账号准备 | https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-account |
| 团队账号列表（加入团队） | https://developer.huawei.com/consumer/cn/console/setting/teamAccountInfoList |
| 团队账号说明 | https://developer.huawei.com/consumer/cn/Team-account/ |
| 管理团队帐号 | https://developer.huawei.com/consumer/cn/doc/app/agc-help-manageaccount-0000002306610129 |
| AGC 控制台 | https://developer.huawei.com/consumer/cn/service/josp/agc/index.html |

### 客户端工程与 AGC 配置

| 资料 | 链接 |
| --- | --- |
| 获取 HarmonyOS SDK 配置信息 | https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/harmony-api6-obtain-files-0000001553463638 |

### 端云工程与云开发

| 资料 | 链接 |
| --- | --- |
| CloudDev 管理面板 | https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-clouddev-console |
| 创建/关联端云工程 | https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-create-appproject |
| 关联云开发资源 | https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-create-appproject |

### 模拟器、签名与云调试凭据

| 资料 | 链接 |
| --- | --- |
| 创建模拟器 | https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-emulator-create |
| 自动签名 | https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto |
| 使用模拟器调试云服务 | https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/cloudfoundation-emulator |
| 注册模拟器调试凭据 | https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/agc-help-add-credential-0000002415343501 |
| GPS 扩展能力 | https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-emulator-more-features |
| ArkTS debug 调试 | https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-debug-arkts-debug |
| 模拟器与真机差异 | https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-emulator-specification |

### 学习资源

| 资料 | 链接 |
| --- | --- |
| HarmonyOS 第一课：DevEco Studio 的使用 | https://developer.huawei.com/consumer/cn/training/course/slightMooc/C101717494752698457?pathId=101667550095504391 |
