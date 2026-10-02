import { common } from '@kit.AbilityKit';
import {
  FoodCard, PrepareCardPhotoRequest, PrepareCardPhotoResponse, UpdateProfileRequest, UserProfile
} from '../model/CloudContracts';
import { coverFor } from '../components/FoodCover';
import { cardPriceText } from '../model/CardPrice';
import { CardRepository } from '../repository/CardRepository';
import { CardVisitStore } from '../service/CardVisitStore';
import { AuthService } from '../service/AuthService';
import { LocationService } from '../service/LocationService';
import { AvatarCrop, ImageDimensions, ImagePreparationService, PreparedPhoto } from '../service/ImagePreparationService';
import { PhotoUploadService } from '../service/PhotoUploadService';
import { PushNotificationService, PushNotificationStatus } from '../service/PushNotificationService';
import { ServiceCardRemoteSyncService, ServiceCardRemoteSyncStatus } from '../service/ServiceCardRemoteSyncService';
import { ErrorDetail, errorText } from '../common/ErrorKit';

const AVATAR_CROP_VIEWPORT = 240;
const CLOUD_BUSY_MAX_ATTEMPTS = 3;
const CLOUD_BUSY_RETRY_BASE_DELAY_MS = 800;

function priceText(card: FoodCard): string {
  return cardPriceText(card);
}

function statusText(card: FoodCard): string {
  return card.status === 'APPROVED' ? '已发布' : '已下架';
}

@Component
export struct MyPublishedPage {
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  onCardsChanged: () => void = (): void => {};
  @State cards: Array<FoodCard> = [];
  @State pendingDeleteCardId: string = '';
  @State status: string = '';
  @State loading: boolean = false;
  @State loaded: boolean = false;
  private repository: CardRepository = new CardRepository();
  private hasBeenShown: boolean = false;

  aboutToAppear(): void {
    void this.refresh();
  }

