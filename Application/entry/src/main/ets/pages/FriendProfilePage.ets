import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { cardPriceText } from '../model/CardPrice';
import { FriendProfileResponse, SocialUser } from '../model/FriendModels';
import { SocialAvatar } from '../components/social/SocialDisplay';
import { coverFor } from '../components/FoodCover';
import { FriendRepository } from '../repository/FriendRepository';
import { ErrorDetail, errorText } from '../common/ErrorKit';

@Component
export struct FriendProfilePage {
  @Consume('pathStack') pathStack: NavPathStack;
  friendUid: string = '';
  onOpenChat: (friend: SocialUser) => void = (_friend: SocialUser): void => {};
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @State profile: FriendProfileResponse | undefined = undefined;
  @State cards: Array<FoodCard> = [];
  @State nextPageToken: string = '';
  @State loading: boolean = false;
  @State errorMessage: string = '';
  private repository: FriendRepository = new FriendRepository();

  aboutToAppear(): void {
    void this.loadPage(true);
  }

  private appendCards(existing: Array<FoodCard>, next: Array<FoodCard>): Array<FoodCard> {
    const output: Array<FoodCard> = existing.slice();
    for (const card of next) {
      if (!output.some((item: FoodCard): boolean => item.id === card.id)) output.push(card);
    }
    return output;
  }

