/**
 * 【文件职责】好友私信页面：分页加载消息（list-messages）、发送文字 / 链接 / 卡片（send-message）、从收藏中选卡片发送。
 * 新消息获取：前台按 PollBackoff 退避轮询；收到 IM 推送时 EntryAbility 增加 socialForegroundRevision，本页监听后立即刷新。
 * 消息列表使用 DiffDataSource + LazyForEach，只渲染可见行并以最小变化通知刷新。
 */
import { PagePaletteName, pageColor } from '../common/PagePaletteUi';
import { NoteInputStyle, WarmNoteBackdrop } from '../common/WarmNoteUi';
import { AppDestinationStyle } from '../common/AppPageUi';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import {
  ChatMessage, ListMessagesRequest, SendMessageRequest, SocialUser, emptySocialUser
} from '../model/FriendModels';
import { FriendRepository } from '../repository/FriendRepository';
import { CardRepository } from '../repository/CardRepository';
import { SocialAvatar } from '../components/social/SocialDisplay';
import { coverFor } from '../components/FoodCover';
import { ErrorDetail, errorText } from '../common/ErrorKit';
import { PollBackoff } from '../service/PollBackoff';
import { StateView } from '../common/StateViewUi';
import {
  ShareableCards, chatBubbleRadius, chatClock, chatSeparator, chatSeparatorLabel, chatShowsSeparator, loadShareableCards
} from '../common/ChatUi';
import { legacyPriceText } from '../model/CardPrice';
import { DiffDataSource } from '../service/PagedDataSource';

const MESSAGE_PAGE_SIZE = 50;

// 私信页面。
@Component
export struct ChatPage {
  @Prop palette: PagePaletteName = 'SOCIAL';
  @State contentWidth: number = 320;
  // 消息气泡最大宽度（随页面宽度变化）。
  private messageWidth(): number { return Math.max(120, Math.min(286, this.contentWidth - 76)); }
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  private destinationVisible: boolean = true;
  // App 前后台切换时暂停 / 恢复。
  private onAppActiveChanged(): void { if (!this.appActive) this.aboutToDisappear(); else if (this.destinationVisible) this.aboutToAppear(); }

  @Consume('pathStack') pathStack: NavPathStack;
  @Prop friend: SocialUser = emptySocialUser();
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @StorageLink('socialForegroundRevision') @Watch('onSocialForegroundChanged') socialForegroundRevision: number = 0;
  // 消息通过 LazyForEach 渲染，数据源只接收最小的 ADD / CHANGE 通知，长对话也不卡顿。
  @State @Watch('syncMessageSource') messages: Array<ChatMessage> = [];
  private messageSource: DiffDataSource<ChatMessage> = new DiffDataSource<ChatMessage>(
    (message: ChatMessage): string => message.id,
    (message: ChatMessage, index: number, all: Array<ChatMessage>): string => message.id + ':' + (index > 0 ? all[index - 1].id : '') + ':' + message.readAt);
  private previousMessage: Map<string, ChatMessage> = new Map<string, ChatMessage>();
  // 把当前消息数组同步到 LazyForEach 数据源。
  private syncMessageSource(): void {
    const previous: Map<string, ChatMessage> = new Map<string, ChatMessage>();
    for (let index = 1; index < this.messages.length; index++) previous.set(this.messages[index].id, this.messages[index - 1]);
    this.previousMessage = previous;
    this.messageSource.update(this.messages);
  }
  // 上一条消息的时间（用于判断是否显示时间分隔条）。
  private previousCreatedAt(message: ChatMessage): number | undefined {
    const previous: ChatMessage | undefined = this.previousMessage.get(message.id);
    return previous === undefined ? undefined : previous.createdAt;
  }
  @State nextBeforeToken: string = '';
  @State textDraft: string = '';
  @State favoriteCursor: string = '';
  private pageGeneration: number = 0;
  @State cardCandidates: Array<FoodCard> = [];
  @State cardPickerVisible: boolean = false;
  @State loading: boolean = false;
  @State loadingOlder: boolean = false;
  @State cardsLoading: boolean = false;
  @State sending: boolean = false;
  @State status: string = '';
  private friendRepository: FriendRepository = new FriendRepository();
  private cardRepository: CardRepository = new CardRepository();
  private poller: PollBackoff = new PollBackoff((): Promise<boolean> => this.pollMessages());