  private async refresh(): Promise<void> {
    if (this.loading) return;
    this.loading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.cards = await this.repository.myCards(context);
      this.status = '';
    } catch (error) {
      this.status = `商品卡片加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.loading = false;
      this.loaded = true;
    }
  }

  private requestDeleteCard(cardId: string): void {
    this.pendingDeleteCardId = cardId;
    this.status = '删除后卡片及实拍图不可恢复，请再次确认。';
  }

  private async deleteCard(cardId: string): Promise<void> {
    if (this.loading) return;
    this.loading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.deleteOwn(context, cardId);
      this.cards = await this.repository.myCards(context);
      this.pendingDeleteCardId = '';
      this.status = '卡片及其云端实拍图已删除。';
      this.onCardsChanged();
    } catch (error) {
      this.status = `删除失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.loading = false;
    }
  }

  @Builder
  private cardRow(card: FoodCard) {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Image(card.photoUrl.length > 0 ? card.photoUrl : coverFor(card.category)).width(64).height(64)
          .objectFit(ImageFit.Cover).borderRadius(14).accessibilityLevel('no')
        Column({ space: 5 }) {
          Text(card.productName).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ink')).width('100%').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(priceText(card)).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(card.priceFen > 0 ? $r('app.color.accent_action') : $r('app.color.muted'))
            .width('100%').maxLines(1)
          Row({ space: 8 }) {
            Text(statusText(card)).fontSize(12)
              .fontColor(card.status === 'APPROVED' ? $r('app.color.leaf') : $r('app.color.danger'))
            if (card.district.length > 0) {
              Text(card.district).fontSize(12).fontColor($r('app.color.muted'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }.width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Image($r('app.media.ic_chevron_right')).width(24).height(24).objectFit(ImageFit.Contain)
          .accessibilityLevel('no')
      }
      .width('100%').accessibilityGroup(true)
      .accessibilityText(`${card.productName}，${priceText(card)}，${statusText(card)}`)
      .accessibilityDescription('点击查看卡片详情')
      .onClick(() => this.onOpenCard(card))

      if (this.pendingDeleteCardId === card.id) {
          Column({ space: 10 }) {
            Text('确认删除这张卡片和对应实拍图？')
              .fontSize(13).lineHeight(20).fontColor($r('app.color.danger')).width('100%')
            Row({ space: 10 }) {
              Button('取消').layoutWeight(1).height(48)
                .backgroundColor($r('app.color.surface')).fontColor($r('app.color.muted'))
                .border({ width: 1, color: $r('app.color.line') })
                .onClick(() => {
                  this.pendingDeleteCardId = '';
                  this.status = '';
                })
              Button('确认删除').layoutWeight(1).height(48).enabled(!this.loading)
                .backgroundColor($r('app.color.danger_action')).fontColor($r('app.color.on_danger_action'))
                .onClick((): void => { void this.deleteCard(card.id); })
            }.width('100%')
          }
          .width('100%').padding(12).backgroundColor($r('app.color.danger_soft')).borderRadius(14)
      } else {
          Row() {
            Blank()
            Button('删除').height(44).fontSize(13)
              .backgroundColor($r('app.color.surface')).fontColor($r('app.color.danger'))
              .border({ width: 1, color: $r('app.color.line') })
              .onClick(() => this.requestDeleteCard(card.id))
          }.width('100%').height(44)
      }
    }
    .width('100%').padding(12).backgroundColor($r('app.color.surface')).borderRadius(18)
    .border({ width: 1, color: $r('app.color.line') })
  }

  build() {
    NavDestination() {
      Column({ space: 14 }) {
        Row() {
          Column({ space: 3 }) {
            Text('我的卡片').fontSize(20).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink'))
            Text(`共 ${this.cards.length} 张商品卡片`)
              .fontSize(12).fontColor($r('app.color.muted'))
          }.alignItems(HorizontalAlign.Start)
          Blank()
          Button(this.loading ? '刷新中' : '刷新').height(48).enabled(!this.loading)
            .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.accent_action'))
            .onClick((): void => { void this.refresh(); })
        }
        .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(18)
        .border({ width: 1, color: $r('app.color.line') })

        if (this.status.length > 0) {
          Text(this.status).fontSize(13).lineHeight(20)
            .fontColor(this.status.includes('失败') ? $r('app.color.warning') : $r('app.color.muted'))
            .width('100%').padding(12).backgroundColor($r('app.color.accent_soft')).borderRadius(14)
        }

        if (!this.loaded || (this.loading && this.cards.length === 0)) {
          Column({ space: 10 }) {
            LoadingProgress().width(36).height(36).color($r('app.color.accent_action'))
            Text('正在加载商品卡片…').fontSize(13).fontColor($r('app.color.muted'))
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.cards.length === 0) {
          Column({ space: 12 }) {
            Image($r('app.media.food_other')).width(140).height(140).objectFit(ImageFit.Contain)
              .accessibilityLevel('no')
            Text(this.status.includes('失败') ? '暂时无法加载卡片' : '还没有发布商品卡片')
              .fontSize(19).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink'))
            Text(this.status.includes('失败') ? '请点击右上角刷新后重试。' : '完成第一张推荐卡后，它会出现在这里。')
              .fontSize(13).fontColor($r('app.color.muted')).textAlign(TextAlign.Center)
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          .padding(24).backgroundColor($r('app.color.surface')).borderRadius(20)
          .border({ width: 1, color: $r('app.color.line') })
        } else {
          List({ space: 12 }) {
            ForEach(this.cards, (card: FoodCard) => {
              ListItem() { this.cardRow(card) }
            }, (card: FoodCard) => card.id)
          }.width('100%').layoutWeight(1).edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%').height('100%').padding({ left: 20, right: 20, top: 12, bottom: 20 })
      .backgroundColor($r('app.color.canvas')).alignItems(HorizontalAlign.Start)
    }.title('我的卡片').onShown((): void => {
      if (this.hasBeenShown) {
        void this.refresh();
      } else {
        this.hasBeenShown = true;
      }
    })
  }
}

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
      this.status = '好友、私信、群聊与评论通知已开启。';
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
        .fontColor($r('app.color.ink')).width('100%')
      Text(description).fontSize(13).lineHeight(20)
        .fontColor($r('app.color.muted')).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 18 }) {
          Column({ space: 12 }) {
            Text('位置权限').fontSize(18).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink')).width('100%')
            Text(this.permissionStatus).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.leaf')).width('100%')
            Text('浏览推荐无需定位；仅在发布时按需请求一次精确位置，不会持续定位。')
              .fontSize(13).lineHeight(20).fontColor($r('app.color.muted')).width('100%')
            Button(this.loading ? '正在刷新…' : '刷新权限状态')
              .width('100%').height(48).enabled(!this.loading)
              .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.accent_action'))
              .onClick(() => this.refresh())
          }
          .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(20)
          .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start)

          Column({ space: 12 }) {
            Text('食刻通知').fontSize(18).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink')).width('100%')
            Text(this.notificationStatus).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.notificationEnabled ? $r('app.color.leaf') : $r('app.color.muted')).width('100%')
            Text('默认关闭。开启后提醒好友申请、申请通过、私信、群聊、评论与回复；系统通知不展示聊天或评论正文。')
              .fontSize(13).lineHeight(20).fontColor($r('app.color.muted')).width('100%')
            if (this.notificationSupported) {
              if (this.notificationEnabled) {
                if (!this.notificationRegistered) {
                  Button(this.loading ? '处理中…' : '重新登记通知设备')
                    .width('100%').height(48).enabled(!this.loading)
                    .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
                    .onClick(() => this.retryNotificationRegistration())
                }
                Button(this.loading ? '处理中…' : '关闭食刻通知')
                  .width('100%').height(48).enabled(!this.loading)
                  .backgroundColor($r('app.color.surface')).fontColor($r('app.color.ink'))
                  .border({ width: 1, color: $r('app.color.line') })
                  .onClick(() => this.disableNotifications())
              } else {
                Button(this.loading ? '处理中…' : '开启食刻通知')
                  .width('100%').height(48).enabled(!this.loading)
                  .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
                  .onClick(() => this.enableNotifications())
              }
            }
          }
          .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(20)
          .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start)

          Column({ space: 12 }) {
            Text('桌面卡片远程同步').fontSize(18).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink')).width('100%')
            Text(this.serviceCardSyncStatus).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.serviceCardSyncRegistered ? $r('app.color.leaf') :
                (this.serviceCardSyncEnabled ? $r('app.color.warning') : $r('app.color.muted')))
              .width('100%')
            Text('默认关闭。开启后仅把已审核公开推荐摘要同步到已添加的食刻卡片；不发送定位、实拍图、好友关系或私信。')
              .fontSize(13).lineHeight(20).fontColor($r('app.color.muted')).width('100%')
            if (this.serviceCardSyncSupported) {
              if (this.serviceCardSyncEnabled) {
                if (!this.serviceCardSyncRegistered) {
                  Button(this.loading ? '处理中…' : '检查并登记桌面卡片')
                    .width('100%').height(48).enabled(!this.loading)
                    .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
                    .onClick(() => this.retryServiceCardRegistration())
                }
                Button(this.loading ? '处理中…' : '关闭桌面卡片远程同步')
                  .width('100%').height(48).enabled(!this.loading)
                  .backgroundColor($r('app.color.surface')).fontColor($r('app.color.ink'))
                  .border({ width: 1, color: $r('app.color.line') })
                  .onClick(() => this.disableServiceCardSync())
              } else {
                Button(this.loading ? '处理中…' : '开启桌面卡片远程同步')
                  .width('100%').height(48).enabled(!this.loading)
                  .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
                  .onClick(() => this.enableServiceCardSync())
              }
            }
          }
          .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(20)
          .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start)

          Column({ space: 14 }) {
            Text('数据使用').fontSize(18).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink')).width('100%')
            this.dataRow('图片选择', '使用系统 Photo Picker，不申请图库全量读取权限。')
            Divider().strokeWidth(1).color($r('app.color.line'))
            this.dataRow('实拍图上传', '可选实拍图和资料头像均经本机重编码、移除 EXIF/GPS 后上传到 AGC 公开路径。')
            Divider().strokeWidth(1).color($r('app.color.line'))
            this.dataRow('好友与私信', '食刻号用于精确查找；好友关系、会话状态和主动发送的文字、HTTPS 链接、卡片标识保存在 AGC 云端。')
            Divider().strokeWidth(1).color($r('app.color.line'))
            this.dataRow('浏览记录', '最近浏览的卡片名称、分类和时间仅保存在本机，并按登录账号隔离；可随时在浏览记录页清空。')
            Divider().strokeWidth(1).color($r('app.color.line'))
            this.dataRow('通知、桌面卡片与鸿蒙多设备', '好友通知与桌面卡片远程同步分别由你主动开启；两类 Push Token 登记均在云端加密保存，卡片只处理公开摘要，跨设备只接续页面和不透明标识。')
          }
          .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(20)
          .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start)

          Column({ space: 12 }) {
            Text('隐私与数据删除').fontSize(18).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink')).width('100%')
            Text('你可删除本人发布的卡片；移除好友会关闭双方会话并清理全部对应私信。退出登录会使当前会话失效；本机浏览记录仍按账号保留，可手动清空，注销账号时清理。')
              .fontSize(13).lineHeight(20).fontColor($r('app.color.muted')).width('100%')
            Button(this.showPrivacy ? '收起完整说明' : '查看完整隐私说明')
              .width('100%').height(48).backgroundColor($r('app.color.surface'))
              .fontColor($r('app.color.ink')).border({ width: 1, color: $r('app.color.line') })
              .onClick(() => this.showPrivacy = !this.showPrivacy)
            if (this.showPrivacy) {
              Text('食刻使用 AGC Auth 管理邮箱验证码注册、登录和最近一次重新认证；邮箱原文不写入 UserProfile，食刻也不会收集或保存邮箱密码。华为账号仅作为兼容登录入口，完成邮箱绑定后，业务数据继续使用稳定的食刻账号标识。你可在资料页主动填写昵称并选择头像；头像与实拍图均先在本机重编码、移除 EXIF/GPS，再上传到 AGC 公开路径。发布位置只上传三位小数坐标和行政区，浏览位置不写入云端。好友功能会保存食刻号、好友申请、好友关系、会话未读数，以及你主动发送的文字、HTTPS 链接和卡片标识。好友通知和桌面卡片远程同步默认关闭，分别由你主动开启；相关 Push Token 均会加密保存。远程同步只更新已审核公开推荐摘要，不携带定位、实拍图、好友关系或私信。跨设备接续只传页签、卡片 ID 或好友 ID。移除好友时会话从双方页面移除，并同步清理全部对应私信。测试阶段的实拍图随卡片直接上架；正式上架前应根据平台要求补充内容审核和 HTTPS 隐私政策地址。')
                .fontSize(13).lineHeight(21).fontColor($r('app.color.muted')).width('100%')
                .padding(14).backgroundColor($r('app.color.canvas')).borderRadius(14)
            }
          }
          .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(20)
          .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start)

          if (this.status.length > 0) {
            Text(this.status).fontSize(13).lineHeight(20).fontColor($r('app.color.warning')).width('100%')
              .padding(12).backgroundColor($r('app.color.accent_soft')).borderRadius(14)
          }
        }
        .width('100%').padding({ left: 20, right: 20, top: 12, bottom: 28 })
        .alignItems(HorizontalAlign.Start)
      }.width('100%').height('100%').scrollBar(BarState.Off)
      .backgroundColor($r('app.color.canvas'))
    }.title('权限与隐私')
  }
}

