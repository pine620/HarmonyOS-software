import { AppDestinationStyle } from '../common/AppPageUi';
import { common } from '@kit.AbilityKit';
import { UserProfile } from '../model/CloudContracts';
import { AuthService } from '../service/AuthService';
import { LocationService } from '../service/LocationService';
import { PushNotificationService, PushNotificationStatus } from '../service/PushNotificationService';
import { ServiceCardRemoteSyncService, ServiceCardRemoteSyncStatus } from '../service/ServiceCardRemoteSyncService';
import { ErrorDetail, errorText } from '../common/ErrorKit';

// Pack 4.3 (2026-10-15): split out of ProfileSubPages.ets without behaviour changes.

@Component
export struct PermissionsPrivacyPage {
  @State permissionStatus: string = '位置权限：待检查';
  @State notificationStatus: string = '通知：待检查';
  @State notificationSupported: boolean = false;
  @State notificationEnabled: boolean = false;
  @State notificationRegistered: boolean = false;
  @State serviceCardSyncStatus: string = '桌面卡片同步：待检查';
  @State serviceCardSyncSupported: boolean = false;
  @State serviceCardSyncEnabled: boolean = false;
  @State serviceCardSyncRegistered: boolean = false;
  @State status: string = '';
  @State loading: boolean = false;
  @State showPrivacy: boolean = false;

  aboutToAppear(): void {
    this.refresh();
  }

