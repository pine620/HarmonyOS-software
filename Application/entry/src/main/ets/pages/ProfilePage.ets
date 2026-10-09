import { OperationsRepository } from '../repository/OperationsRepository';
import { OperationsCapabilities } from '../model/OperationsModels';
import { AuthSessionStore } from '../service/AuthSessionStore';
import { UserProfile } from '../model/CloudContracts';
import { AuthService } from '../service/AuthService';

function maskedFoodId(uid: string): string {
  const normalized = uid.replace(/[^0-9A-Za-z]/g, '').toUpperCase();
  if (normalized.length === 0) return 'SK-••••';
  const suffix = normalized.length > 4 ? normalized.slice(-4) : normalized;
  return `SK-••••-${suffix}`;
}

@Component
export struct ProfilePage {
  @Consume('pathStack') pathStack: NavPathStack;
  @Prop @Watch('onRevisionChanged') revision: number = 0;
  @StorageLink('profileAvatarRevision') @Watch('onAvatarRevisionChanged') profileAvatarRevision: number = 0;
  @State administrator: boolean = false;
  @State operationsState: string = 'UNKNOWN';
  private operationsOwner: string = '';
  @StorageLink('operationsRoleRevision') @Watch('onOperationsRoleRejected') operationsRoleRevision: number = 0;
  private onOperationsRoleRejected(): void { this.operationsGeneration++; this.administrator = false; this.operationsState = 'NON_ADMIN'; }
  @StorageLink('stage47AppActive') @Watch('onOperationsEnvironment') appActive: boolean = true;
  @StorageLink('authSessionRevision') @Watch('onOperationsEnvironment') sessionRevision: number = 0;
  private operationsGeneration: number = 0;
  private operationsVisible: boolean = false;
  private onOperationsEnvironment(): void {
    this.operationsGeneration++;
    const owner: string = AuthService.profile()?.uid || '';
    if (owner !== this.operationsOwner) { this.operationsOwner = owner; this.administrator = false; this.operationsState = 'UNKNOWN'; }
    if (this.operationsVisible && this.appActive) void this.loadOperationsCapabilities();
  }
  private async loadOperationsCapabilities(): Promise<void> {
    const generation: number = ++this.operationsGeneration;
    const profile: UserProfile | undefined = AuthService.profile();
    const session: number = AuthSessionStore.generation();
    if (profile === undefined || !this.appActive) return;
    this.operationsState = 'CHECKING';
    try {
      const capabilities: OperationsCapabilities = await new OperationsRepository().capabilities({ priority: 'metadata', mayContinue: async (): Promise<boolean> => this.operationsVisible && this.appActive && generation === this.operationsGeneration && session === AuthSessionStore.generation() });
      if (this.operationsVisible && this.appActive && generation === this.operationsGeneration && session === AuthSessionStore.generation() && AuthService.profile()?.uid === profile.uid) {
        this.administrator = capabilities.administrator;
        this.operationsState = capabilities.administrator ? 'ADMIN' : 'NON_ADMIN';
      }
    } catch (_error) { if (generation === this.operationsGeneration && session === AuthSessionStore.generation()) this.operationsState = 'ERROR'; }
  }
  aboutToDisappear(): void { this.operationsVisible = false; this.onOperationsEnvironment(); }
  @State profile: UserProfile | undefined = undefined;

  aboutToAppear(): void {
    this.onAvatarRevisionChanged();
  }

  private onRevisionChanged(): void {
    this.onAvatarRevisionChanged();
  }

  private onAvatarRevisionChanged(): void {
    const profile: UserProfile | undefined = AuthService.profile();
    if (profile === undefined) return;
    this.profile = {
      uid: profile.uid, nickname: profile.nickname, avatarUrl: profile.avatarUrl,
      friendCode: profile.friendCode, avatarPath: profile.avatarPath, avatarBucket: profile.avatarBucket,
      coverPath: profile.coverPath, coverBucket: profile.coverBucket, coverUrl: profile.coverUrl,
      accountStatus: profile.accountStatus, publishCount: profile.publishCount,
      createdAt: profile.createdAt, updatedAt: profile.updatedAt
    };
  }