@Component
export struct ProfileSettingsPage {
  @Consume('pathStack') pathStack: NavPathStack;
  onSessionEnded: (message: string) => void = (_message: string): void => {};
  @State profile: UserProfile | undefined = undefined;
  @State status: string = '';
  @State busy: boolean = false;
  @State deleteConfirmationVisible: boolean = false;
  @State deleteEmailAddress: string = '';
  @State deleteVerifyCode: string = '';
  @State deleteCodeBusy: boolean = false;
  @State deleteCodeCountdown: number = 0;
  @State emailBindingVisible: boolean = false;
  @State emailBindingAddress: string = '';
  @State emailBindingVerifyCode: string = '';
  @State emailBindingCodeBusy: boolean = false;
  @State emailBindingCodeCountdown: number = 0;
  private deleteCodeTimer: number | undefined = undefined;
  private emailBindingCodeTimer: number | undefined = undefined;

  aboutToAppear(): void {
    this.profile = AuthService.profile();
  }

  aboutToDisappear(): void {
    if (this.deleteCodeTimer !== undefined) {
      clearTimeout(this.deleteCodeTimer);
      this.deleteCodeTimer = undefined;
    }
    if (this.emailBindingCodeTimer !== undefined) {
      clearTimeout(this.emailBindingCodeTimer);
      this.emailBindingCodeTimer = undefined;
    }
  }

