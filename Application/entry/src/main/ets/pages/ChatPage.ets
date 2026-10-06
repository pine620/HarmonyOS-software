import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import {
  ChatMessage, ListMessagesRequest, SendMessageRequest, SocialUser, emptySocialUser
} from '../model/FriendModels';
import { FriendRepository } from '../repository/FriendRepository';
import { CardRepository } from '../repository/CardRepository';
import { SocialAvatar } from '../components/social/SocialDisplay';
import { foodCardCategoryLabel, coverFor } from '../components/FoodCover';
import { ErrorDetail, errorText } from '../common/ErrorKit';

const MESSAGE_PAGE_SIZE = 50;
const AUTO_REFRESH_MS = 12000;

function messageTime(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '';
  const date = new Date(timestamp);
  const month = date.getMonth() + 1;
  const day = date.getDate();
  const minute = date.getMinutes();
  return `${month}月${day}日 ${date.getHours()}:${minute < 10 ? `0${minute}` : minute}`;
}

@Component
export struct ChatPage {
  @Consume('pathStack') pathStack: NavPathStack;
  @Prop friend: SocialUser = emptySocialUser();
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @StorageLink('socialForegroundRevision') @Watch('onSocialForegroundChanged') socialForegroundRevision: number = 0;
  @State messages: Array<ChatMessage> = [];
  @State nextBeforeToken: string = '';
  @State textDraft: string = '';
  @State cardCandidates: Array<FoodCard> = [];
  @State cardPickerVisible: boolean = false;
  @State loading: boolean = false;
  @State loadingOlder: boolean = false;
  @State cardsLoading: boolean = false;
  @State sending: boolean = false;
  @State status: string = '';
  private friendRepository: FriendRepository = new FriendRepository();
  private cardRepository: CardRepository = new CardRepository();
  private refreshTimer: number | undefined = undefined;

  aboutToAppear(): void {
    this.loadMessages(true);
    this.startAutoRefresh();
  }