  private async loadPage(reset: boolean): Promise<void> {
    if (this.loading || (!reset && this.nextPageToken.length === 0)) return;
    this.loading = true;
    this.errorMessage = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const response = await this.repository.friendProfile(context, this.friendUid,
        reset ? '' : this.nextPageToken, 12);
      this.profile = response;
      this.cards = reset ? response.cards : this.appendCards(this.cards, response.cards);
      this.nextPageToken = response.nextPageToken;
    } catch (error) {
      this.errorMessage = `好友主页加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.loading = false;
    }
  }

  private dateKey(timestamp: number): string {
    const safeTimestamp = Number.isFinite(timestamp) ? timestamp : 0;
    const date = new Date(safeTimestamp);
    if (!Number.isFinite(date.getTime())) return '1970-01-01';
    let yearText = date.getFullYear().toString();
    while (yearText.length < 4) yearText = `0${yearText}`;
    const month = date.getMonth() + 1;
    const day = date.getDate();
    const monthText = month < 10 ? `0${month}` : month.toString();
    const dayText = day < 10 ? `0${day}` : day.toString();
    return `${yearText}-${monthText}-${dayText}`;
  }

  private startsDateGroup(index: number): boolean {
    if (index === 0) return true;
    return this.dateKey(this.cards[index - 1].createdAt) !== this.dateKey(this.cards[index].createdAt);
  }

  private priceText(card: FoodCard): string {
    return cardPriceText(card, '');
  }

  @Builder
  private profileHero(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.profile !== undefined && (this.profile.profile.coverUrl || '').length > 0) {
        Image(this.profile.profile.coverUrl || '').width('100%').height(328).objectFit(ImageFit.Cover)
          .accessibilityText(`${this.profile.profile.user.nickname}的主页背景`)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP]);
      } else {
        Column().width('100%').height(328).backgroundColor($r('app.color.accent_soft'))
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP]);
      }
      Column().width('100%').height(328)
        .linearGradient({
          angle: 180,
          colors: [
            [$r('app.color.profile_hero_fade_clear'), 0],
            [$r('app.color.profile_hero_fade_mid'), 0.5],
            [$r('app.color.profile_hero_fade_near'), 0.82],
            [$r('app.color.canvas'), 1]
          ]
        }).accessibilityLevel('no');
      Column() {
        Row({ space: 8 }) {
          Button() {
            Row() {
              SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20)
                .fontColor([(this.profile?.profile.coverUrl || '').length > 0 ?
                  Color.White : $r('app.color.accent_action')]);
            }
            .width(30).height(30).justifyContent(FlexAlign.Center)
            .border({ width: 1, color: (this.profile?.profile.coverUrl || '').length > 0 ?
              Color.White : $r('app.color.accent_action') }).borderRadius(15);
          }
          .width(44).height(44).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('返回好友列表').onClick((): void => {
            this.pathStack.pop();
          });
          Blank();
          if (this.profile !== undefined) {
            Button() {
              Text('发消息').fontSize(12)
                .fontColor((this.profile?.profile.coverUrl || '').length > 0 ?
                  Color.White : $r('app.color.accent_action'))
                .width(68).height(30).textAlign(TextAlign.Center)
                .border({ width: 1, color: (this.profile?.profile.coverUrl || '').length > 0 ?
                  Color.White : $r('app.color.accent_action') }).borderRadius(15);
            }
            .width(76).height(44).padding(0).backgroundColor(Color.Transparent)
            .accessibilityText(`给 ${this.profile.profile.user.nickname} 发消息`)
            .onClick((): void => {
              if (this.profile !== undefined) this.onOpenChat(this.profile.profile.user);
            });
          }
        }.width('100%').height(44);
        Blank().layoutWeight(1);
        if (this.profile !== undefined) {
          Row({ space: 12 }) {
            SocialAvatar({ user: this.profile.profile.user, avatarSize: 72 });
            Column({ space: 4 }) {
              Text(this.profile.profile.user.nickname).fontSize(16).fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.ink')).width('100%').maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
              Text(this.profile.profile.user.friendCode).fontSize(12).fontColor($r('app.color.muted'))
                .maxLines(1).copyOption(CopyOptions.LocalDevice)
                .accessibilityDescription('长按复制食刻号');
            }.layoutWeight(1).padding({ top: 36 }).alignItems(HorizontalAlign.Start);
          }
          .width('100%').height(80).alignItems(VerticalAlign.Top);
        }
      }
      .width('100%').height(328).padding({ left: 14, right: 14, top: 30, bottom: 8 })
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%').height(328).backgroundColor($r('app.color.canvas')).clip(false);
  }

  @Builder
  private activityCard(card: FoodCard): void {
    Button() {
      Row({ space: 10 }) {
        if (card.photoUrl.length > 0) {
          Image(card.photoUrl).width(72).height(72).objectFit(ImageFit.Cover).borderRadius(12)
            .accessibilityText(`${card.productName}实拍图`);
        } else {
          Image(coverFor(card.category)).width(72).height(72).objectFit(ImageFit.Cover).borderRadius(12)
            .accessibilityText(`${card.productName}分类图片`);
        }
        Column({ space: 3 }) {
          Text(card.productName).fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
            .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
          Row({ space: 8 }) {
            if (this.priceText(card).length > 0) {
              Text(this.priceText(card)).fontSize(13).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.accent_action')).maxLines(1);
            }
            if (card.tasteScore > 0) {
              Text(`${card.tasteScore}/10`).fontSize(11).fontColor($r('app.color.leaf')).maxLines(1);
            }
          }.width('100%');
          if (card.reviewText.length > 0) {
            Text(card.reviewText).fontSize(11).lineHeight(15).fontColor($r('app.color.muted'))
              .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      }
      .width('100%').height(88).padding(8).alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.surface')).borderRadius(16);
    }
    .width('100%').height(88).padding(0).backgroundColor($r('app.color.surface'))
    .borderRadius(16).border({ width: 1, color: $r('app.color.line') })
    .accessibilityGroup(true).accessibilityText(`${card.productName}，打开食刻卡片详情`)
    .onClick((): void => {
      this.onOpenCard(card);
    });
  }

  build() {
    NavDestination() {
      List({ space: 8 }) {
        ListItem() { this.profileHero(); }
        if (this.errorMessage.length > 0 && this.profile === undefined) {
          ListItem() {
            Column({ space: 10 }) {
              Text(this.errorMessage).fontSize(13).lineHeight(20).fontColor($r('app.color.warning'))
                .width('100%');
              Button('重试').height(44).backgroundColor($r('app.color.accent_soft'))
                .fontColor($r('app.color.accent_action')).onClick((): void => {
                  void this.loadPage(true);
                });
            }.width('100%').padding(16).alignItems(HorizontalAlign.Start);
          }
        } else if (this.profile === undefined) {
          ListItem() {
            Row({ space: 8 }) {
              LoadingProgress().width(24).height(24).color($r('app.color.accent_action'));
              Text('正在打开好友主页').fontSize(13).fontColor($r('app.color.muted'));
            }.width('100%').height(56).padding({ left: 16, right: 16 });
          }
        } else {
          if (this.errorMessage.length > 0) {
            ListItem() {
              Column({ space: 8 }) {
                Text(this.errorMessage).fontSize(12).lineHeight(18).fontColor($r('app.color.warning'))
                  .width('100%');
                Button('重试加载动态').height(44).backgroundColor($r('app.color.accent_soft'))
                  .fontColor($r('app.color.accent_action')).onClick((): void => {
                    void this.loadPage(this.cards.length === 0);
                  });
              }.width('100%').padding(12).backgroundColor($r('app.color.surface')).borderRadius(14);
            }.padding({ left: 14, right: 14 });
          }
          ListItem() {
            Row() {
              Text('动态').fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
              Blank();
              Text(`${this.profile.profile.user.publishCount} 张`).fontSize(12).fontColor($r('app.color.muted'));
            }.width('100%').height(34).padding({ left: 16, right: 16 });
          }
          if (this.cards.length === 0 && !this.loading && this.errorMessage.length === 0) {
            ListItem() {
              Text('这位好友还没有公开动态。').fontSize(13).fontColor($r('app.color.muted'))
                .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(16);
            }.padding({ left: 14, right: 14 });
          }
          ForEach(this.cards, (card: FoodCard, index: number): void => {
            if (this.startsDateGroup(index)) {
              ListItem() {
                Text(this.dateKey(card.createdAt)).fontSize(13).fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.leaf')).width('100%').padding({ top: 4, bottom: 0, left: 16 });
              }
            }
            ListItem() { this.activityCard(card); }.padding({ left: 14, right: 14 });
          }, (card: FoodCard): string => card.id);
          if (this.loading && this.cards.length > 0) {
            ListItem() {
              Row({ space: 8 }) {
                LoadingProgress().width(20).height(20).color($r('app.color.accent_action'));
                Text('正在加载更多动态…').fontSize(12).fontColor($r('app.color.muted'));
              }.width('100%').height(44).justifyContent(FlexAlign.Center);
            }
          } else if (this.nextPageToken.length > 0) {
            ListItem() {
              Button('加载更多动态').width('100%').height(44)
                .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.accent_action'))
                .onClick((): void => {
                  void this.loadPage(false);
                });
            }.padding({ left: 14, right: 14 });
          }
        }
      }
      .width('100%').height('100%').backgroundColor($r('app.color.canvas'))
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP]);
    }
    .hideTitleBar(true);
  }
}