  private async logout(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await AuthService.logout(context);
      this.onSessionEnded('已退出食刻，认证会话和本机状态已清理。');
    } catch (error) {
      if (AuthService.profile() === undefined) {
        this.onSessionEnded(`本地食刻会话已清除，但云端退出未完成：${errorText(error as ErrorDetail)}`);
      } else {
        this.status = `退出未完成：${errorText(error as ErrorDetail)} 请保持登录并重试，以便先移除通知设备。`;
      }
    } finally {
      this.busy = false;
    }
  }

  private async switchUser(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await AuthService.logout(context);
      this.onSessionEnded('食刻会话已清除，可使用其他邮箱或华为账号重新登录。');
    } catch (_error) {
      if (AuthService.profile() === undefined) {
        this.onSessionEnded('食刻会话已清除，可使用其他邮箱或华为账号重新登录。');
      } else {
        this.status = '切换用户未完成：请保持当前账号登录并重试，以便先移除通知设备。';
      }
    } finally {
      this.busy = false;
    }
  }

  private showEmailBinding(): void {
    if (this.busy) return;
    this.emailBindingAddress = '';
    this.emailBindingVerifyCode = '';
    this.emailBindingCodeCountdown = 0;
    this.emailBindingVisible = true;
    this.status = '';
  }

  private startEmailBindingCodeCountdown(): void {
    if (this.emailBindingCodeTimer !== undefined) {
      clearTimeout(this.emailBindingCodeTimer);
    }
    this.emailBindingCodeTimer = setTimeout((): void => {
      if (this.emailBindingCodeCountdown <= 1) {
        this.emailBindingCodeCountdown = 0;
        this.emailBindingCodeTimer = undefined;
      } else {
        this.emailBindingCodeCountdown -= 1;
        this.startEmailBindingCodeCountdown();
      }
    }, 1000);
  }

  private async requestEmailBindingCode(): Promise<void> {
    if (this.busy || this.emailBindingCodeBusy || this.emailBindingCodeCountdown > 0) return;
    this.emailBindingCodeBusy = true;
    this.status = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await AuthService.requestEmailCode(context, this.emailBindingAddress);
      this.emailBindingCodeCountdown = 60;
      this.startEmailBindingCodeCountdown();
      this.status = '邮箱验证码已发送；验证后会关联到当前食刻账号。';
    } catch (error) {
      this.status = `验证码发送失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.emailBindingCodeBusy = false;
    }
  }

  private async completeEmailBinding(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.status = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.profile = await AuthService.linkEmailToHuawei(
        context, this.emailBindingAddress, this.emailBindingVerifyCode);
      this.emailBindingVisible = false;
      this.status = '邮箱已关联到当前食刻账号。退出后使用邮箱验证码登录，仍会进入同一账号。';
    } catch (error) {
      this.status = `邮箱关联未完成：${errorText(error as ErrorDetail)}`;
    } finally {
      this.busy = false;
    }
  }

  private async linkHuaweiAccount(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.status = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.profile = await AuthService.linkHuaweiToEmail(context);
      this.status = '华为账号已关联到当前食刻账号。之后可使用任一方式登录。';
    } catch (error) {
      this.status = `华为账号关联未完成：${errorText(error as ErrorDetail)}`;
    } finally {
      this.busy = false;
    }
  }

  private async deleteAccount(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const deletedUid: string = AuthService.profile()?.uid || '';
      const message: string = await AuthService.deleteAccount(
        context, this.deleteEmailAddress, this.deleteVerifyCode);
      if (deletedUid.length > 0) {
        try {
          CardVisitStore.clear(context, deletedUid);
        } catch (_error) {
          // Account deletion has already succeeded; local history cleanup is best effort.
        }
      }
      this.deleteConfirmationVisible = false;
      this.onSessionEnded(message);
    } catch (error) {
      this.status = `账号注销未完成：${errorText(error as ErrorDetail)}`;
    } finally {
      this.busy = false;
    }
  }

  private startDeleteCodeCountdown(): void {
    if (this.deleteCodeTimer !== undefined) {
      clearTimeout(this.deleteCodeTimer);
    }
    this.deleteCodeTimer = setTimeout((): void => {
      if (this.deleteCodeCountdown <= 1) {
        this.deleteCodeCountdown = 0;
        this.deleteCodeTimer = undefined;
      } else {
        this.deleteCodeCountdown -= 1;
        this.startDeleteCodeCountdown();
      }
    }, 1000);
  }

  private async requestDeleteCode(): Promise<void> {
    if (this.busy || this.deleteCodeBusy || this.deleteCodeCountdown > 0) return;
    this.deleteCodeBusy = true;
    this.status = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await AuthService.requestEmailCode(context, this.deleteEmailAddress);
      this.deleteCodeCountdown = 60;
      this.startDeleteCodeCountdown();
      this.status = '注销邮箱验证码已发送，请在有效期内完成最近一次认证。';
    } catch (error) {
      this.status = `验证码发送失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.deleteCodeBusy = false;
    }
  }

  build() {
    NavDestination() {
      Column() {
        List({ space: 18 }) {
          ListItem() {
            Row({ space: 14 }) {
              if (this.profile !== undefined && this.profile.avatarUrl.length > 0) {
                Image(this.profile.avatarUrl).width(54).height(54).borderRadius(27).objectFit(ImageFit.Cover)
                  .accessibilityText('当前用户头像')
              } else {
                Image($r('app.media.app_icon')).width(54).height(54).borderRadius(18)
                  .accessibilityText('食刻默认头像')
              }
              Column({ space: 4 }) {
                Text(this.profile?.nickname || '食刻用户').fontSize(17)
                  .fontWeight(FontWeight.Medium).fontColor($r('app.color.ink')).width('100%').maxLines(1)
                Text('当前食刻账号').fontSize(12).fontColor($r('app.color.muted')).width('100%')
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }
            .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(20)
            .border({ width: 1, color: $r('app.color.line') })
          }

          ListItem() {
            Row({ space: 12 }) {
              Image($r('app.media.ic_profile_privacy')).width(26).height(26)
                .accessibilityLevel('no')
              Text('权限与隐私').fontSize(16).fontColor($r('app.color.ink'))
                .layoutWeight(1)
              Image($r('app.media.ic_chevron_right')).width(22).height(22)
                .accessibilityLevel('no')
            }
            .width('100%').height(60).padding({ left: 16, right: 16 })
            .backgroundColor($r('app.color.surface')).borderRadius(18)
            .border({ width: 1, color: $r('app.color.line') })
            .accessibilityGroup(true).accessibilityText('权限与隐私')
            .onClick((): void => {
              this.pathStack.pushPathByName('profile-privacy', null);
            })
          }

          ListItem() {
            Column({ space: 12 }) {
              Text('登录与会话').fontSize(18).fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.ink')).width('100%')
              Text('切换用户会先使当前食刻会话失效并清除本机状态，之后可使用其他邮箱或华为账号登录。')
                .fontSize(13).lineHeight(20).fontColor($r('app.color.muted')).width('100%')
              Button(this.busy ? '处理中…' : '切换用户').enabled(!this.busy)
                .width('100%').height(48).backgroundColor($r('app.color.accent_soft'))
                .fontColor($r('app.color.accent_action')).onClick(() => this.switchUser())
              Button('退出登录').enabled(!this.busy).width('100%').height(48)
                .backgroundColor($r('app.color.surface')).fontColor($r('app.color.ink'))
                .border({ width: 1, color: $r('app.color.line') }).onClick(() => this.logout())
              if (!AuthService.isEmailSession()) {
                Text('关联邮箱登录').fontSize(16).fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.ink')).width('100%').margin({ top: 6 })
                Text('验证邮箱后会直接关联到当前 AGC 用户；不会新建另一份食刻账号。')
                  .fontSize(13).lineHeight(20).fontColor($r('app.color.muted')).width('100%')
                if (this.emailBindingVisible) {
                  Text('邮箱地址').fontSize(13).fontColor($r('app.color.muted')).width('100%')
                  TextInput({ text: this.emailBindingAddress, placeholder: 'name@example.com' })
                    .width('100%').height(48).backgroundColor($r('app.color.canvas'))
                    .accessibilityText('要关联的邮箱地址')
                    .onChange((value: string): void => {
                      this.emailBindingAddress = value;
                    })
                  Row({ space: 10 }) {
                    TextInput({ text: this.emailBindingVerifyCode, placeholder: '邮箱验证码' })
                      .layoutWeight(1).height(48).backgroundColor($r('app.color.canvas'))
                      .accessibilityText('关联邮箱验证码')
                      .onChange((value: string): void => {
                        this.emailBindingVerifyCode = value;
                      })
                    Button(this.emailBindingCodeCountdown > 0 ? `${this.emailBindingCodeCountdown} 秒后重发` :
                      (this.emailBindingCodeBusy ? '发送中…' : '获取验证码'))
                      .enabled(!this.busy && !this.emailBindingCodeBusy && this.emailBindingCodeCountdown === 0)
                      .height(46).fontSize(13).backgroundColor($r('app.color.surface'))
                      .fontColor($r('app.color.accent_action')).border({ width: 1, color: $r('app.color.line') })
                      .onClick(() => this.requestEmailBindingCode())
                  }.width('100%')
                  Button(this.busy ? '正在关联…' : '确认关联邮箱').enabled(!this.busy && !this.emailBindingCodeBusy)
                    .width('100%').height(48).backgroundColor($r('app.color.accent_action'))
                    .fontColor($r('app.color.on_accent_action')).onClick(() => this.completeEmailBinding())
                } else {
                  Button(this.busy ? '处理中…' : '关联邮箱').enabled(!this.busy)
                    .width('100%').height(48).backgroundColor($r('app.color.accent_soft'))
                    .fontColor($r('app.color.accent_action')).onClick((): void => this.showEmailBinding())
                }
              } else {
                Text('关联华为账号').fontSize(16).fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.ink')).width('100%').margin({ top: 6 })
                Text('授权后会直接关联到当前 AGC 用户；之后可用邮箱或华为账号登录同一食刻账号。')
                  .fontSize(13).lineHeight(20).fontColor($r('app.color.muted')).width('100%')
                Button(this.busy ? '正在关联…' : '关联华为账号').enabled(!this.busy)
                  .width('100%').height(48).backgroundColor($r('app.color.accent_soft'))
                  .fontColor($r('app.color.accent_action')).onClick(() => this.linkHuaweiAccount())
              }
            }
            .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(20)
            .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start)
          }

          ListItem() {
            Column({ space: 12 }) {
              Text('注销食刻账号').fontSize(18).fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.danger')).width('100%')
              Text('注销会删除个人资料、本人发布的卡片与实拍图、好友关系和私信数据，并取消当前应用授权。此操作不可恢复。')
                .fontSize(13).lineHeight(20).fontColor($r('app.color.muted')).width('100%')
              if (this.deleteConfirmationVisible) {
                Text('请再次确认：你将永久失去当前食刻账号及其相关数据。')
                  .fontSize(13).lineHeight(20).fontColor($r('app.color.danger')).width('100%')
                  .padding(12).backgroundColor($r('app.color.danger_soft')).borderRadius(14)
                if (AuthService.isEmailSession()) {
                  Text('邮箱会话需要在注销前完成最近 5 分钟内的邮箱验证码重新认证。')
                    .fontSize(12).lineHeight(18).fontColor($r('app.color.muted')).width('100%')
                  Text('当前认证邮箱').fontSize(13).fontColor($r('app.color.muted')).width('100%')
                  TextInput({ text: this.deleteEmailAddress, placeholder: 'name@example.com' })
                    .width('100%').height(48).backgroundColor($r('app.color.canvas'))
                    .accessibilityText('当前认证邮箱')
                    .onChange((value: string): void => {
                      this.deleteEmailAddress = value;
                    })
                  Row({ space: 10 }) {
                    TextInput({ text: this.deleteVerifyCode, placeholder: '邮箱验证码' })
                      .layoutWeight(1).height(48)
                      .accessibilityText('邮箱验证码')
                      .onChange((value: string): void => {
                        this.deleteVerifyCode = value;
                      })
                    Button(this.deleteCodeCountdown > 0 ? `${this.deleteCodeCountdown} 秒后重发` :
                      (this.deleteCodeBusy ? '发送中…' : '获取验证码'))
                      .enabled(!this.busy && !this.deleteCodeBusy && this.deleteCodeCountdown === 0)
                      .height(46).fontSize(13)
                      .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent_action'))
                      .border({ width: 1, color: $r('app.color.line') })
                      .onClick(() => this.requestDeleteCode())
                  }.width('100%')
                }
                Row({ space: 10 }) {
                  Button('取消').layoutWeight(1).height(48).enabled(!this.busy)
                    .backgroundColor($r('app.color.surface')).fontColor($r('app.color.ink'))
                    .border({ width: 1, color: $r('app.color.line') })
                    .onClick((): void => {
                      this.deleteConfirmationVisible = false;
                    })
                  Button(this.busy ? '正在注销…' : '确认永久注销').layoutWeight(1).height(48).enabled(!this.busy)
                    .backgroundColor($r('app.color.danger_action')).fontColor($r('app.color.on_danger_action'))
                    .onClick((): void => {
                      this.deleteAccount();
                    })
                }.width('100%')
              } else {
                Button('注销账号').enabled(!this.busy).width('100%').height(48)
                  .backgroundColor($r('app.color.danger_soft')).fontColor($r('app.color.danger'))
                  .border({ width: 1, color: $r('app.color.danger') })
                  .onClick((): void => {
                    this.status = '';
                    this.deleteConfirmationVisible = true;
                  })
              }
            }
            .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(20)
            .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start)
          }

          if (this.status.length > 0) {
            ListItem() {
              Text(this.status).fontSize(13).lineHeight(20).fontColor($r('app.color.warning')).width('100%')
                .padding(12).backgroundColor($r('app.color.accent_soft')).borderRadius(14)
            }
          }
        }
        .width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
        .padding({ left: 20, right: 20, top: 12, bottom: 28 })
      }.width('100%').height('100%').backgroundColor($r('app.color.canvas'))
    }.title('设置')
  }
}

