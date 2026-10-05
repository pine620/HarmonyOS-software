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
        this.shortcut('收藏', $r('app.media.ic_profile_favorite'), 'profile-favorites');
        this.shortcut('浏览记录', $r('app.media.ic_profile_history'), 'profile-history');
      }.width('100%');
    }
    .width('100%').padding({ left: 12, right: 12, top: 14, bottom: 10 })
    .backgroundColor($r('app.color.surface')).borderRadius(20)
    .border({ width: 1, color: $r('app.color.line') });
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
          Column() { this.shortcuts(); }
            .width('100%').padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.canvas'));
        }
      }
      .width('100%').height('100%').edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .scrollBar(BarState.Off).backgroundColor(Color.Transparent)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    }
    .width('100%').height('100%').backgroundColor($r('app.color.canvas'))
  }
}
