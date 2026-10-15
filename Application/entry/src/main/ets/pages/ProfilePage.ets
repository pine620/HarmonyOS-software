import { PagePaletteRoute } from '../common/PagePaletteUi';
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
  @State profile: UserProfile | undefined = undefined;
  @StorageProp('appSystemTopPx') systemTopPx: number = 0;

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
    // Index paints the status-bar slice of the same cover so the background reaches the top edge.
    AppStorage.setOrCreate('profileCoverUrl', profile.coverUrl || '');
  }

  private hasCover(): boolean {
    return (this.profile?.coverUrl || '').length > 0;
  }

  private topInset(): number {
    return this.getUIContext().px2vp(this.systemTopPx);
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
            [$r('app.color.personal_canvas'), 1]
          ]
        }).accessibilityLevel('no');
      Column() {
        Row({ space: 4 }) {
          Blank();
          Button() {
            Text('编辑资料').fontSize(11)
              .fontColor((this.profile?.coverUrl || '').length > 0 ? Color.White : $r('app.color.personal_action'))
              .width(66).height(28).textAlign(TextAlign.Center)
              .border({ width: 1, color: (this.profile?.coverUrl || '').length > 0 ?
                Color.White : $r('app.color.personal_action') }).borderRadius(14);
          }
          .width(72).height(44).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('编辑个人资料').onClick((): void => {
            this.pathStack.pushPathByName('profile-edit', null);
          });
          Button() {
            Row() {
              Image(this.hasCover() ?
                $r('app.media.ic_profile_settings_light') : $r('app.media.ic_me_settings'))
                .width(16).height(16)
                .accessibilityLevel('no');
            }
            .width(28).height(28).justifyContent(FlexAlign.Center)
            .border({ width: 1, color: (this.profile?.coverUrl || '').length > 0 ?
              Color.White : $r('app.color.personal_action') }).borderRadius(14);
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
              .fontColor($r('app.color.personal_ink')).width('100%').maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
            Text(this.foodId()).fontSize(12).fontColor($r('app.color.personal_muted')).width('100%').maxLines(1)
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
        Stack() {
          Image(icon).width(24).height(24).objectFit(ImageFit.Contain).accessibilityLevel('no');
        }.width(44).height(44).borderRadius(14).backgroundColor($r('app.color.personal_soft'));
        Text(label).fontSize(12).fontColor($r('app.color.personal_ink')).maxLines(1);
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
        .fontColor($r('app.color.personal_ink')).width('100%');
      Row({ space: 4 }) {
        this.shortcut('我的卡片', $r('app.media.ic_me_cards'), 'profile-published');
        this.shortcut('我的收藏', $r('app.media.ic_me_favorite'), 'profile-favorites');
        this.shortcut('浏览记录', $r('app.media.ic_me_history'), 'profile-history');
      }.width('100%');
    }
    .width('100%').padding({ left: 12, right: 12, top: 14, bottom: 10 })
    .backgroundColor($r('app.color.personal_surface')).borderRadius(20)
    .border({ width: 1.2, color: $r('app.color.personal_line'), style: BorderStyle.Dashed });
  }

  private openPlanningPage(route: string): void {
    const paletteRoute: PagePaletteRoute = { palette: 'PERSONAL' };
    this.pathStack.pushPathByName(route,
      route === 'random-food' || route === 'food-choice-history' ? paletteRoute : null);
  }

  @Builder
  private planningRow(label: string, icon: Resource, route: string, divider: boolean) {
    Column({ space: 0 }) {
      Button() {
        Row({ space: 12 }) {
          Stack() {
            Image(icon).width(18).height(18).accessibilityLevel('no')
          }.width(30).height(30).borderRadius(10).backgroundColor($r('app.color.personal_soft'))
          Text(label).fontSize(15).fontColor($r('app.color.personal_ink')).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Image($r('app.media.ic_me_chevron')).width(18).height(18)
            .accessibilityLevel('no')
        }.width('100%').alignItems(VerticalAlign.Center)
      }
      .type(ButtonType.Normal).width('100%').constraintSize({ minHeight: 56 })
      .padding({ left: 14, right: 14, top: 12, bottom: 12 }).backgroundColor(Color.Transparent)
      .accessibilityText(label).onClick((): void => this.openPlanningPage(route))
      if (divider) {
        Row() {
          Blank().width(56)
          Column().height(1).layoutWeight(1)
            .border({ width: { top: 1 }, color: $r('app.color.personal_line'), style: BorderStyle.Dashed })
        }.width('100%').padding({ right: 14 })
      }
    }.width('100%')
  }

  @Builder
  private planningEntries() {
    Column({ space: 10 }) {
      Text('饮食与记录').fontSize(13).fontColor($r('app.color.personal_muted')).width('100%')
      Column({ space: 0 }) {
        Button() {
          Row({ space: 12 }) {
            Column({ space: 6 }) {
              Text('今日篇 / FOOD MOMENTS').fontSize(11).fontColor($r('app.color.personal_soft')).accessibilityLevel('no')
              Text('今日吃什么').fontSize(21).fontWeight(FontWeight.Bold).fontColor($r('app.color.personal_canvas'))
              Text('一次随机，三张灵感').fontSize(13).fontColor($r('app.color.personal_soft'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Text('翻开 ›').fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.personal_action'))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 }).borderRadius(16)
              .backgroundColor($r('app.color.personal_canvas'))
          }.width('100%')
        }.type(ButtonType.Normal).width('100%').constraintSize({ minHeight: 104 }).padding(20).borderRadius(16)
          .backgroundColor($r('app.color.personal_action')).accessibilityText('今日吃什么，翻三张选一个')
          .onClick((): void => this.openPlanningPage('random-food'))
        this.planningRow('选择记录', $r('app.media.ic_me_choice'), 'food-choice-history', false)
      }.width('100%').backgroundColor($r('app.color.personal_surface')).borderRadius(16)
        .border({ width: 1.2, color: $r('app.color.personal_line'), style: BorderStyle.Dashed })
      Text('内容管理').fontSize(13).fontColor($r('app.color.personal_muted')).width('100%').margin({ top: 8 })
      Column({ space: 0 }) {
        this.planningRow('我的举报', $r('app.media.ic_me_report'), 'my-reports', true)
        this.planningRow('删除记录', $r('app.media.ic_me_deleted'), 'deleted-cards', false)
      }.width('100%').backgroundColor($r('app.color.personal_surface')).borderRadius(16).border({ width: 1.2, color: $r('app.color.personal_line'), style: BorderStyle.Dashed })
      Text('本机与隐私').fontSize(13).fontColor($r('app.color.personal_muted')).width('100%').margin({ top: 8 })
      Column({ space: 0 }) {
        this.planningRow('本机草稿箱', $r('app.media.ic_me_draft'), 'drafts', true)
      }.width('100%').backgroundColor($r('app.color.personal_surface')).borderRadius(16)
        .border({ width: 1.2, color: $r('app.color.personal_line'), style: BorderStyle.Dashed })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.hasCover()) {
        // Same size as the status-bar slice drawn by Index (top inset + 360), shifted up by the inset,
        // so both halves of the cover line up into one continuous image.
        Image(this.profile?.coverUrl || '').width('100%').height(360 + this.topInset()).objectFit(ImageFit.Cover)
          .translate({ y: -this.topInset() })
          .accessibilityText('我的主页背景')
          .expandSafeArea([], []);
        Column() {}.width('100%').height(72)
          .linearGradient({ direction: GradientDirection.Bottom, colors: [
            ['#33000000', 0], ['#00000000', 1]
          ] }).hitTestBehavior(HitTestMode.None).accessibilityLevel('no');
      } else {
        Column().width('100%').height(360).backgroundColor($r('app.color.personal_header'))
          .expandSafeArea([], []);
        Column() {}.width('100%').height(64)
          .linearGradient({ direction: GradientDirection.Bottom, colors: [
            [$r('app.color.personal_header'), 0], [$r('app.color.personal_header_clear'), 1]
          ] }).hitTestBehavior(HitTestMode.None).accessibilityLevel('no');
      }
      List({ space: 0 }) {
        ListItem() { this.profileHero(); }
        ListItem() {
          Column({ space: 14 }) { this.shortcuts(); this.planningEntries(); }
            .width('100%').padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.personal_canvas'));
        }
      }
      .width('100%').height('100%').edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .scrollBar(BarState.Off).backgroundColor(Color.Transparent)
    }
    .width('100%').height('100%').backgroundColor($r('app.color.personal_canvas'))
      .background($r('app.color.personal_canvas')).expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