@Component
export struct ProfileEditPage {
  onProfileChanged: (profile: UserProfile) => void = (_profile: UserProfile): void => {};
  @State profile: UserProfile | undefined = undefined;
  @State nickname: string = '';
  @State avatarPreviewUri: string = '';
  @State coverPreviewUri: string = '';
  @State preparingCover: boolean = false;
  @State clearCoverRequested: boolean = false;
  @State cropSourceUri: string = '';
  @State cropImageWidth: number = 0;
  @State cropImageHeight: number = 0;
  @State cropScale: number = 1;
  @State cropOffsetX: number = 0;
  @State cropOffsetY: number = 0;
  @State cropEditing: boolean = false;
  @State preparingAvatar: boolean = false;
  @State status: string = '';
  @State saving: boolean = false;
  private repository: CardRepository = new CardRepository();
  private preparedAvatar: PreparedPhoto | undefined = undefined;
  private avatarUpload: PrepareCardPhotoResponse | undefined = undefined;
  private avatarUploadCompleted: boolean = false;
  private preparedCover: PreparedPhoto | undefined = undefined;
  private coverUpload: PrepareCardPhotoResponse | undefined = undefined;
  private coverUploadCompleted: boolean = false;
  private activeCropTouchId: number = -1;
  private cropTouchStartX: number = 0;
  private cropTouchStartY: number = 0;
  private cropTouchStartOffsetX: number = 0;
  private cropTouchStartOffsetY: number = 0;
  private cropTouchStartDistance: number = 0;
  private cropTouchStartScale: number = 1;

  aboutToAppear(): void {
    this.profile = AuthService.profile();
    this.nickname = this.profile?.nickname || '';
    this.avatarPreviewUri = this.profile?.avatarUrl || '';
    this.coverPreviewUri = this.profile?.coverUrl || '';
    this.clearCoverRequested = false;
    void this.resolveCurrentCover();
    this.preparedAvatar = undefined;
    this.clearAvatarUpload();
    this.clearCrop();
    this.status = '';
  }