  private foodId(): string {
    const friendCode = this.profile?.friendCode;
    if (typeof friendCode === 'string' && friendCode.length > 0) return friendCode;
    return maskedFoodId(this.profile?.uid || '');
  }

  @Builder
  private profileHero() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column().width('100%').height(220)
        .linearGradient({
          angle: 180,
          colors: [
            [$r('app.color.profile_hero_fade_clear'), 0],
            [$r('app.color.profile_hero_fade_clear'), 0.45],
            [$r('app.color.profile_hero_fade_mid'), 0.65],
            [$r('app.color.canvas'), 1]
          ]
        }).accessibilityLevel('no');
      Column() {
        Row({ space: 4 }) {
          Blank();
          Button() {
            Text('编辑资料').fontSize(11)
              .fontColor((this.profile?.coverUrl || '').length > 0 ? Color.White : $r('app.color.accent_action'))
              .width(66).height(28).textAlign(TextAlign.Center)
              .border({ width: 1, color: (this.profile?.coverUrl || '').length > 0 ?
                Color.White : $r('app.color.accent_action') }).borderRadius(14);
          }
          .width(72).height(44).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('编辑个人资料').onClick((): void => {
            this.pathStack.pushPathByName('profile-edit', null);
          });
          Button() {
            Row() {
              Image((this.profile?.coverUrl || '').length > 0 ?
                $r('app.media.ic_profile_settings_light') : $r('app.media.ic_profile_settings'))
                .width(16).height(16)
                .accessibilityLevel('no');
            }
            .width(28).height(28).justifyContent(FlexAlign.Center)
            .border({ width: 1, color: (this.profile?.coverUrl || '').length > 0 ?
              Color.White : $r('app.color.accent_action') }).borderRadius(14);
          }
          .width(44).height(44).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('打开设置').onClick((): void => {
            this.pathStack.pushPathByName('profile-settings', null);
          });
        }.width('100%').height(44);
        Blank().layoutWeight(1);
        Row({ space: 12 }) {
          if (this.profile !== undefined && this.profile.avatarUrl.length > 0) {
            Image(this.profile.avatarUrl).width(68).height(68).borderRadius(34).objectFit(ImageFit.Cover)
              .accessibilityText('当前用户头像');
          } else {
            Image($r('app.media.app_icon')).width(68).height(68).borderRadius(34)
              .accessibilityText('食刻默认头像');
          }
          Column({ space: 4 }) {
            Text(this.profile?.nickname || '食刻用户').fontSize(18).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink')).width('100%').maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
            Text(this.foodId()).fontSize(12).fontColor($r('app.color.muted')).width('100%').maxLines(1)
              .copyOption(CopyOptions.LocalDevice).accessibilityDescription('长按可复制食刻号');
          }.layoutWeight(1).alignItems(HorizontalAlign.Start);
        }
        .width('100%').height(68).alignItems(VerticalAlign.Center);
      }
      .width('100%').height(220).padding({ left: 16, right: 12, top: 42, bottom: 12 })
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%').height(220).clip(false);
  }

  @Builder
  private shortcut(label: string, icon: Resource, route: string) {
    Button() {
      Column({ space: 8 }) {
        Image(icon).width(30).height(30).objectFit(ImageFit.Contain).accessibilityLevel('no');
        Text(label).fontSize(12).fontColor($r('app.color.ink')).maxLines(1);
      }.width('100%').justifyContent(FlexAlign.Center);
    }
    .layoutWeight(1).height(80).padding(0).backgroundColor(Color.Transparent)
    .accessibilityText(label).onClick((): void => {
      this.pathStack.pushPathByName(route, null);
    });
  }

  @Builder
  private shortcuts() {
    Column({ space: 10 }) {
      Text('常用功能').fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.ink')).width('100%');
      Row({ space: 4 }) {
        this.shortcut('我的卡片', $r('app.media.ic_profile_cards'), 'profile-published');
        this.shortcut('我的收藏', $r('app.media.ic_profile_favorite'), 'profile-favorites');
        this.shortcut('浏览记录', $r('app.media.ic_profile_history'), 'profile-history');
      }.width('100%');
    }
    .width('100%').padding({ left: 12, right: 12, top: 14, bottom: 10 })
    .backgroundColor($r('app.color.surface')).borderRadius(20)
    .border({ width: 1, color: $r('app.color.line') });
  }

  @Builder
  private planningRow(label: string, icon: Resource, route: string, divider: boolean) {
    Column({ space: 0 }) {
      Button() {
        Row({ space: 12 }) {
          Image(icon).width(22).height(22).fillColor($r('app.color.muted')).accessibilityLevel('no')
          Text(label).fontSize(15).fontColor($r('app.color.ink')).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('›').fontSize(23).fontColor($r('app.color.muted')).accessibilityLevel('no')
        }.width('100%').alignItems(VerticalAlign.Center)
      }
      .type(ButtonType.Normal).width('100%').constraintSize({ minHeight: 56 })
      .padding({ left: 14, right: 14, top: 12, bottom: 12 }).backgroundColor(Color.Transparent)
      .accessibilityText(label).onClick((): void => this.pathStack.pushPathByName(route, null))
      if (divider) {
        Row() {
          Blank().width(48)
          Divider().color($r('app.color.line')).layoutWeight(1)
        }.width('100%').padding({ right: 14 })
      }
    }.width('100%')
  }

  @Builder
  private planningEntries() {
    Column({ space: 10 }) {
      Text('饮食与记录').fontSize(13).fontColor($r('app.color.muted')).width('100%')
      Column({ space: 0 }) {
        this.planningRow('今天吃什么', $r('app.media.ic_planning_meal'), 'today-eat', true)
        this.planningRow('主动偏好', $r('app.media.ic_planning_preference'), 'taste-preference', true)
      }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(16)
        .border({ width: 1, color: $r('app.color.line') })
      Text('内容管理').fontSize(13).fontColor($r('app.color.muted')).width('100%').margin({ top: 8 })
      Column({ space: 0 }) {
        this.planningRow('待修改内容', $r('app.media.ic_profile_cards'), 'review-requests', true)
        this.planningRow('我的举报', $r('app.media.ic_profile_history'), 'my-reports', true)
        this.planningRow('删除记录', $r('app.media.ic_profile_history'), 'deleted-cards', this.administrator)
        if (this.administrator) { this.planningRow('审核中心', $r('app.media.ic_profile_settings'), 'moderation-center', false) }
        if (this.operationsState === 'ERROR' || this.operationsState === 'CHECKING' || this.operationsState === 'UNKNOWN') {
          Button(this.operationsState === 'ERROR' ? '审核身份检查失败 · 重试' : '正在确认审核身份…').fontSize(13).fontColor($r('app.color.muted')).backgroundColor(Color.Transparent).constraintSize({ minHeight: 48 }).width('100%')
            .enabled(this.operationsState !== 'CHECKING').onClick((): void => { void this.loadOperationsCapabilities(); })
        }
      }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(16).border({ width: 1, color: $r('app.color.line') })
      Text('本机与隐私').fontSize(13).fontColor($r('app.color.muted')).width('100%').margin({ top: 8 })
      Column({ space: 0 }) {
        this.planningRow('本机草稿箱', $r('app.media.ic_planning_draft'), 'drafts', true)
      }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(16)
        .border({ width: 1, color: $r('app.color.line') })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if ((this.profile?.coverUrl || '').length > 0) {
        Image(this.profile?.coverUrl || '').width('100%').height(360).objectFit(ImageFit.Cover)
          .accessibilityText('我的主页背景')
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP]);
      } else {
        Column().width('100%').height(360).backgroundColor($r('app.color.accent_soft'))
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP]);
      }
      List({ space: 0 }) {
        ListItem() { this.profileHero(); }
        ListItem() {
          Column({ space: 14 }) { this.shortcuts(); this.planningEntries(); }
            .width('100%').padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.canvas'));
        }
      }
      .width('100%').height('100%').edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .scrollBar(BarState.Off).backgroundColor(Color.Transparent)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    }
    .width('100%').height('100%').backgroundColor($r('app.color.canvas'))
      .onVisibleAreaChange([0, 1], (_visible: boolean, ratio: number): void => { const shown: boolean = ratio > 0; if (shown === this.operationsVisible) return; this.operationsVisible = shown; this.onOperationsEnvironment(); })
  }
}
