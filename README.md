# 食刻

食刻是使用 **ArkTS / ArkUI + AppGallery Connect（AGC）** 开发的 HarmonyOS 美食推荐应用。客户端在 `Application/`，云端源码在 `CloudProgram/`。

这份说明用于新协作者从零获取代码、加入团队并完成**手机模拟器端云联调**。先按下面顺序操作，源码职责另查 [文件索引](PROJECT_FILE_INDEX.md)。

> 官方资料核对日期：2026-10-02。下文保留官方英文菜单名，中文界面的名称可能略有不同。SDK/包名按项目要求使用，IDE 的新版本号不等于项目 targetSdkVersion。

## 1. 安装开发工具

1. 安装 Git。
2. 到华为 [DevEco Studio 下载中心](https://developer.huawei.com/consumer/cn/download/deveco-studio)登录华为账号，按电脑系统和 CPU 架构下载安装包，选择能支持本项目 `26.0.0` SDK 的版本。Windows 运行安装向导；macOS 将应用拖入 Applications。
3. 新版 DevEco Studio 已打包 HarmonyOS SDK、Node.js、Hvigor、OHPM 和模拟器平台，**无需照旧教程单独下载 HarmonyOS SDK**；模拟器镜像仍需要下载。首次启动不迁移他人的设置。
4. 在欢迎页点 `Diagnose`，或打开工程后进入 `Help > Diagnostic Tools > Diagnose Development Environment`，按提示处理网络与工具环境问题。需要代理时，Windows 从 `File > Settings`、macOS 从 `DevEco Studio > Preferences/Settings`进入配置；IDE HTTP、NPM、OHPM 和模拟器网络分别排查。
5. 注册自己的华为开发者账号并实名认证。当前官方云开发准备要求账号注册地为中国境内（不含港澳台）；确认符合条件后由管理员加入团队。AGC、IDE 都使用这个成员账号登录。

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
└── CloudProgram/        # 云开发工程：开发云端时打开外层目录
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

1. 账号持有者或有“管理用户及访问权限”的成员登录 [AGC](https://developer.huawei.com/consumer/cn/service/josp/agc/index.html)，进入 `用户与权限 > 用户 > 所有用户 > 添加`，按提示前往开发者联盟团队账号页面。也可从开发者联盟管理中心的 `开发者中心 > 团队账号`进入。
2. 添加协作者**自己的华为账号**，按页面填写成员信息与角色；无需分享持有者密码。成员收到邀请/确认提示时，完成相应确认。
3. 回到 AGC 的该成员“编辑”页，在角色管理中按职责配置“开发”等角色，并检查实际权限；承担云端部署的成员必须有云开发服务相应操作权限。
4. 在“项目与应用权限”里分别确认测试项目和 `com.wyq.shike` 应用的授权范围。**项目权限与应用权限独立**，不能仅凭看得到应用就认为能管理该项目的云资源。
5. 在证书与 Profile 权限中授予联调所需调试证书、调试 Profile 权限；确认允许管理模拟器调试凭据。无法授权或缺少入口时，由具备该权限的管理员完成对应操作。
6. 保存，检查成员权限有效期。将团队标识、测试项目名称/ID、应用名称/APP ID/包名、数据处理位置、部署负责人交给成员；分享秘密值使用团队约定的安全渠道。

### 新成员操作

1. 用被添加的账号登录 AGC，点击右上角账号菜单，**切换到项目所属团队**；控制台可能默认打开个人团队或上次访问的团队。
2. 在“用户与权限”的个人信息中确认角色、项目/应用范围和有效期；进入“开发与服务”选择约定项目，核对应用包名 `com.wyq.shike`，数据处理位置含**中国**。
3. 应能看到对应云函数/云对象、Cloud DB、Storage，以及应用配置。缺少项目、按钮灰色或无签名权限时，回传缺失入口与页面错误给管理员，逐项补授权，不另建个人项目替代。
4. IDE 的登录账号和签名页面 `Team` 也要选同一团队。GitHub 仓库读写权限另由仓库管理员分配。

以上参照官方[团队账号说明](https://developer.huawei.com/consumer/cn/Team-account/)与[管理团队帐号](https://developer.huawei.com/consumer/cn/doc/app/agc-help-manageaccount-0000002306610129)。云开发协议若尚未签署，须由**账号持有者或法务角色**完成；开发成员的项目授权不能替代签约。参见[关联云开发资源](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/agc-harmonyos-create-appproject)。

## 4. 补齐客户端配置，打开工程

签名与 SDK 应用配置不在 Git 中共享。首次拉取时需要补齐三个被忽略的 build profile；**已有文件不要覆盖**。

<details>
<summary>首次拉取代码：三个 build-profile.json5 的最小内容</summary>

`Application/build-profile.json5`：

```json
{
  "app": {
    "signingConfigs": [],
    "products": [{
      "name": "default",
      "compatibleSdkVersion": "6.1.1(24)",
      "targetSdkVersion": "26.0.0",
      "runtimeOS": "HarmonyOS"
    }],
    "buildModeSet": [{ "name": "debug" }, { "name": "release" }]
  },
  "modules": [
    { "name": "entry", "srcPath": "./entry", "targets": [{ "name": "default", "applyToProducts": ["default"] }] },
    { "name": "cloud_objects", "srcPath": "./cloud_objects", "targets": [{ "name": "default", "applyToProducts": ["default"] }] }
  ]
}
```

`Application/entry/build-profile.json5`：

```json
{
  "apiType": "stageMode",
  "buildOption": {},
  "targets": [{ "name": "default" }]
}
```

`Application/cloud_objects/build-profile.json5`：

```json
{
  "apiType": "stageMode",
  "buildOption": { "resOptions": { "copyCodeResource": { "enable": false } } },
  "targets": [{ "name": "default" }]
}
```

</details>

1. `File > Open`选择 **`shikeclouddev/Application`**，作为客户端运行窗口。
2. 等待工程同步和 OHPM 安装完成，确认识别 `entry`、`cloud_objects`。未自动同步时使用工具栏工程同步按钮；只执行终端 `npm install`不能替代端侧 OHPM 同步。
3. `File > Project Structure`核对 product `default`，target SDK `26.0.0`、compatible SDK `6.1.1(24)`。若 IDE 缺少相应 HarmonyOS SDK，换用配套 IDE/SDK，不能为消除提示直接降低工程版本。
4. AGC → **开发与服务 → 约定项目 → 约定应用 → 项目设置**，下载 `agconnect-services.json`，放到：

   ```text
   Application/entry/src/main/resources/rawfile/agconnect-services.json
   ```

5. 保持项目现有依赖：entry 的 AGC SDK 与 `@shike/cloud-objects`本地 HAR 由 OHPM 安装；不要把云端 Node.js 依赖装进客户端。若下载时开启“不包含密钥”，SDK 还需要额外初始化配置；当前工程没有这条手动注入流程，首次联调不能仅去掉字段而不调整初始化。

配置下载参见官方[获取 HarmonyOS SDK 配置信息](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/harmony-api6-obtain-files-0000001553463638)。完成标志：工程显示两个模块，同步无错误，rawfile 配置属于约定 AGC 应用。此时尚不代表签名和云调用已通过。

<a id="clouddev"></a>

## 5. 确认云端关联和已部署资源

**接手团队已有后端：**复用约定测试项目，不要求每位成员部署一套资源。管理员需先确认已开通邮箱认证、Cloud DB、Cloud Storage，并部署四个项目云对象。

1. 需要查看/开发云端时，再用 `File > Open`打开外层 **`shikeclouddev/`**，可选 `New Window`保留客户端窗口。确认能看到 `Application`、`CloudProgram`两个目录。
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
6. 保存后检查 Profile 的包名、有效期与当前模拟器；确认 product `default`使用生成的签名。若提示找不到应用，先排查团队、包名、应用授权；若提示无权创建证书/Profile，返回第 3 步补授权。

普通模拟器页面调试可能无需签名，但本项目 Cloud Foundation 云调用要求**关联注册应用的自动签名或匹配应用的手动签名**。不要只勾未关联应用的自动签名，也不要复制其他成员的证书路径/口令。系统时间异常时，按官方签名指引校准。

参见官方[创建模拟器](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-emulator-create)、[自动签名](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto)。

## 7. 首次运行并注册模拟器云调试凭据

1. 客户端窗口顶部选择模块 **`entry`**、构建模式 **debug**、刚启动的手机模拟器，点击 Run。若没有运行配置，用 `Run > Edit Configurations`创建/选择 HarmonyOS 应用运行配置，模块选 entry。
2. 等待 Build 与安装完成；应用内同意隐私，使用测试邮箱验证码注册/登录。登录后的资料读取会触发云对象调用；**新模拟器尚未注册云调试凭据时，该调用失败是此步骤的预期现象**。
3. 打开 IDE 底部 **HiLog**，选对应设备，切换为 **`No filters`**，搜索 **`clouddevelopproxy.debugToken`**。应用日志过滤可能把系统输出的凭据隐藏掉。
4. 找到 `[clouddevelopproxy.debugToken=xxx]`，只复制其中 `xxx`。
5. AGC → **证书、APP ID和Profile → 模拟器调试凭据 → 注册凭据**：选择应用名称，确认自动填充包名为 `com.wyq.shike`，粘贴调试凭据，填写备注，点击“注册”。成员没有入口时交由管理员在控制台登记，凭据不要放到 GitHub。
6. 注册成功后重新运行应用，再次登录或重试失败请求。应能取得资料、进入首页并调用附近列表；没有测试数据时允许为空。

找不到凭据：检查模拟器网络、签名方式，并确保触发了 Cloud Foundation **业务云调用**；只发邮箱验证码不能代替该调用。401/403 或 `create http task error`：检查是否未注册、绑定错应用、团队/签名/SDK 配置不一致。绑定错应用时，删除错误凭据、重新绑定，按官方要求等待 30 分钟再试。新建模拟器或重置后重新检查实际凭据，不假定已登记其他模拟器就自动生效。

参见官方[使用模拟器调试云服务](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/cloudfoundation-emulator)和[注册模拟器调试凭据](https://developer.huawei.com/consumer/cn/doc/app/agc-help-add-credential-0000002415343501)。

## 8. 设置测试位置，进行断点调试

1. 模拟器右侧工具栏打开扩展菜单，进入 **GPS 定位**，手动填写测试区域经纬度，或选城市；只改电脑所在位置不会设置模拟器 GPS。模拟器系统内也要开启定位服务。
2. 应用同时授予**模糊位置和精确位置**，刷新“附近”。本项目只查询 20km 内公开且带实拍图的卡片；没有数据时，用测试账号在该位置制作发布一张卡。
3. 准备有权使用的测试图片，通过模拟器的文件上传能力放入设备，并确认系统 Photo Picker 能选到。测试邮箱需真实可收验证码，团队成员账号不会自动成为应用测试账号。
4. 在 `entry/src/main/ets/pages/Index.ets`、`NearbyPage.ets`或目标 Service 的可执行代码行左侧点击设置断点。仍选择 entry/debug/目标模拟器，点击 **Debug**。
5. 触发对应操作；暂停后看 **Frames/Variables**，使用 Step Over/Step Into/Resume 检查流程。Run 只启动应用，要命中调试断点需启动 Debug 会话。
6. 客户端错误看 HiLog/Build Output；云对象错误到 CloudDev/AGC 查看对应函数和生效版本的日志。端侧断点不会暂停 AGC 远端 runtime；云对象本地/远程调用调试见云端 README。

第一轮完成标志：**同步/安装成功 → 邮箱登录和资料读取成功 → 定位权限与测试位置有效 → 测试卡片列表、图片和详情可用 → 目标断点可暂停**。近场分享、跨设备、真实性能需按平台能力用真机验证。

参考官方[GPS 扩展能力](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-emulator-more-features)、[ArkTS debug 调试](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-debug-arkts-debug)、[模拟器与真机差异](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-emulator-specification)。也可观看官方[HarmonyOS 第一课：DevEco Studio 的使用](https://developer.huawei.com/consumer/cn/training/course/slightMooc/C101717494752698457?pathId=101667550095504391)中的环境搭建、模拟器与真机调试章节。

## 常见问题与反馈

| 现象 | 优先检查 |
| --- | --- |
| 克隆后没有客户端 | 是否克隆完整仓库并切到正确分支；仓库根目录应有 Application 与 CloudProgram |
| 工程不识别/没有 entry | 客户端窗口是否打开 Application，三个 build profile 是否齐全，SDK 与 OHPM 是否同步 |
| AGC/IDE 找不到团队或应用 | 被添加的个人账号、团队切换、项目/应用授权范围和有效期；签名 Team 与包名 |
| 签名按钮报无权限 | 调试证书/Profile 权限；由管理员授予或完成操作 |
| CloudDev 资源页与约定不同 | 外层工程、cloud-config 关联、登录团队、应用所属项目与中国数据处理位置 |
| SDK 配置读取失败 | rawfile 文件是否来自正确 AGC 应用，文件名与位置是否准确 |
| 云调用 401/403 | 凭据注册/绑定、关联应用签名、网络；同时检查业务用户 Token 是否有效 |
| 邮箱无验证码 | AGC 邮箱认证开关、邮箱/反垃圾、发送间隔；和云对象调试凭据分别排查 |
| 附近空/定位失败 | GPS、系统定位开关、双权限、20km 内公开带图测试数据；位置缓存 90 秒，改位置后刷新或等过期 |
| 图片上传/详情失败 | shike-media 云版本、runtime 同级打包和生产依赖；不要用 Sync 当作部署修复 |
| 断点没停 | 是否 Debug、可执行代码行、正确模块/设备；云端代码需单独调试 |

回传：**操作到第几步、预期/实际、首条完整错误及前后约 20 行脱敏日志、DevEco/SDK/镜像/API 版本、对应页面截图**。保留错误码/文件/行号，遮盖邮箱、Token、调试凭据、验证码、私钥和密码；不要发送完整 AGC/签名配置。

## 文档入口

| 文档 | 用途 |
| --- | --- |
| [PROJECT_FILE_INDEX.md](PROJECT_FILE_INDEX.md) | 当前 Application/CloudProgram 的目录、文件职责和修改入口 |
| [CloudProgram/README.md](CloudProgram/README.md) | 新建测试后端、云开发部署/调试与环境变量 |