  private async resolveCurrentCover(): Promise<void> {
    const profile = this.profile;
    if (profile === undefined || profile.coverPath === undefined || profile.coverPath.length === 0 ||
      profile.coverBucket === undefined || profile.coverBucket.length === 0) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const coverUrl = await PhotoUploadService.getDownloadUrl(context, profile.coverBucket, profile.coverPath);
      if (this.preparedCover === undefined && !this.clearCoverRequested) this.coverPreviewUri = coverUrl;
    } catch (_error) {
      if (this.preparedCover === undefined && !this.clearCoverRequested) this.coverPreviewUri = '';
    }
  }

  private cropSpec(): AvatarCrop {
    return {
      scale: this.cropScale,
      offsetX: this.cropOffsetX,
      offsetY: this.cropOffsetY
    };
  }

  private bounded(value: number, minimum: number, maximum: number): number {
    return Math.max(minimum, Math.min(maximum, value));
  }

  private clearAvatarUpload(): void {
    this.avatarUpload = undefined;
    this.avatarUploadCompleted = false;
  }

  private clearCoverUpload(): void {
    this.coverUpload = undefined;
    this.coverUploadCompleted = false;
  }

  private async chooseCover(): Promise<void> {
    if (this.saving || this.preparingCover || this.preparingAvatar) return;
    try {
      const uri = await ImagePreparationService.selectOne();
      if (uri.length === 0) return;
      this.preparingCover = true;
      this.status = '正在本机处理主页背景…';
      const prepared: PreparedPhoto = await ImagePreparationService.prepareOwnedPhoto(uri);
      this.preparedCover = prepared;
      this.coverPreviewUri = uri;
      this.clearCoverRequested = false;
      this.clearCoverUpload();
      this.status = '背景图片已选定，保存后才会上传。';
    } catch (error) {
      this.preparedCover = undefined;
      this.clearCoverUpload();
      this.status = `背景处理失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.preparingCover = false;
    }
  }

  private async uploadPreparedCover(context: common.UIAbilityContext): Promise<string> {
    const cover: PreparedPhoto | undefined = this.preparedCover;
    if (cover === undefined) return '';
    if (this.coverUpload === undefined) {
      const photoRequest: PrepareCardPhotoRequest = {
        mimeType: cover.mimeType,
        byteSize: cover.byteSize,
        sha256: cover.sha256,
        width: cover.width,
        height: cover.height
      };
      this.status = '正在准备主页背景…';
      this.coverUpload = await this.retryCloudBusy('背景准备', (): Promise<PrepareCardPhotoResponse> =>
        this.repository.preparePhoto(context, photoRequest));
    }
    const upload: PrepareCardPhotoResponse | undefined = this.coverUpload;
    if (upload === undefined) throw new Error('背景上传准备记录缺失，请重新选择图片。');
    if (!this.coverUploadCompleted) {
      this.status = '正在上传主页背景…';
      await this.retryCloudBusy('背景上传', (): Promise<void> =>
        PhotoUploadService.upload(context, upload.bucketName, upload.cloudPath, cover.data, cover.sha256));
      this.coverUploadCompleted = true;
    }
    return upload.mediaId;
  }

  private clearCover(): void {
    if (this.saving || this.preparingCover) return;
    this.preparedCover = undefined;
    this.clearCoverUpload();
    this.clearCoverRequested = true;
    this.coverPreviewUri = '';
    this.status = '将恢复食刻默认背景，保存后生效。';
  }

  private isCloudBusyError(error: ErrorDetail): boolean {
    const message = errorText(error).toLowerCase();
    return message.includes('3007009') || message.includes('too many requests') || message.includes('too busy');
  }

  private waitForCloudRetry(delayMs: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout((): void => resolve(), delayMs);
    });
  }

  private async retryCloudBusy<T>(operationName: string, operation: () => Promise<T>): Promise<T> {
    for (let attempt = 1; attempt <= CLOUD_BUSY_MAX_ATTEMPTS; attempt++) {
      try {
        return await operation();
      } catch (error) {
        const detail = error as ErrorDetail;
        if (!this.isCloudBusyError(detail) || attempt === CLOUD_BUSY_MAX_ATTEMPTS) {
          throw new Error(errorText(detail));
        }
        const delayMs = CLOUD_BUSY_RETRY_BASE_DELAY_MS * attempt;
        this.status = `${operationName}服务繁忙，正在重试（${attempt}/${CLOUD_BUSY_MAX_ATTEMPTS - 1}）…`;
        await this.waitForCloudRetry(delayMs);
      }
    }
    throw new Error(`${operationName}未完成，请稍后重试。`);
  }

  private async uploadPreparedAvatar(context: common.UIAbilityContext): Promise<string> {
    const avatar: PreparedPhoto | undefined = this.preparedAvatar;
    if (avatar === undefined) return '';
    if (this.avatarUpload === undefined) {
      const photoRequest: PrepareCardPhotoRequest = {
        mimeType: avatar.mimeType,
        byteSize: avatar.byteSize,
        sha256: avatar.sha256,
        width: avatar.width,
        height: avatar.height
      };
      this.status = '正在准备新头像…';
      this.avatarUpload = await this.retryCloudBusy('头像准备', (): Promise<PrepareCardPhotoResponse> =>
        this.repository.preparePhoto(context, photoRequest));
    }
    const upload: PrepareCardPhotoResponse | undefined = this.avatarUpload;
    if (upload === undefined) throw new Error('头像上传准备记录缺失，请重新选择图片。');
    if (!this.avatarUploadCompleted) {
      this.status = '正在上传新头像…';
      await this.retryCloudBusy('头像上传', (): Promise<void> =>
        PhotoUploadService.upload(context, upload.bucketName, upload.cloudPath, avatar.data, avatar.sha256));
      this.avatarUploadCompleted = true;
    }
    return upload.mediaId;
  }

  private cropTouchDistance(first: TouchObject, second: TouchObject): number {
    const deltaX = second.x - first.x;
    const deltaY = second.y - first.y;
    return Math.sqrt(deltaX * deltaX + deltaY * deltaY);
  }

  private resetCropTouch(): void {
    this.activeCropTouchId = -1;
    this.cropTouchStartDistance = 0;
  }

  /**
   * Handles touch input on the crop frame itself. The frame stays fixed while
   * the source image moves underneath it, matching the common avatar-crop flow.
   */
  private handleCropTouch(viewport: number, event: TouchEvent): void {
    if (!this.cropEditing || this.saving || this.preparingAvatar) return;
    event.stopPropagation();

    if (event.type === TouchType.Down) {
      if (event.touches.length === 1) {
        const touch: TouchObject = event.touches[0];
        this.activeCropTouchId = touch.id;
        this.cropTouchStartX = touch.x;
        this.cropTouchStartY = touch.y;
        this.cropTouchStartOffsetX = this.cropOffsetX;
        this.cropTouchStartOffsetY = this.cropOffsetY;
        this.cropTouchStartDistance = 0;
      } else if (event.touches.length >= 2) {
        const first: TouchObject = event.touches[0];
        const second: TouchObject = event.touches[1];
        this.cropTouchStartDistance = this.cropTouchDistance(first, second);
        this.cropTouchStartScale = this.cropScale;
      }
      return;
    }

    if (event.type === TouchType.Move) {
      if (event.touches.length >= 2) {
        const first: TouchObject = event.touches[0];
        const second: TouchObject = event.touches[1];
        const distance = this.cropTouchDistance(first, second);
        if (distance > 0) {
          if (this.cropTouchStartDistance <= 0) {
            this.cropTouchStartDistance = distance;
            this.cropTouchStartScale = this.cropScale;
          }
          this.cropScale = this.bounded(
            this.cropTouchStartScale * distance / this.cropTouchStartDistance,
            1,
            3
          );
        }
        return;
      }

      if (event.touches.length === 1 && this.activeCropTouchId >= 0) {
        const touch: TouchObject = event.touches[0];
        if (touch.id !== this.activeCropTouchId) return;
        const panX = this.previewPanX(viewport);
        const panY = this.previewPanY(viewport);
        if (panX > 0) {
          this.cropOffsetX = this.bounded(
            this.cropTouchStartOffsetX - (touch.x - this.cropTouchStartX) / panX,
            -1,
            1
          );
        }
        if (panY > 0) {
          this.cropOffsetY = this.bounded(
            this.cropTouchStartOffsetY - (touch.y - this.cropTouchStartY) / panY,
            -1,
            1
          );
        }
      }
      return;
    }

    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.resetCropTouch();
    }
  }

  private resetCropPosition(): void {
    this.cropScale = 1;
    this.cropOffsetX = 0;
    this.cropOffsetY = 0;
    this.status = '已重置取景位置。';
  }

  private previewImageWidth(viewport: number): number {
    if (this.cropImageWidth <= 0 || this.cropImageHeight <= 0) return viewport;
    const baseWidth = this.cropImageWidth >= this.cropImageHeight
      ? viewport * this.cropImageWidth / this.cropImageHeight : viewport;
    return baseWidth * this.cropScale;
  }

  private previewImageHeight(viewport: number): number {
    if (this.cropImageWidth <= 0 || this.cropImageHeight <= 0) return viewport;
    const baseHeight = this.cropImageHeight >= this.cropImageWidth
      ? viewport * this.cropImageHeight / this.cropImageWidth : viewport;
    return baseHeight * this.cropScale;
  }

  private previewPanX(viewport: number): number {
    return Math.max(0, (this.previewImageWidth(viewport) - viewport) / 2);
  }

  private previewPanY(viewport: number): number {
    return Math.max(0, (this.previewImageHeight(viewport) - viewport) / 2);
  }

  private clearCrop(): void {
    this.resetCropTouch();
    this.cropSourceUri = '';
    this.cropImageWidth = 0;
    this.cropImageHeight = 0;
    this.cropScale = 1;
    this.cropOffsetX = 0;
    this.cropOffsetY = 0;
    this.cropEditing = false;
  }

  private async chooseAvatar(): Promise<void> {
    if (this.saving || this.preparingAvatar || this.preparingCover) return;
    try {
      const uri = await ImagePreparationService.selectOne();
      if (uri.length === 0) return;
      const dimensions: ImageDimensions = await ImagePreparationService.readImageDimensions(uri);
      this.preparedAvatar = undefined;
      this.clearAvatarUpload();
      this.cropSourceUri = uri;
      this.cropImageWidth = dimensions.width;
      this.cropImageHeight = dimensions.height;
      this.cropScale = 1;
      this.cropOffsetX = 0;
      this.cropOffsetY = 0;
      this.resetCropTouch();
      this.cropEditing = true;
      this.status = '请在取景框内调整头像；单指拖动图片、双指捏合缩放，确认后才会在本机生成头像。';
    } catch (error) {
      this.preparedAvatar = undefined;
      this.clearAvatarUpload();
      this.clearCrop();
      this.status = `头像处理失败：${errorText(error as ErrorDetail)}`;
    }
  }

  private async applyAvatarCrop(): Promise<void> {
    if (this.cropSourceUri.length === 0 || this.saving || this.preparingAvatar || this.preparingCover) return;
    this.preparingAvatar = true;
    try {
      this.clearAvatarUpload();
      this.status = '正在本机生成圆形头像…';
      const prepared: PreparedPhoto = await ImagePreparationService.prepareAvatarPhoto(
        this.cropSourceUri, this.cropSpec());
      this.preparedAvatar = prepared;
      this.avatarPreviewUri = this.cropSourceUri;
      this.cropEditing = false;
      this.status = '头像取景已选定，已本机重编码并移除 EXIF/GPS；保存后才会上传。';
    } catch (error) {
      this.preparedAvatar = undefined;
      this.status = `头像处理失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.preparingAvatar = false;
    }
  }

  private cancelAvatarCrop(): void {
    if (this.preparingAvatar) return;
    this.preparedAvatar = undefined;
    this.clearAvatarUpload();
    this.clearCrop();
    this.status = '已取消这次头像选择。';
  }

  private async save(): Promise<void> {
    if (this.cropEditing) {
      this.status = '请先确认或取消头像取景，再保存资料。';
      return;
    }
    if (this.saving || this.preparingAvatar || this.preparingCover) return;
    const normalizedNickname = this.nickname.trim();
    if (normalizedNickname.length === 0 || normalizedNickname.length > 24) {
      this.status = '昵称需为 1–24 个字符。';
      return;
    }
    this.saving = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let avatarMediaId = '';
      if (this.preparedAvatar !== undefined) {
        avatarMediaId = await this.uploadPreparedAvatar(context);
      }
      let coverMediaId = '';
      if (this.preparedCover !== undefined) {
        coverMediaId = await this.uploadPreparedCover(context);
      }
      this.status = '正在保存资料…';
      const request: UpdateProfileRequest = {
        nickname: normalizedNickname,
        avatarMediaId,
        coverMediaId,
        clearCover: this.clearCoverRequested
      };
      const updated = await this.retryCloudBusy('资料保存', (): Promise<UserProfile> =>
        AuthService.updateProfile(context, request));
      this.profile = updated;
      this.nickname = updated.nickname;
      this.avatarPreviewUri = updated.avatarUrl;
      this.coverPreviewUri = updated.coverUrl || '';
      this.preparedAvatar = undefined;
      this.preparedCover = undefined;
      this.clearCoverRequested = false;
      this.clearAvatarUpload();
      this.clearCoverUpload();
      this.clearCrop();
      this.status = '资料已保存。';
      this.onProfileChanged(updated);
    } catch (error) {
      const detail = error as ErrorDetail;
      this.status = this.isCloudBusyError(detail)
        ? '云端服务暂时繁忙，已保留本次头像选择，请稍后再次保存。'
        : `保存失败：${errorText(detail)}`;
    } finally {
      this.saving = false;
    }
  }

  @Builder
  private avatarCropPreview(viewport: number, description: string) {
    Stack({ alignContent: Alignment.Center }) {
      Image(this.cropSourceUri)
        .width(this.previewImageWidth(viewport)).height(this.previewImageHeight(viewport))
        .objectFit(ImageFit.Fill)
        .translate({
          x: -this.cropOffsetX * this.previewPanX(viewport),
          y: -this.cropOffsetY * this.previewPanY(viewport)
        })
        .accessibilityLevel('no')
      Column().width(viewport).height(viewport)
        .border({ width: 2, color: $r('app.color.on_accent_action') }).borderRadius(viewport / 2)
        .accessibilityLevel('no')
    }
    .width(viewport).height(viewport).clip(true).backgroundColor($r('app.color.canvas'))
    .borderRadius(viewport / 2)
    .onTouch((event: TouchEvent): void => this.handleCropTouch(viewport, event))
    .hitTestBehavior(this.cropEditing ? HitTestMode.Block : HitTestMode.Default)
    .accessibilityText(description);
  }

  @Builder
  private cropEditor() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 4 }) {
          Text('选定头像区域').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
            .width('100%')
          Text('在固定取景框内拖动或缩放图片，框内内容会成为最终头像。')
            .fontSize(12).fontColor($r('app.color.muted')).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text('第 2 步').fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.leaf'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 }).backgroundColor($r('app.color.accent_soft')).borderRadius(10)
      }.width('100%')

      Row() {
        this.avatarCropPreview(AVATAR_CROP_VIEWPORT, '头像圆形取景预览')
      }.width('100%').justifyContent(FlexAlign.Center)

      Text(`当前取景框：圆形；缩放 ${this.cropScale.toFixed(1)}×`)
        .fontSize(13).fontColor($r('app.color.muted')).width('100%').textAlign(TextAlign.Center)

      Button('重置取景位置').height(44).width('100%')
        .backgroundColor($r('app.color.canvas')).fontColor($r('app.color.accent_action'))
        .border({ width: 1, color: $r('app.color.line') })
        .onClick(() => this.resetCropPosition())

      Row({ space: 10 }) {
        Button('取消').height(44).layoutWeight(1).enabled(!this.preparingAvatar)
          .backgroundColor($r('app.color.surface')).fontColor($r('app.color.ink'))
          .border({ width: 1, color: $r('app.color.line') }).onClick(() => this.cancelAvatarCrop())
        Button(this.preparingAvatar ? '正在处理…' : '使用此头像').height(44).layoutWeight(1)
          .enabled(!this.preparingAvatar).backgroundColor($r('app.color.accent_action'))
          .fontColor($r('app.color.on_accent_action')).onClick(() => this.applyAvatarCrop())
      }.width('100%')
    }
    .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(20)
    .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start)
  }

  build() {
    NavDestination() {
      Column() {
        List({ space: 18 }) {
          ListItem() {
            if (this.cropEditing) {
              this.cropEditor()
            } else {
              Column({ space: 14 }) {
                Text('头像').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).width('100%')
                Row({ space: 16 }) {
                  if (this.preparedAvatar !== undefined && this.cropSourceUri.length > 0) {
                    this.avatarCropPreview(76, '待保存的用户头像')
                  } else if (this.avatarPreviewUri.length > 0) {
                    Image(this.avatarPreviewUri).width(76).height(76).borderRadius(38).objectFit(ImageFit.Cover)
                      .accessibilityText('当前用户头像')
                  } else {
                    Image($r('app.media.app_icon')).width(76).height(76).borderRadius(22)
                      .accessibilityText('食刻默认头像')
                  }
                  Column({ space: 6 }) {
                    Button('更换头像').height(44).fontSize(14)
                      .enabled(!this.saving && !this.preparingAvatar && !this.preparingCover)
                      .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.accent_action'))
                      .onClick(() => this.chooseAvatar())
                    Text('选择后可在取景框中拖动或缩放；保存前不会上传。')
                      .fontSize(12).lineHeight(18).fontColor($r('app.color.muted')).width('100%')
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                }.width('100%')
              }
              .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(20)
              .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start)
            }
          }

          ListItem() {
            Column({ space: 12 }) {
              Text('主页背景').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).width('100%')
              Stack({ alignContent: Alignment.Center }) {
                if (this.coverPreviewUri.length > 0) {
                  Image(this.coverPreviewUri).width('100%').height(132).objectFit(ImageFit.Cover)
                    .borderRadius(16).accessibilityText('主页背景预览');
                } else {
                  Column({ space: 6 }) {
                    Text('食刻好友主页').fontSize(20).fontWeight(FontWeight.Bold)
                      .fontColor($r('app.color.accent_action'));
                    Text('把喜欢的味道分享给朋友').fontSize(13).fontColor($r('app.color.leaf'));
                  }
                  .width('100%').height(132).justifyContent(FlexAlign.Center)
                  .backgroundColor($r('app.color.accent_soft')).borderRadius(16);
                }
              }.width('100%').height(132);
              Row({ space: 8 }) {
                Button(this.preparingCover ? '正在处理…' : '更换背景').height(44).layoutWeight(1)
                  .enabled(!this.saving && !this.preparingCover && !this.preparingAvatar)
                  .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.accent_action'))
                  .onClick((): void => {
                    this.chooseCover();
                  });
                Button('恢复默认').height(44).layoutWeight(1)
                  .enabled(!this.saving && !this.preparingCover &&
                    (this.coverPreviewUri.length > 0 || (this.profile?.coverPath || '').length > 0))
                  .backgroundColor($r('app.color.surface')).fontColor($r('app.color.ink'))
                  .border({ width: 1, color: $r('app.color.line') }).onClick((): void => {
                    this.clearCover();
                  });
              }.width('100%');
              Text('背景图片会显示在你的好友主页；选择后先在本机移除图片位置等元数据，保存时再上传。')
                .fontSize(12).lineHeight(18).fontColor($r('app.color.muted')).width('100%');
            }
            .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(20)
            .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start)
          }

          ListItem() {
            Column({ space: 10 }) {
              Text('昵称').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).width('100%')
              TextInput({ text: this.nickname, placeholder: '请输入昵称' })
                .width('100%').height(48).fontSize(16).backgroundColor($r('app.color.canvas'))
                .fontColor($r('app.color.ink')).placeholderColor($r('app.color.muted'))
                .border({ width: 1, color: $r('app.color.line') }).borderRadius(14)
                .padding({ left: 14, right: 14 })
                .onChange((value: string) => this.nickname = value)
              Text('昵称仅用于食刻内展示，长度为 1–24 个字符。')
                .fontSize(12).lineHeight(18).fontColor($r('app.color.muted')).width('100%')
            }
            .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(20)
            .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start)
          }

          ListItem() {
            Button(this.cropEditing ? '请先确认头像取景' : (this.saving ? '正在保存…' : '保存资料'))
              .enabled(!this.saving && !this.cropEditing && !this.preparingAvatar && !this.preparingCover)
              .width('100%').height(50)
              .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
              .onClick(() => this.save())
          }

          if (this.status.length > 0) {
            ListItem() {
              Text(this.status).fontSize(13).lineHeight(20).width('100%')
                .fontColor(this.status.includes('失败') ? $r('app.color.warning') : $r('app.color.muted'))
                .padding(12).backgroundColor($r('app.color.accent_soft')).borderRadius(14)
            }
          }
        }
        .width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
        .padding({ left: 20, right: 20, top: 12, bottom: 28 })
      }.width('100%').height('100%').backgroundColor($r('app.color.canvas'))
    }.title('编辑资料')
  }
}
