/**
 * 【文件职责】群聊页面：群资料与成员（get-group-chat）、消息分页与发送（list/send-group-message）、群主移除成员、退出群聊、
 * 发起和查看“一起选餐”投票（MealPollPage）。新消息获取方式与私信相同（退避轮询 + IM 推送即时刷新）。
 */
import { PagePaletteName, pageColor } from '../common/PagePaletteUi';
import { NoteInputStyle, WarmNoteBackdrop } from '../common/WarmNoteUi';
import { AppDestinationStyle } from '../common/AppPageUi';
import { SecondaryActionStyle } from '../common/Stage47Ui';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { MealPollPage } from './MealPollPage';
import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import {
  GroupChatDetailResponse, GroupConversationSummary, GroupMemberProfile, GroupMessage,
  ListGroupMessagesRequest, SendGroupMessageRequest, emptyGroupConversation
} from '../model/FriendModels';
import { FriendRepository } from '../repository/FriendRepository';
import { CardRepository } from '../repository/CardRepository';
import { AuthService } from '../service/AuthService';
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

const GROUP_MESSAGE_PAGE_SIZE = 50;

// 群聊页面。
@Component
export struct GroupChatPage {
  @Prop palette: PagePaletteName = 'SOCIAL';
  @State contentWidth: number = 320;
  // 消息气泡最大宽度。
  private messageWidth(): number { return Math.max(120, Math.min(286, this.contentWidth - 76)); }
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  private destinationVisible: boolean = true;
  // App 前后台切换时暂停 / 恢复。
  private onAppActiveChanged(): void { if (!this.appActive) this.aboutToDisappear(); else if (this.destinationVisible) this.aboutToAppear(); }