  // 出现时加载消息并开始轮询。
  aboutToAppear(): void {
    this.pageGeneration++; this.messages = []; this.cardCandidates = []; this.loading = false; this.loadingOlder = false;
    this.loadMessages(true);
    this.poller.start();
  }

  // 消失时停止轮询并清空。
  aboutToDisappear(): void {
    this.pageGeneration++; this.messages = []; this.cardCandidates = []; this.cardPickerVisible = false; this.favoriteCursor = ''; this.loading = false; this.loadingOlder = false; this.cardsLoading = false; this.sending = false;
    this.poller.stop();
  }

  // 收到 IM 推送或回到前台时立即刷新。
  private onSocialForegroundChanged(): void {
    if (!this.destinationVisible || !this.appActive) return;
    if (this.socialForegroundRevision > 0) { this.loadMessages(true); this.poller.reset(); }
  }

  // 最新一条消息的 id。
  private newestMessageId(): string {
    return this.messages.length > 0 ? this.messages[this.messages.length - 1].id : '';
  }

  // 后台轮询一次；返回最新消息是否变化，以便轮询器决定是否放慢间隔。
  private async pollMessages(): Promise<boolean> {
    const before: string = this.newestMessageId();
    await this.loadMessages(true);
    return this.newestMessageId() !== before;
  }