  private async refresh(clearStatus: boolean = true): Promise<void> {
    if (this.loading) return;
    this.loading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.permissionStatus = await LocationService.permissionSummary(context);
      const pushStatus: PushNotificationStatus = await PushNotificationService.status(context);
      this.notificationSupported = pushStatus.supported;
      this.notificationEnabled = pushStatus.optedIn;
      this.notificationRegistered = pushStatus.registered;
      const serviceCardStatus: ServiceCardRemoteSyncStatus = ServiceCardRemoteSyncService.status(context);
      this.serviceCardSyncSupported = serviceCardStatus.supported;
      this.serviceCardSyncEnabled = serviceCardStatus.optedIn;
      this.serviceCardSyncRegistered = serviceCardStatus.registered;
      if (!pushStatus.supported) {
        this.notificationStatus = '当前设备不支持 Push Kit';
      } else if (pushStatus.registered) {
        this.notificationStatus = '食刻通知已开启并完成设备登记';
      } else if (pushStatus.optedIn) {
        this.notificationStatus = pushStatus.enabled
          ? '食刻通知已开启，设备登记待确认'
          : '食刻通知已开启，但系统通知权限已关闭';
      } else if (pushStatus.enabled) {
        this.notificationStatus = '系统通知已允许，食刻通知未开启';
      } else {
        this.notificationStatus = '食刻通知未开启';
      }
      if (!serviceCardStatus.supported) {
        this.serviceCardSyncStatus = '当前设备不支持 Push Kit 桌面卡片同步';
      } else if (serviceCardStatus.registered) {
        this.serviceCardSyncStatus = `已开启并登记 ${serviceCardStatus.formCount} 张桌面卡片`;
      } else if (serviceCardStatus.optedIn && serviceCardStatus.formCount === 0) {
        this.serviceCardSyncStatus = '已开启，等待将食刻卡片添加到桌面';
      } else if (serviceCardStatus.optedIn) {
        this.serviceCardSyncStatus = '已开启，桌面卡片登记待确认';
      } else {
        this.serviceCardSyncStatus = '桌面卡片远程同步未开启';
      }
      if (clearStatus) this.status = '';
    } catch (error) {
      this.status = `权限状态刷新失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.loading = false;
    }
  }

  private async enableNotifications(): Promise<void> {
    if (this.loading) return;
    const profile: UserProfile | undefined = AuthService.profile();
    if (profile === undefined) {
      this.status = '登录状态已失效，请重新登录后开启通知。';
      return;
    }
    this.loading = true;
    this.status = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await PushNotificationService.enable(context, profile.uid);
      this.status = '好友、私信与群聊通知已开启。';
    } catch (error) {
      this.status = `通知开启失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.loading = false;
      await this.refresh(false);
    }
  }

  private async disableNotifications(): Promise<void> {
    if (this.loading) return;
    this.loading = true;
    this.status = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await PushNotificationService.disable(context);
      this.status = '食刻好友通知已关闭，设备推送登记已删除。';
    } catch (error) {
      this.status = `通知关闭未完全完成：${errorText(error as ErrorDetail)}`;
    } finally {
      this.loading = false;
      await this.refresh(false);
    }
  }

  private async retryNotificationRegistration(): Promise<void> {
    if (this.loading) return;
    const profile: UserProfile | undefined = AuthService.profile();
    if (profile === undefined) {
      this.status = '登录状态已失效，请重新登录后完成通知设备登记。';
      return;
    }
    this.loading = true;
    this.status = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await PushNotificationService.enable(context, profile.uid);
      this.status = '通知设备登记已完成。';
    } catch (error) {
      this.status = `通知设备登记未完成：${errorText(error as ErrorDetail)}`;
    } finally {
      this.loading = false;
      await this.refresh(false);
    }
  }

  private async enableServiceCardSync(): Promise<void> {
    if (this.loading) return;
    if (AuthService.profile() === undefined) {
      this.status = '登录状态已失效，请重新登录后开启桌面卡片远程同步。';
      return;
    }
    this.loading = true;
    this.status = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result = await ServiceCardRemoteSyncService.enable(context);
      this.status = result.registeredFormCount > 0
        ? `已登记 ${result.registeredFormCount} 张桌面卡片；手动刷新附近推荐时将同步公开摘要。`
        : '桌面卡片远程同步已开启；添加食刻卡片到桌面后，打开应用并刷新附近推荐即可完成登记。';
    } catch (error) {
      this.status = `桌面卡片同步开启失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.loading = false;
      await this.refresh(false);
    }
  }

  private async disableServiceCardSync(): Promise<void> {
    if (this.loading) return;
    this.loading = true;
    this.status = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await ServiceCardRemoteSyncService.disable(context);
      this.status = '桌面卡片远程同步已关闭，云端卡片登记已删除。';
    } catch (error) {
      this.status = `桌面卡片同步关闭未完全完成：${errorText(error as ErrorDetail)}`;
    } finally {
      this.loading = false;
      await this.refresh(false);
    }
  }

  private async retryServiceCardRegistration(): Promise<void> {
    if (this.loading) return;
    if (AuthService.profile() === undefined) {
      this.status = '登录状态已失效，请重新登录后完成桌面卡片登记。';
      return;
    }
    this.loading = true;
    this.status = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result = await ServiceCardRemoteSyncService.enable(context);
      this.status = result.registeredFormCount > 0
        ? `桌面卡片登记已完成，共 ${result.registeredFormCount} 张。`
        : '尚未检测到食刻桌面卡片；添加卡片后再次检查即可。';
    } catch (error) {
      this.status = `桌面卡片登记未完成：${errorText(error as ErrorDetail)}`;
    } finally {
      this.loading = false;
      await this.refresh(false);
    }
  }

  @Builder
  private dataRow(title: string, description: string) {
    Column({ space: 5 }) {
      Text(title).fontSize(15).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.personal_ink')).width('100%')
      Text(description).fontSize(13).lineHeight(20)
        .fontColor($r('app.color.personal_muted')).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 18 }) {
          Column({ space: 12 }) {
            Text('位置权限').fontSize(18).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.personal_ink')).width('100%')
            Text(this.permissionStatus).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.leaf')).width('100%')
            Text('浏览推荐无需定位；仅在发布时按需请求一次精确位置，不会持续定位。')
              .fontSize(13).lineHeight(20).fontColor($r('app.color.personal_muted')).width('100%')
            Button(this.loading ? '正在刷新…' : '刷新权限状态')
              .width('100%').height(48).enabled(!this.loading)
              .backgroundColor($r('app.color.personal_soft')).fontColor($r('app.color.personal_action'))
              .onClick(() => this.refresh())
          }
          .width('100%').padding(16).backgroundColor($r('app.color.personal_surface')).borderRadius(20)
          .border({ width: 1, color: $r('app.color.personal_line') }).alignItems(HorizontalAlign.Start)

          Column({ space: 12 }) {
            Text('食刻通知').fontSize(18).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.personal_ink')).width('100%')
            Text(this.notificationStatus).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.notificationEnabled ? $r('app.color.leaf') : $r('app.color.personal_muted')).width('100%')
            Text('默认关闭。开启后提醒好友申请、申请通过、私信与群聊；系统通知不展示聊天正文。')
              .fontSize(13).lineHeight(20).fontColor($r('app.color.personal_muted')).width('100%')
            if (this.notificationSupported) {
              if (this.notificationEnabled) {
                if (!this.notificationRegistered) {
                  Button(this.loading ? '处理中…' : '重新登记通知设备')
                    .width('100%').height(48).enabled(!this.loading)
                    .backgroundColor($r('app.color.personal_action')).fontColor($r('app.color.personal_surface'))
                    .onClick(() => this.retryNotificationRegistration())
                }
                Button(this.loading ? '处理中…' : '关闭食刻通知')
                  .width('100%').height(48).enabled(!this.loading)
                  .backgroundColor($r('app.color.personal_surface')).fontColor($r('app.color.personal_ink'))
                  .border({ width: 1, color: $r('app.color.personal_line') })
                  .onClick(() => this.disableNotifications())
              } else {
                Button(this.loading ? '处理中…' : '开启食刻通知')
                  .width('100%').height(48).enabled(!this.loading)
                  .backgroundColor($r('app.color.personal_action')).fontColor($r('app.color.personal_surface'))
                  .onClick(() => this.enableNotifications())
              }
            }
          }
          .width('100%').padding(16).backgroundColor($r('app.color.personal_surface')).borderRadius(20)
          .border({ width: 1, color: $r('app.color.personal_line') }).alignItems(HorizontalAlign.Start)

          Column({ space: 12 }) {
            Text('桌面卡片远程同步').fontSize(18).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.personal_ink')).width('100%')
            Text(this.serviceCardSyncStatus).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.serviceCardSyncRegistered ? $r('app.color.leaf') :
                (this.serviceCardSyncEnabled ? $r('app.color.warning') : $r('app.color.personal_muted')))
              .width('100%')
            Text('默认关闭。开启后仅把已审核公开推荐摘要同步到已添加的食刻卡片；不发送定位、实拍图、好友关系或私信。')
              .fontSize(13).lineHeight(20).fontColor($r('app.color.personal_muted')).width('100%')
            if (this.serviceCardSyncSupported) {
              if (this.serviceCardSyncEnabled) {
                if (!this.serviceCardSyncRegistered) {
                  Button(this.loading ? '处理中…' : '检查并登记桌面卡片')
                    .width('100%').height(48).enabled(!this.loading)
                    .backgroundColor($r('app.color.personal_action')).fontColor($r('app.color.personal_surface'))
                    .onClick(() => this.retryServiceCardRegistration())
                }
                Button(this.loading ? '处理中…' : '关闭桌面卡片远程同步')
                  .width('100%').height(48).enabled(!this.loading)
                  .backgroundColor($r('app.color.personal_surface')).fontColor($r('app.color.personal_ink'))
                  .border({ width: 1, color: $r('app.color.personal_line') })
                  .onClick(() => this.disableServiceCardSync())
              } else {
                Button(this.loading ? '处理中…' : '开启桌面卡片远程同步')
                  .width('100%').height(48).enabled(!this.loading)
                  .backgroundColor($r('app.color.personal_action')).fontColor($r('app.color.personal_surface'))
                  .onClick(() => this.enableServiceCardSync())
              }
            }
          }
          .width('100%').padding(16).backgroundColor($r('app.color.personal_surface')).borderRadius(20)
          .border({ width: 1, color: $r('app.color.personal_line') }).alignItems(HorizontalAlign.Start)

          Column({ space: 14 }) {
            Text('数据使用').fontSize(18).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.personal_ink')).width('100%')
            this.dataRow('图片选择', '使用系统 Photo Picker，不申请图库全量读取权限。')
            Divider().strokeWidth(1).color($r('app.color.personal_line'))
            this.dataRow('实拍图上传', '可选实拍图和资料头像均经本机重编码、移除 EXIF/GPS 后上传到 AGC 公开路径。')
            Divider().strokeWidth(1).color($r('app.color.personal_line'))
            this.dataRow('好友与私信', '食刻号用于精确查找；好友关系、会话状态和主动发送的文字、HTTPS 链接、卡片标识保存在 AGC 云端。')
            Divider().strokeWidth(1).color($r('app.color.personal_line'))
            this.dataRow('浏览记录', '最近浏览的卡片名称、分类和时间仅保存在本机，并按登录账号隔离；可随时在浏览记录页清空。')
            Divider().strokeWidth(1).color($r('app.color.personal_line'))
            this.dataRow('通知、桌面卡片与鸿蒙多设备', '好友通知与桌面卡片远程同步分别由你主动开启；两类 Push Token 登记均在云端加密保存，卡片只处理公开摘要，跨设备只接续页面和不透明标识。')
          }
          .width('100%').padding(16).backgroundColor($r('app.color.personal_surface')).borderRadius(20)
          .border({ width: 1, color: $r('app.color.personal_line') }).alignItems(HorizontalAlign.Start)

          Column({ space: 12 }) {
            Text('隐私与数据删除').fontSize(18).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.personal_ink')).width('100%')
            Text('你可删除本人发布的卡片；移除好友会关闭当前会话，历史私信进入清理流程。退出登录会使当前会话失效；本机浏览记录仍按账号保留，可手动清空，注销账号时清理。')
              .fontSize(13).lineHeight(20).fontColor($r('app.color.personal_muted')).width('100%')
            Button(this.showPrivacy ? '收起完整说明' : '查看完整隐私说明')
              .width('100%').height(48).backgroundColor($r('app.color.personal_surface'))
              .fontColor($r('app.color.personal_ink')).border({ width: 1, color: $r('app.color.personal_line') })
              .onClick(() => this.showPrivacy = !this.showPrivacy)
            if (this.showPrivacy) {
              Text('食刻通过邮箱验证码或华为账号验证注册身份，并支持唯一昵称与密码登录。邮箱由 AGC Auth 管理；食刻服务端仅保存加盐密码哈希，不保存明文密码。改昵称会同步改变登录名，业务资料和权限仍关联固定的食刻账号标识。你可在资料页主动填写昵称并选择头像；头像与实拍图均先在本机重编码、移除 EXIF/GPS，再上传到 AGC 公开路径。发布位置只上传三位小数坐标和行政区，浏览位置不写入云端。好友功能会保存食刻号、好友申请、好友关系、会话未读数，以及你主动发送的文字、HTTPS 链接和卡片标识。好友通知和桌面卡片远程同步默认关闭，分别由你主动开启；相关 Push Token 均会加密保存。远程同步只更新已审核公开推荐摘要，不携带定位、实拍图、好友关系或私信。跨设备接续只传页签、卡片 ID 或好友 ID。移除好友时当前会话从双方页面移除，历史私信进入清理流程；所有已发布卡片和商品实拍图统一公开，删除好友或拉黑不影响公开内容浏览；拉黑仍限制好友互动与私信。收藏保存为本人标记，旧清单会合并到收藏，已下线的历史标记、私人备注、吃过时间和评分仅作为历史数据保留，相关编辑入口已下线。测试阶段的实拍图随卡片直接上架；正式上架前应根据平台要求补充内容审核和 HTTPS 隐私政策地址。')
                .fontSize(13).lineHeight(21).fontColor($r('app.color.personal_muted')).width('100%')
                .padding(14).backgroundColor($r('app.color.personal_canvas')).borderRadius(14)
            }
          }
          .width('100%').padding(16).backgroundColor($r('app.color.personal_surface')).borderRadius(20)
          .border({ width: 1, color: $r('app.color.personal_line') }).alignItems(HorizontalAlign.Start)

          if (this.status.length > 0) {
            Text(this.status).fontSize(13).lineHeight(20).fontColor($r('app.color.warning')).width('100%')
              .padding(12).backgroundColor($r('app.color.personal_soft')).borderRadius(14)
          }
        }
        .width('100%').padding({ left: 20, right: 20, top: 12, bottom: 28 })
        .alignItems(HorizontalAlign.Start)
      }.width('100%').height('100%').scrollBar(BarState.Off)
      .backgroundColor($r('app.color.personal_canvas'))
    }.attributeModifier(new AppDestinationStyle('权限与隐私', $r('app.color.personal_canvas'), $r('app.color.personal_header'), 'PERSONAL'))
  }
}