  @Prop group: GroupConversationSummary = emptyGroupConversation();
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  onGroupChanged: () => void = (): void => {};
  @StorageLink('socialForegroundRevision') @Watch('onSocialForegroundChanged') socialForegroundRevision: number = 0;
  @Consume('pathStack') pathStack: NavPathStack;
  @State showMealPoll: boolean = false;
  @State selectedPollId: string = '';
  @State detail: GroupChatDetailResponse | undefined = undefined;
  // 消息通过 LazyForEach 渲染，数据源只接收最小的 ADD / CHANGE 通知。
  @State @Watch('syncMessageSource') messages: Array<GroupMessage> = [];
  private messageSource: DiffDataSource<GroupMessage> = new DiffDataSource<GroupMessage>(
    (message: GroupMessage): string => message.id,
    (message: GroupMessage, index: number, all: Array<GroupMessage>): string => message.id + ':' + (index > 0 ? all[index - 1].id : ''));
  private previousMessage: Map<string, GroupMessage> = new Map<string, GroupMessage>();
  // 把当前消息数组同步到 LazyForEach 数据源。
  private syncMessageSource(): void {
    const previous: Map<string, GroupMessage> = new Map<string, GroupMessage>();
    for (let index = 1; index < this.messages.length; index++) previous.set(this.messages[index].id, this.messages[index - 1]);
    this.previousMessage = previous;
    this.messageSource.update(this.messages);
  }
  // 上一条消息的时间（用于时间分隔条）。
  private previousCreatedAt(message: GroupMessage): number | undefined {
    const previous: GroupMessage | undefined = this.previousMessage.get(message.id);
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
  @State detailLoading: boolean = false;
  @State cardsLoading: boolean = false;
  @State sending: boolean = false;
  @State membersVisible: boolean = false;
  @State memberActionUid: string = '';
  @State leaving: boolean = false;
  @State status: string = '';
  private friendRepository: FriendRepository = new FriendRepository();
  private cardRepository: CardRepository = new CardRepository();
  private poller: PollBackoff = new PollBackoff((): Promise<boolean> => this.pollMessages());

  // 出现时加载群资料与消息并开始轮询。
  aboutToAppear(): void {
    this.detail = undefined; this.detailLoading = false; this.pageGeneration++; this.messages = []; this.cardCandidates = []; this.loading = false; this.loadingOlder = false;
    this.loadDetail();
    this.loadMessages(true);
    this.poller.start();
  }

  // 消失时停止轮询并清空。
  aboutToDisappear(): void {
    this.detail = undefined; this.detailLoading = false; this.pageGeneration++; this.messages = []; this.cardCandidates = []; this.cardPickerVisible = false; this.favoriteCursor = ''; this.loading = false; this.loadingOlder = false; this.cardsLoading = false; this.sending = false;
    this.poller.stop();
  }

  // 收到 IM 推送或回到前台时立即刷新。
  private onSocialForegroundChanged(): void {
    if (!this.destinationVisible || !this.appActive) return;
    if (this.socialForegroundRevision > 0) {
      this.loadDetail();
      this.loadMessages(true);
      this.poller.reset();
    }
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

  // 当前用户是否为群主。
  private isOwner(): boolean {
    const profile = AuthService.profile();
    return profile !== undefined && this.detail !== undefined && this.detail.group.ownerUid === profile.uid;
  }

  // 群成员数。
  private memberCount(): number {
    return this.detail === undefined ? this.group.memberCount : this.detail.members.length;
  }


  // 读取群资料与成员。
  private async loadDetail(): Promise<void> {
    if (this.detailLoading) return;
    const generation: number = this.pageGeneration; const owner: string = AccountRequestGuard.owner(); this.detailLoading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const detail: GroupChatDetailResponse = await this.friendRepository.groupDetail(context, this.group.id);
      if (generation !== this.pageGeneration || owner !== AccountRequestGuard.owner()) return;
      this.detail = detail;
    } catch (error) {
      if (generation !== this.pageGeneration || owner !== AccountRequestGuard.owner()) return; this.detail = undefined;
      this.status = `群聊信息加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      if (generation === this.pageGeneration) this.detailLoading = false;
    }
  }

  // 加载消息（reset=true 从最新一页开始）。
  private async loadMessages(reset: boolean): Promise<void> {
    if (this.loading || this.loadingOlder) return;
    if (!reset && this.nextBeforeToken.length === 0) return;
    const generation: number = this.pageGeneration; const owner: string = AccountRequestGuard.owner();
    if (reset) this.loading = true;
    else this.loadingOlder = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const request: ListGroupMessagesRequest = {
        groupId: this.group.id,
        beforeToken: reset ? '' : this.nextBeforeToken,
        pageSize: GROUP_MESSAGE_PAGE_SIZE
      };
      const response = await this.friendRepository.listGroupMessages(context, request);
      if (generation !== this.pageGeneration || owner !== AccountRequestGuard.owner()) return;
      this.messages = reset ? response.messages : response.messages.concat(this.messages);
      this.nextBeforeToken = response.nextBeforeToken;
    } catch (error) {
      if (generation !== this.pageGeneration) return; this.messages = [];
      this.status = `群消息加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      if (generation === this.pageGeneration) { this.loading = false; this.loadingOlder = false; }
    }
  }

  // 加载可分享的卡片候选。
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

  // 发送一条群消息。
  private async sendRequest(request: SendGroupMessageRequest): Promise<void> {
    if (this.sending) return;
    const generation: number = this.pageGeneration; const owner: string = AccountRequestGuard.owner(); this.sending = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const message = await this.friendRepository.sendGroupMessage(context, request);
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

  // 发送文字。
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
    this.sendRequest({ groupId: this.group.id, kind: 'TEXT', text: value, cardId: '' });
  }

  // 发送卡片。
  private sendCard(card: FoodCard): void {
    this.sendRequest({ groupId: this.group.id, kind: 'CARD', text: '', cardId: card.id });
    this.cardPickerVisible = false;
  }

  // 群主移除成员。
  private async removeMember(member: GroupMemberProfile): Promise<void> {
    if (this.memberActionUid.length > 0 || member.role === 'OWNER') return;
    this.memberActionUid = member.user.uid;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.friendRepository.removeGroupMember(context, this.group.id, member.user.uid);
      this.status = `已移除 ${member.user.nickname}。`;
      await this.loadDetail();
      this.onGroupChanged();
    } catch (error) {
      this.status = `移除成员失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.memberActionUid = '';
    }
  }

  // 退出群聊。
  private async leaveGroup(): Promise<void> {
    if (this.leaving) return;
    this.leaving = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.friendRepository.leaveGroupChat(context, this.group.id);
      this.membersVisible = false;
      this.status = '你已退出群聊，返回好友页后该群将不再显示。';
      this.onGroupChanged();
    } catch (error) {
      this.status = `退出群聊失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.leaving = false;
    }
  }