  // 加载消息（reset=true 从最新一页重新开始，否则加载更早的一页）。
  private async loadMessages(reset: boolean): Promise<void> {
    if (this.loading || this.loadingOlder) return;
    if (!reset && this.nextBeforeToken.length === 0) return;
    const generation: number = this.pageGeneration; const owner: string = AccountRequestGuard.owner();
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
      if (generation !== this.pageGeneration || owner !== AccountRequestGuard.owner()) return;
      this.messages = reset ? response.messages : response.messages.concat(this.messages);
      this.nextBeforeToken = response.nextBeforeToken;
      this.status = '';
    } catch (error) {
      if (generation !== this.pageGeneration) return; this.messages = [];
      this.status = `消息加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      if (generation === this.pageGeneration) { this.loading = false; this.loadingOlder = false; }
    }
  }

  // 加载可分享的卡片候选（我的收藏）。
  private async loadCardCandidates(more: boolean = false): Promise<void> {
    if (this.cardsLoading) return; const generation: number = this.pageGeneration; this.cardsLoading = true;
    try { const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const loaded: ShareableCards | undefined = await loadShareableCards(context, this.cardRepository, this.cardCandidates,
        this.favoriteCursor, more, (): boolean => generation === this.pageGeneration);
      if (loaded === undefined) return;
      this.cardCandidates = loaded.cards; this.favoriteCursor = loaded.nextCursor;
      if (loaded.collectionPending) this.status = '收藏尚未整理，请先在我的收藏中继续；当前可分享自己发布的卡片。';
    } catch (error) { if (generation === this.pageGeneration) this.status = `卡片加载失败：${errorText(error as ErrorDetail)}`; }
    finally { if (generation === this.pageGeneration) this.cardsLoading = false; }
  }

  // 发送一条消息，成功后加入列表并重置轮询间隔。
  private async sendRequest(request: SendMessageRequest): Promise<void> {
    if (this.sending) return;
    const generation: number = this.pageGeneration; const owner: string = AccountRequestGuard.owner(); this.sending = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const message = await this.friendRepository.sendMessage(context, request);
      if (generation !== this.pageGeneration || owner !== AccountRequestGuard.owner()) return;
      this.messages = this.messages.concat([message]);
      this.textDraft = '';
      this.status = '已发送。';
      this.poller.reset();
    } catch (error) {
      if (generation !== this.pageGeneration || owner !== AccountRequestGuard.owner()) return;
      this.status = `发送失败：${errorText(error as ErrorDetail)}`;
    } finally {
      if (generation === this.pageGeneration) this.sending = false;
    }
  }

  // 发送文字消息（不能为空，最多 1000 字）。
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

  // 发送卡片。
  private sendCard(card: FoodCard): void {
    const request: SendMessageRequest = {
      friendUid: this.friend.uid, kind: 'CARD', text: '', link: '', cardId: card.id
    };
    this.sendRequest(request);
  }

  // 关闭私信页。
  private closeChat(): void {
    this.pathStack.pop();
  }

  // 顶部栏（对方头像、昵称）。
  @Builder
  private header(): void {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([pageColor(this.palette, 'ink')]);
      }
      .width(40).height(40).backgroundColor(Color.Transparent)
      .accessibilityText('返回好友与消息').onClick((): void => {
        this.closeChat();
      });
      SocialAvatar({ user: this.friend, avatarSize: 36 });
      Column({ space: 1 }) {
        Text(this.friend.nickname).fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(pageColor(this.palette, 'ink')).width('100%').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(this.friend.friendCode).fontSize(11).fontColor(pageColor(this.palette, 'muted')).width('100%').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.person')).fontSize(19).fontColor([pageColor(this.palette, 'action')]);
      }
      .width(40).height(40).backgroundColor(pageColor(this.palette, 'soft'))
      .accessibilityText('查看好友资料').onClick((): void => { this.pathStack.pushPathByName('friend-profile', this.friend); });
    }
    .width('100%').height(60).padding({ left: 4, right: 12, bottom: 8 })
    .border({ width: { bottom: 1.2 }, color: pageColor(this.palette, 'line'), style: BorderStyle.Dashed });
  }

  // 卡片消息气泡。
  @Builder
  private sharedCard(card: FoodCard, mine: boolean): void {
    Row({ space: 10 }) {
      Image(card.photoUrl.length > 0 ? card.photoUrl : coverFor(card.category)).width(56).height(56)
        .objectFit(ImageFit.Cover).borderRadius(10).accessibilityText(card.productName + '的实拍图');
      Column({ space: 3 }) {
        Text(card.productName || '食刻卡片').fontSize(14).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'))
          .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`${legacyPriceText(card)} · 查看卡片 ›`).fontSize(12).fontColor(pageColor(this.palette, 'action')).width('100%').maxLines(1);
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
    }
    .width(Math.min(this.messageWidth(), 250)).padding(8).backgroundColor(pageColor(this.palette, 'surface'))
    .borderRadius(chatBubbleRadius(mine)).border({ width: 1, color: pageColor(this.palette, 'line') })
    .accessibilityGroup(true).accessibilityText(`${card.productName || '食刻卡片'}，${legacyPriceText(card)}，查看卡片`)
    .onClick((): void => this.onOpenCard(card));
  }

  // 文字消息气泡。
  @Builder
  private textBubble(text: string, mine: boolean): void {
    Text(text).fontSize(15).lineHeight(22)
      .fontColor(mine ? pageColor(this.palette, 'canvas') : pageColor(this.palette, 'ink'))
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .backgroundColor(mine ? pageColor(this.palette, 'action') : pageColor(this.palette, 'surface'))
      .border({ width: mine ? 0 : 1, color: pageColor(this.palette, 'line') })
      .borderRadius(chatBubbleRadius(mine)).constraintSize({ maxWidth: this.messageWidth() })
      .copyOption(CopyOptions.LocalDevice);
  }

  // 按消息类型渲染内容。
  @Builder
  private messageContent(message: ChatMessage): void {
    if (message.kind === 'CARD') {
      if (message.sharedCard !== undefined) {
        this.sharedCard(message.sharedCard, message.mine);
      } else {
        Column({ space: 4 }) {
          Text('卡片暂不可查看').fontSize(14).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'));
          Text('它可能已下架或删除。').fontSize(12).fontColor(pageColor(this.palette, 'muted'));
        }
        .padding(12).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(chatBubbleRadius(message.mine))
        .border({ width: 1, color: pageColor(this.palette, 'line'), style: BorderStyle.Dashed }).alignItems(HorizontalAlign.Start);
      }
    } else if (message.kind === 'LINK') {
      this.textBubble(message.link, message.mine);
    } else {
      this.textBubble(message.text, message.mine);
    }
  }

  // 一行消息（含时间分隔条与左右对齐）。
  @Builder
  private messageRow(message: ChatMessage): void {
    Column({ space: 4 }) {
      if (chatShowsSeparator(this.previousCreatedAt(message), message.createdAt)) {
        chatSeparator(chatSeparatorLabel(message.createdAt), this.palette);
      }
      Row() {
        if (message.mine) {
          Blank();
        } else {
          SocialAvatar({ user: this.friend, avatarSize: 30 });
          Blank().width(8);
        }
        this.messageContent(message);
        if (!message.mine) {
          Blank();
        }
      }.width('100%').alignItems(VerticalAlign.Bottom);
      if (message.mine) {
        Text(`${chatClock(message.createdAt)}${message.readAt > 0 ? ' · 已读' : ' · 已送达'}`)
          .fontSize(10.5).fontColor(pageColor(this.palette, 'muted')).width('100%').textAlign(TextAlign.End)
          .padding({ right: 2 });
      }
    }.width('100%');
  }

  // 卡片候选中的一项。
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
          .fontColor(pageColor(this.palette, 'ink')).width(120).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(legacyPriceText(card)).fontSize(12).fontColor(pageColor(this.palette, 'action'));
      }.alignItems(HorizontalAlign.Start);
      Button(this.sending ? '发送中' : '发送').height(48).enabled(!this.sending).fontSize(12)
        .backgroundColor(pageColor(this.palette, 'gold')).fontColor(pageColor(this.palette, 'on_gold'))
        .onClick((): void => {
          this.sendCard(card);
          this.cardPickerVisible = false;
        });
    }
    .padding(8).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(14)
    .border({ width: 1, color: pageColor(this.palette, 'line') });
  }

  // 底部输入区域。
  @Builder
  private composer(): void {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.picture')).fontSize(19).fontColor([pageColor(this.palette, 'action')]);
        }
        .width(40).height(40).backgroundColor(this.cardPickerVisible ? pageColor(this.palette, 'soft') : Color.Transparent)
        .border({ width: 1.2, color: pageColor(this.palette, 'action'), style: BorderStyle.Dashed })
        .enabled(!this.sending).accessibilityText('选择食刻卡片发送').onClick((): void => {
          this.cardPickerVisible = !this.cardPickerVisible;
          if (this.cardPickerVisible && this.cardCandidates.length === 0) this.loadCardCandidates();
        });
        TextInput({ text: this.textDraft, placeholder: '说点什么，或粘贴链接' })
          .layoutWeight(1).height(40).fontSize(15).backgroundColor(pageColor(this.palette, 'canvas'))
          .borderRadius(20).attributeModifier(new NoteInputStyle(this.palette)).onChange((value: string): void => {
            this.textDraft = value;
          });
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.paperplane')).fontSize(18).fontColor([pageColor(this.palette, 'canvas')]);
        }
        .width(40).height(40).enabled(!this.sending).backgroundColor(pageColor(this.palette, 'action'))
        .opacity(this.sending ? 0.6 : 1).accessibilityText(this.sending ? '消息发送中' : '发送文字消息')
        .onClick((): void => {
          this.sendText();
        });
      }.width('100%').alignItems(VerticalAlign.Center);
      if (this.cardPickerVisible && this.cardsLoading) {
        Row({ space: 8 }) {
          LoadingProgress().width(22).height(22).color(pageColor(this.palette, 'action'));
          Text('正在读取已收藏和已发布卡片').fontSize(13).fontColor(pageColor(this.palette, 'muted'));
        }.width('100%').height(56).justifyContent(FlexAlign.Center);
      } else if (this.cardPickerVisible && this.cardCandidates.length === 0 && this.favoriteCursor.length === 0) {
        Column({ space: 8 }) {
          Text('暂无可发送卡片，先收藏或发布一张公开卡片。').fontSize(12).fontColor(pageColor(this.palette, 'muted'));
          Button('重新加载').height(40).fontSize(12).backgroundColor(pageColor(this.palette, 'soft'))
            .fontColor(pageColor(this.palette, 'action')).onClick((): void => {
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
      if (this.cardPickerVisible && this.favoriteCursor.length > 0) { Button('加载更多收藏').height(40).enabled(!this.cardsLoading).onClick((): void => { void this.loadCardCandidates(true); }); }
    }
    .width('100%').padding({ left: 10, right: 10, top: 10, bottom: 10 }).backgroundColor(pageColor(this.palette, 'surface'))
    .border({ width: { top: 1.2 }, color: pageColor(this.palette, 'line'), style: BorderStyle.Dashed });
  }

  // 页面布局。
  build() {
    NavDestination() {
      Stack() {
        WarmNoteBackdrop({ palette: this.palette });
      Column({ space: 10 }) {
        this.header();
        if (this.status.length > 0) {
          Column() {
            Text(this.status).fontSize(12).lineHeight(18).fontColor($r('app.color.warning')).width('100%')
              .padding(9).backgroundColor(pageColor(this.palette, 'soft')).borderRadius(12);
          }.width('100%').padding({ left: 12, right: 12 });
        }
        if (this.loading && this.messages.length === 0) {
          Column() {
            StateView({ kind: 'LOADING', palette: this.palette, title: '正在加载私信', skeletonRows: 0 });
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
        } else if (this.messages.length === 0) {
          Column() {
            StateView({ kind: 'EMPTY', palette: this.palette, icon: 'message', title: '从一条真诚推荐开始',
              hint: '可以发送文字，或分享一张公开的食刻卡片；链接会作为普通文字发送。' });
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
        } else {
          List({ space: 12 }) {
            if (this.nextBeforeToken.length > 0) {
              ListItem() {
                Button(this.loadingOlder ? '加载中…' : '查看更早消息').width('100%').height(36).fontSize(13)
                  .enabled(!this.loadingOlder).backgroundColor(Color.Transparent)
                  .fontColor(pageColor(this.palette, 'action')).onClick((): void => {
                    this.loadMessages(false);
                  });
              }
            }
            LazyForEach(this.messageSource, (message: ChatMessage): void => {
              ListItem() { this.messageRow(message); }
            }, (message: ChatMessage, index: number): string => this.messageSource.keyAt(index));
          }
          .width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
          .cachedCount(6).stackFromEnd(true).maintainVisibleContentPosition(true)
          .padding({ left: 12, right: 12, top: 4, bottom: 4 });
        }
        this.composer();
      }
      .width('100%').height('100%').padding({ left: 0, right: 0, top: 0, bottom: 0 })
      .onAreaChange((_oldArea: Area, newArea: Area): void => { const width: number = Number(newArea.width); if (Number.isFinite(width) && width > 0) this.contentWidth = width; })
      .backgroundColor(Color.Transparent);
      }.width('100%').height('100%');
    }
    .hideTitleBar(true).attributeModifier(new AppDestinationStyle('', pageColor(this.palette, 'canvas'), pageColor(this.palette, 'header'), this.palette)).onShown((): void => { this.destinationVisible = true; this.aboutToAppear(); }).onHidden((): void => { this.destinationVisible = false; this.aboutToDisappear(); })
    .onBackPressed((): boolean => {
      this.closeChat();
      return true;
    });
  }
}