  aboutToDisappear(): void {
    if (this.refreshTimer !== undefined) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = undefined;
    }
  }

  private onSocialForegroundChanged(): void {
    if (this.socialForegroundRevision > 0) this.loadMessages(true);
  }

  private startAutoRefresh(): void {
    if (this.refreshTimer !== undefined) clearInterval(this.refreshTimer);
    this.refreshTimer = setInterval((): void => {
      this.loadMessages(true);
    }, AUTO_REFRESH_MS);
  }

  private containsCard(cards: Array<FoodCard>, cardId: string): boolean {
    for (let index = 0; index < cards.length; index += 1) {
      if (cards[index].id === cardId) return true;
    }
    return false;
  }

  private async loadMessages(reset: boolean): Promise<void> {
    if (this.loading || this.loadingOlder) return;
    if (!reset && this.nextBeforeToken.length === 0) return;
    if (reset) this.loading = true;
    else this.loadingOlder = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const request: ListMessagesRequest = {
        friendUid: this.friend.uid,
        beforeToken: reset ? '' : this.nextBeforeToken,
        pageSize: MESSAGE_PAGE_SIZE
      };
      const response = await this.friendRepository.listMessages(context, request);
      this.messages = reset ? response.messages : response.messages.concat(this.messages);
      this.nextBeforeToken = response.nextBeforeToken;
      this.status = '';
    } catch (error) {
      this.status = `消息加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.loading = false;
      this.loadingOlder = false;
    }
  }

  private async loadCardCandidates(): Promise<void> {
    if (this.cardsLoading) return;
    this.cardsLoading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const collections = await Promise.all([
        this.cardRepository.myFavoriteCards(context), this.cardRepository.myCards(context)
      ]);
      const combined: Array<FoodCard> = [];
      collections[0].forEach((card: FoodCard): void => {
        if (card.status === 'APPROVED') combined.push(card);
      });
      collections[1].forEach((card: FoodCard): void => {
        if (card.status === 'APPROVED' && !this.containsCard(combined, card.id)) combined.push(card);
      });
      this.cardCandidates = combined;
      this.status = combined.length === 0 ? '暂无可发送的卡片。先收藏或发布一张公开卡片吧。' : '';
    } catch (error) {
      this.status = `卡片加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.cardsLoading = false;
    }
  }

  private async sendRequest(request: SendMessageRequest): Promise<void> {
    if (this.sending) return;
    this.sending = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const message = await this.friendRepository.sendMessage(context, request);
      this.messages = this.messages.concat([message]);
      this.textDraft = '';
      this.status = '已发送。';
    } catch (error) {
      this.status = `发送失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.sending = false;
    }
  }

  private sendText(): void {
    const value = this.textDraft.trim();
    if (value.length === 0) {
      this.status = '请输入消息内容。';
      return;
    }
    if (value.length > 1000) {
      this.status = '单条消息最多 1000 个字符。';
      return;
    }
    const request: SendMessageRequest = {
      friendUid: this.friend.uid, kind: 'TEXT', text: value, link: '', cardId: ''
    };
    this.sendRequest(request);
  }

  private sendCard(card: FoodCard): void {
    const request: SendMessageRequest = {
      friendUid: this.friend.uid, kind: 'CARD', text: '', link: '', cardId: card.id
    };
    this.sendRequest(request);
  }

  private priceText(card: FoodCard): string {
    if (card.priceFen <= 0) return '价格待补充';
    return `¥${(card.priceFen / 100).toFixed(2)}`;
  }

  private closeChat(): void {
    this.pathStack.pop();
  }

  @Builder
  private header(): void {
    Row({ space: 8 }) {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(24).fontColor([$r('app.color.ink')]);
      }
      .width(48).height(48).backgroundColor($r('app.color.surface')).borderRadius(16)
      .accessibilityText('返回好友与消息').onClick((): void => {
        this.closeChat();
      });
      SocialAvatar({ user: this.friend, avatarSize: 38 });
      Column({ space: 3 }) {
        Text(this.friend.nickname).fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.ink')).width('100%').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(this.friend.friendCode).fontSize(11).fontColor($r('app.color.muted')).width('100%').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Text('自动更新').fontSize(11).fontColor($r('app.color.muted'))
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .backgroundColor($r('app.color.accent_soft')).borderRadius(10);
    }
    .width('100%').height(64).padding({ left: 2, right: 2, top: 6, bottom: 6 });
  }

  @Builder
  private sharedCard(card: FoodCard): void {
    Row({ space: 10 }) {
      if (card.photoUrl.length > 0) {
        Image(card.photoUrl).width(72).height(72).objectFit(ImageFit.Cover).borderRadius(12)
          .accessibilityText(`${card.productName}的实拍图`);
      } else {
        Image(coverFor(card.category)).width(72).height(72).objectFit(ImageFit.Cover)
          .borderRadius(12).accessibilityLevel('no');
      }
      Column({ space: 4 }) {
        Text(card.productName || '食刻卡片').fontSize(14).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.ink')).width('100%').maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`${foodCardCategoryLabel(card)} · ${this.priceText(card)}`).fontSize(11)
          .fontColor($r('app.color.muted')).width('100%').maxLines(1);
        Button('查看卡片').height(36).fontSize(12).backgroundColor($r('app.color.accent_soft'))
          .fontColor($r('app.color.accent_action')).onClick((): void => {
            this.onOpenCard(card);
          });
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
    }
    .width(230).padding(10).backgroundColor($r('app.color.surface')).borderRadius(16)
    .border({ width: 1, color: $r('app.color.line') });
  }

  @Builder
  private messageContent(message: ChatMessage): void {
    if (message.kind === 'CARD') {
      if (message.sharedCard !== undefined) {
        this.sharedCard(message.sharedCard);
      } else {
        Column({ space: 6 }) {
          Text('卡片暂不可查看').fontSize(14).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
          Text('它可能已下架或删除。').fontSize(12).fontColor($r('app.color.muted'));
        }
        .width(220).padding(14).backgroundColor($r('app.color.surface')).borderRadius(18)
        .border({ width: 1, color: $r('app.color.line') });
      }
    } else if (message.kind === 'LINK') {
      Text(message.link).fontSize(15).lineHeight(22)
        .fontColor(message.mine ? $r('app.color.on_accent_action') : $r('app.color.ink'))
        .padding({ left: 14, right: 14, top: 11, bottom: 11 })
        .backgroundColor(message.mine ? $r('app.color.accent_action') : $r('app.color.surface'))
        .borderRadius(18).constraintSize({ maxWidth: 270 });
    } else {
      Text(message.text).fontSize(15).lineHeight(22)
        .fontColor(message.mine ? $r('app.color.on_accent_action') : $r('app.color.ink'))
        .padding({ left: 14, right: 14, top: 11, bottom: 11 })
        .backgroundColor(message.mine ? $r('app.color.accent_action') : $r('app.color.surface'))
        .borderRadius(18).constraintSize({ maxWidth: 270 });
    }
  }

  @Builder
  private messageRow(message: ChatMessage): void {
    Column({ space: 4 }) {
      Row() {
        if (message.mine) {
          Blank();
        } else {
          SocialAvatar({ user: this.friend, avatarSize: 34 });
          Blank().width(8);
        }
        this.messageContent(message);
        if (!message.mine) {
          Blank();
        }
      }.width('100%').alignItems(VerticalAlign.Bottom);
      Text(`${messageTime(message.createdAt)}${message.mine ? (message.readAt > 0 ? ' · 已读' : ' · 已送达') : ''}`)
        .fontSize(10).fontColor($r('app.color.muted')).width('100%')
        .textAlign(message.mine ? TextAlign.End : TextAlign.Start)
        .padding({ left: message.mine ? 0 : 42, right: message.mine ? 2 : 0 });
    }.width('100%');
  }

  @Builder
  private cardChoice(card: FoodCard): void {
    Row({ space: 8 }) {
      if (card.photoUrl.length > 0) {
        Image(card.photoUrl).width(58).height(58).objectFit(ImageFit.Cover).borderRadius(10)
          .accessibilityText(`${card.productName}的实拍图`);
      } else {
        Image(coverFor(card.category)).width(58).height(58).objectFit(ImageFit.Cover).borderRadius(10)
          .accessibilityLevel('no');
      }
      Column({ space: 4 }) {
        Text(card.productName || '食刻卡片').fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink')).width(120).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(this.priceText(card)).fontSize(12).fontColor($r('app.color.accent_action'));
      }.alignItems(HorizontalAlign.Start);
      Button(this.sending ? '发送中' : '发送').height(40).enabled(!this.sending).fontSize(12)
        .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
        .onClick((): void => {
          this.sendCard(card);
          this.cardPickerVisible = false;
        });
    }
    .padding(8).backgroundColor($r('app.color.surface')).borderRadius(14)
    .border({ width: 1, color: $r('app.color.line') });
  }

  @Builder
  private composer(): void {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.textDraft, placeholder: '输入文字或直接粘贴链接' })
          .layoutWeight(1).height(48).fontSize(15).backgroundColor($r('app.color.canvas'))
          .borderRadius(14).onChange((value: string): void => {
            this.textDraft = value;
          });
        Button('卡片').height(48).fontSize(12).backgroundColor($r('app.color.accent_soft'))
          .fontColor($r('app.color.accent_action')).enabled(!this.sending)
          .accessibilityText('选择食刻卡片发送').onClick((): void => {
            this.cardPickerVisible = !this.cardPickerVisible;
            if (this.cardPickerVisible && this.cardCandidates.length === 0) this.loadCardCandidates();
          });
        Button() {
          Image($r('app.media.ic_send')).width(24).height(24).objectFit(ImageFit.Contain)
            .accessibilityLevel('no');
        }
        .width(48).height(48).enabled(!this.sending).backgroundColor($r('app.color.accent_action'))
        .borderRadius(16).accessibilityText(this.sending ? '消息发送中' : '发送文字消息')
        .onClick((): void => {
          this.sendText();
        });
      }.width('100%').alignItems(VerticalAlign.Center);
      if (this.cardPickerVisible && this.cardsLoading) {
        Row({ space: 8 }) {
          LoadingProgress().width(22).height(22).color($r('app.color.accent_action'));
          Text('正在读取已收藏和已发布卡片').fontSize(13).fontColor($r('app.color.muted'));
        }.width('100%').height(56).justifyContent(FlexAlign.Center);
      } else if (this.cardPickerVisible && this.cardCandidates.length === 0) {
        Column({ space: 8 }) {
          Text('暂无可发送卡片，先收藏或发布一张公开卡片。').fontSize(12).fontColor($r('app.color.muted'));
          Button('重新加载').height(40).fontSize(12).backgroundColor($r('app.color.accent_soft'))
            .fontColor($r('app.color.accent_action')).onClick((): void => {
              this.loadCardCandidates();
            });
        }.width('100%').padding(8).alignItems(HorizontalAlign.Start);
      } else if (this.cardPickerVisible) {
        List({ space: 10 }) {
          ForEach(this.cardCandidates, (card: FoodCard): void => {
            ListItem() { this.cardChoice(card); }
          }, (card: FoodCard): string => card.id);
        }
        .width('100%').height(96).listDirection(Axis.Horizontal).scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring);
      }
    }
    .width('100%').padding(10).backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line') }).borderRadius(18);
  }

  build() {
    NavDestination() {
      Column({ space: 10 }) {
        this.header();
        if (this.status.length > 0) {
          Text(this.status).fontSize(12).lineHeight(18).fontColor($r('app.color.warning')).width('100%')
            .padding(9).backgroundColor($r('app.color.accent_soft')).borderRadius(12);
        }
        if (this.loading && this.messages.length === 0) {
          Column({ space: 10 }) {
            LoadingProgress().width(34).height(34).color($r('app.color.accent_action'));
            Text('正在加载私信').fontSize(13).fontColor($r('app.color.muted'));
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
        } else if (this.messages.length === 0) {
          Column({ space: 10 }) {
            Image($r('app.media.ic_message')).width(54).height(54).objectFit(ImageFit.Contain)
              .accessibilityLevel('no');
            Text('从一条真诚推荐开始').fontSize(18).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink'));
          Text('你可以发送文字，或分享一张公开食刻卡片。链接会作为普通文字发送。')
              .fontSize(13).lineHeight(20).fontColor($r('app.color.muted')).textAlign(TextAlign.Center)
              .width('82%');
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
        } else {
          List({ space: 12 }) {
            if (this.nextBeforeToken.length > 0) {
              ListItem() {
                Button(this.loadingOlder ? '加载中…' : '查看更早消息').width('100%').height(48)
                  .enabled(!this.loadingOlder).backgroundColor($r('app.color.accent_soft'))
                  .fontColor($r('app.color.accent_action')).onClick((): void => {
                    this.loadMessages(false);
                  });
              }
            }
            ForEach(this.messages, (message: ChatMessage): void => {
              ListItem() { this.messageRow(message); }
            }, (message: ChatMessage): string => message.id);
          }
          .width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
          .stackFromEnd(true).maintainVisibleContentPosition(true)
          .padding({ left: 2, right: 2, top: 4, bottom: 4 });
        }
        this.composer();
      }
      .width('100%').height('100%').padding({ left: 14, right: 14, top: 0, bottom: 10 })
      .backgroundColor($r('app.color.canvas'));
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => {
      this.closeChat();
      return true;
    });
  }
}