  // 顶部栏（群名、成员数）。
  @Builder
  private header(): void {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([pageColor(this.palette, 'ink')]);
      }
      .width(40).height(40).backgroundColor(Color.Transparent)
      .accessibilityText('返回好友与消息').onClick((): void => { this.pathStack.pop(); });
      Column({ space: 1 }) {
        Text(this.group.name).fontSize(16).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'))
          .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`${this.memberCount()} 位成员`).fontSize(11).fontColor(pageColor(this.palette, 'muted')).width('100%');
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.person_2')).fontSize(19).fontColor([pageColor(this.palette, 'action')]);
      }
      .width(40).height(40).backgroundColor(pageColor(this.palette, 'soft'))
      .accessibilityText('群成员').onClick((): void => {
        this.membersVisible = true;
      });
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

  // 投票消息卡片（点击打开投票页）。
  @Builder
  private pollCard(message: GroupMessage): void {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.checkmark_square')).fontSize(15).fontColor([pageColor(this.palette, 'action')]);
        }.width(26).height(26).borderRadius(8).backgroundColor(pageColor(this.palette, 'soft'));
        Text('饭局投票').fontSize(14).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')).layoutWeight(1);
      }.width('100%');
      Text('点开查看选项、票数和截止时间').fontSize(12).fontColor(pageColor(this.palette, 'muted')).width('100%');
      Row() {
        Blank();
        Button({ type: ButtonType.Capsule, stateEffect: true }) {
          Text('去投票').fontSize(12).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'canvas'));
        }
        .height(30).padding({ left: 14, right: 14 }).backgroundColor(pageColor(this.palette, 'action'))
        .accessibilityText('打开饭局投票').onClick((): void => {
          this.selectedPollId = message.referenceId === undefined ? '' : message.referenceId; this.showMealPoll = true;
        });
      }.width('100%');
    }
    .width(Math.min(this.messageWidth(), 250)).padding(12).backgroundColor(pageColor(this.palette, 'surface'))
    .borderRadius(18).border({ width: 1.4, color: pageColor(this.palette, 'action'), style: BorderStyle.Dashed });
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
  private messageContent(message: GroupMessage): void {
    if (message.kind === 'MEAL_POLL') {
      this.pollCard(message);
    } else if (message.kind === 'CARD') {
      if (message.sharedCard !== undefined) this.sharedCard(message.sharedCard, message.mine);
      else {
        Text('卡片暂不可查看').fontSize(13).fontColor(pageColor(this.palette, 'muted')).padding(12)
          .backgroundColor(pageColor(this.palette, 'surface')).borderRadius(chatBubbleRadius(message.mine))
          .border({ width: 1, color: pageColor(this.palette, 'line'), style: BorderStyle.Dashed });
      }
    } else {
      this.textBubble(message.text, message.mine);
    }
  }

  // 一行消息。
  @Builder
  private messageRow(message: GroupMessage): void {
    Column({ space: 4 }) {
      if (chatShowsSeparator(this.previousCreatedAt(message), message.createdAt)) {
        chatSeparator(chatSeparatorLabel(message.createdAt), this.palette);
      }
      if (!message.mine) {
        Text(message.sender.nickname).fontSize(11).fontColor(pageColor(this.palette, 'muted')).width('100%').padding({ left: 38 });
      }
      Row() {
        if (message.mine) {
          Blank();
        } else {
          SocialAvatar({ user: message.sender, avatarSize: 30 });
          Blank().width(8);
        }
        this.messageContent(message);
        if (!message.mine) Blank();
      }.width('100%').alignItems(VerticalAlign.Bottom);
      if (message.mine) {
        Text(chatClock(message.createdAt)).fontSize(10.5).fontColor(pageColor(this.palette, 'muted')).width('100%')
          .textAlign(TextAlign.End).padding({ right: 2 });
      }
    }.width('100%');
  }

  // 卡片候选中的一项。
  @Builder
  private cardChoice(card: FoodCard): void {
    Row({ space: 8 }) {
      if (card.photoUrl.length > 0) {
        Image(card.photoUrl).width(56).height(56).objectFit(ImageFit.Cover).borderRadius(10)
          .accessibilityText(`${card.productName}的实拍图`);
      } else {
        Image(coverFor(card.category)).width(56).height(56).objectFit(ImageFit.Cover).borderRadius(10)
          .accessibilityLevel('no');
      }
      Column({ space: 4 }) {
        Text(card.productName || '食刻卡片').fontSize(13).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'ink'))
          .width(118).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(legacyPriceText(card)).fontSize(12).fontColor(pageColor(this.palette, 'action'));
      }.alignItems(HorizontalAlign.Start);
      Button(this.sending ? '发送中' : '发送').height(48).fontSize(12).enabled(!this.sending)
        .backgroundColor(pageColor(this.palette, 'gold')).fontColor(pageColor(this.palette, 'on_gold'))
        .onClick((): void => {
          this.sendCard(card);
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
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.checkmark_square')).fontSize(19).fontColor([pageColor(this.palette, 'action')]);
        }
        .width(40).height(40).backgroundColor(Color.Transparent)
        .border({ width: 1.2, color: pageColor(this.palette, 'action'), style: BorderStyle.Dashed })
        .accessibilityText('发起群选餐投票').onClick((): void => { this.selectedPollId = ''; this.showMealPoll = true; });
        TextInput({ text: this.textDraft, placeholder: '说点什么' }).layoutWeight(1).height(40).fontSize(15)
          .backgroundColor(pageColor(this.palette, 'canvas')).borderRadius(20).attributeModifier(new NoteInputStyle(this.palette)).onChange((value: string): void => {
            this.textDraft = value;
          });
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.paperplane')).fontSize(18).fontColor([pageColor(this.palette, 'canvas')]);
        }
        .width(40).height(40).enabled(!this.sending).backgroundColor(pageColor(this.palette, 'action'))
        .opacity(this.sending ? 0.6 : 1).accessibilityText(this.sending ? '消息发送中' : '发送群消息')
        .onClick((): void => {
          this.sendText();
        });
      }.width('100%').alignItems(VerticalAlign.Center);
      if (this.cardPickerVisible && this.cardsLoading) {
        Row({ space: 8 }) {
          LoadingProgress().width(22).height(22).color(pageColor(this.palette, 'action'));
          Text('正在读取可分享卡片').fontSize(13).fontColor(pageColor(this.palette, 'muted'));
        }.width('100%').height(56).justifyContent(FlexAlign.Center);
      } else if (this.cardPickerVisible && this.cardCandidates.length === 0 && this.favoriteCursor.length === 0) {
        Text('暂无可发送卡片，先收藏或发布一张公开卡片。').fontSize(12).fontColor(pageColor(this.palette, 'muted'))
          .width('100%').padding(8);
      } else if (this.cardPickerVisible) {
        List({ space: 10 }) {
          ForEach(this.cardCandidates, (card: FoodCard): void => {
            ListItem() { this.cardChoice(card); }
          }, (card: FoodCard): string => card.id);
        }.width('100%').height(96).listDirection(Axis.Horizontal).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring);
      }
      if (this.cardPickerVisible && this.favoriteCursor.length > 0) { Button('加载更多收藏').height(40).enabled(!this.cardsLoading).onClick((): void => { void this.loadCardCandidates(true); }).attributeModifier(new SecondaryActionStyle(this.palette)); }
    }
    .width('100%').padding({ left: 10, right: 10, top: 10, bottom: 10 }).backgroundColor(pageColor(this.palette, 'surface'))
    .border({ width: { top: 1.2 }, color: pageColor(this.palette, 'line'), style: BorderStyle.Dashed });
  }

  // 成员列表面板。
  @Builder
  private membersSheet(): void {
    Column({ space: 12 }) {
      Text('群成员').fontSize(20).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')).width('100%');
      if (this.detail === undefined || this.detailLoading) {
        Row({ space: 8 }) {
          LoadingProgress().width(22).height(22).color(pageColor(this.palette, 'action'));
          Text('正在读取成员').fontSize(13).fontColor(pageColor(this.palette, 'muted'));
        }.width('100%').height(120).justifyContent(FlexAlign.Center);
      } else {
        List({ space: 8 }) {
          ForEach(this.detail.members, (member: GroupMemberProfile): void => {
            ListItem() {
              Row({ space: 10 }) {
                SocialAvatar({ user: member.user, avatarSize: 40 });
                Column({ space: 2 }) {
                  Text(member.user.nickname).fontSize(15).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'ink'));
                  Text(member.role === 'OWNER' ? '群主' : member.user.friendCode).fontSize(12)
                    .fontColor(pageColor(this.palette, 'muted')).width('100%').maxLines(1);
                }.layoutWeight(1).alignItems(HorizontalAlign.Start);
                if (this.isOwner() && member.role !== 'OWNER') {
                  Button(this.memberActionUid === member.user.uid ? '处理中' : '移除').height(48).fontSize(12)
                    .enabled(this.memberActionUid.length === 0).backgroundColor(pageColor(this.palette, 'surface'))
                    .fontColor($r('app.color.danger')).border({ width: 1, color: pageColor(this.palette, 'line') })
                    .onClick((): void => {
                      this.removeMember(member);
                    });
                }
              }.width('100%').padding({ top: 4, bottom: 4 }).alignItems(VerticalAlign.Center);
            }
          }, (member: GroupMemberProfile): string => member.user.uid);
        }.width('100%').height(230).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring);
        if (!this.isOwner()) {
          Button(this.leaving ? '正在退出…' : '退出群聊').width('100%').height(48).enabled(!this.leaving)
            .backgroundColor($r('app.color.danger_action')).fontColor($r('app.color.on_danger_action'))
            .onClick((): void => {
              this.leaveGroup();
            });
        }
      }
      Button('关闭').width('100%').height(48).enabled(!this.leaving)
        .backgroundColor(pageColor(this.palette, 'surface')).fontColor(pageColor(this.palette, 'ink'))
        .border({ width: 1, color: pageColor(this.palette, 'line') }).onClick((): void => {
          this.membersVisible = false;
        });
    }
    .width('100%').padding({ left: 20, right: 20, top: 18, bottom: 20 }).backgroundColor(pageColor(this.palette, 'surface'))
    .borderRadius(24).border({ width: 1, color: pageColor(this.palette, 'line') }).alignItems(HorizontalAlign.Start);
  }

  // 页面布局。
  build() {
    NavDestination() {
      if (this.showMealPoll) { MealPollPage({ groupId: this.group.id, pollId: this.selectedPollId, memberCount: this.memberCount(), onDone: (): void => { this.showMealPoll = false; void this.loadMessages(true); }, onOpenCard: (card: FoodCard): void => this.onOpenCard(card) }) } else {
      Stack({ alignContent: Alignment.Bottom }) {
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
              StateView({ kind: 'LOADING', palette: this.palette, title: '正在加载群消息', skeletonRows: 0 });
            }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
          } else if (this.messages.length === 0) {
            Column() {
              StateView({ kind: 'EMPTY', palette: this.palette, icon: 'message', title: '从一条群消息开始',
                hint: '可以发送文字、分享公开食刻卡片，或发起一次饭局投票。' });
            }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
          } else {
            List({ space: 12 }) {
              if (this.nextBeforeToken.length > 0) {
                ListItem() {
                  Button(this.loadingOlder ? '加载中…' : '查看更早消息').width('100%').height(36).fontSize(13).enabled(!this.loadingOlder)
                    .backgroundColor(Color.Transparent).fontColor(pageColor(this.palette, 'action'))
                    .onClick((): void => {
                      this.loadMessages(false);
                    });
                }
              }
              LazyForEach(this.messageSource, (message: GroupMessage): void => {
                ListItem() { this.messageRow(message); }
              }, (message: GroupMessage, index: number): string => this.messageSource.keyAt(index));
            }
            .width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
            .cachedCount(6).stackFromEnd(true).maintainVisibleContentPosition(true).padding({ left: 12, right: 12, top: 4, bottom: 4 });
          }
          this.composer();
        }
        .width('100%').height('100%').padding(0)
        .onAreaChange((_oldArea: Area, newArea: Area): void => { const width: number = Number(newArea.width); if (Number.isFinite(width) && width > 0) this.contentWidth = width; })
        .backgroundColor(Color.Transparent);
        if (this.membersVisible) {
          Column() {}.width('100%').height('100%').backgroundColor($r('app.color.scrim'))
            .onClick((): void => {
              if (!this.leaving && this.memberActionUid.length === 0) this.membersVisible = false;
            });
          this.membersSheet();
        }
      }.width('100%').height('100%').backgroundColor(pageColor(this.palette, 'canvas'));
      }
    }.hideTitleBar(!this.showMealPoll).attributeModifier(new AppDestinationStyle(this.group.name, pageColor(this.palette, 'canvas'), pageColor(this.palette, 'header'), this.palette)).onShown((): void => { this.destinationVisible = true; this.aboutToAppear(); }).onHidden((): void => { this.destinationVisible = false; this.aboutToDisappear(); });
  }
}
