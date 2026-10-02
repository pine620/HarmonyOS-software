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
import { categoryLabel, coverFor } from '../components/FoodCover';
import { ErrorDetail, errorText } from '../common/ErrorKit';

const GROUP_MESSAGE_PAGE_SIZE = 50;
const GROUP_AUTO_REFRESH_MS = 12000;

function messageTime(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '';
  const date = new Date(timestamp);
  const minute = date.getMinutes();
  return `${date.getMonth() + 1}月${date.getDate()}日 ${date.getHours()}:${minute < 10 ? `0${minute}` : minute}`;
}

@Component
export struct GroupChatPage {
  @Prop group: GroupConversationSummary = emptyGroupConversation();
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  onGroupChanged: () => void = (): void => {};
  @StorageLink('socialForegroundRevision') @Watch('onSocialForegroundChanged') socialForegroundRevision: number = 0;
  @State detail: GroupChatDetailResponse | undefined = undefined;
  @State messages: Array<GroupMessage> = [];
  @State nextBeforeToken: string = '';
  @State textDraft: string = '';
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
  private refreshTimer: number | undefined = undefined;

  aboutToAppear(): void {
    this.loadDetail();
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
    if (this.socialForegroundRevision > 0) {
      this.loadDetail();
      this.loadMessages(true);
    }
  }

  private startAutoRefresh(): void {
    if (this.refreshTimer !== undefined) clearInterval(this.refreshTimer);
    this.refreshTimer = setInterval((): void => {
      this.loadMessages(true);
    }, GROUP_AUTO_REFRESH_MS);
  }

  private isOwner(): boolean {
    const profile = AuthService.profile();
    return profile !== undefined && this.detail !== undefined && this.detail.group.ownerUid === profile.uid;
  }

  private memberCount(): number {
    return this.detail === undefined ? this.group.memberCount : this.detail.members.length;
  }

  private containsCard(cards: Array<FoodCard>, cardId: string): boolean {
    return cards.some((card: FoodCard): boolean => card.id === cardId);
  }

  private async loadDetail(): Promise<void> {
    if (this.detailLoading) return;
    this.detailLoading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.detail = await this.friendRepository.groupDetail(context, this.group.id);
    } catch (error) {
      this.status = `群聊信息加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.detailLoading = false;
    }
  }

  private async loadMessages(reset: boolean): Promise<void> {
    if (this.loading || this.loadingOlder) return;
    if (!reset && this.nextBeforeToken.length === 0) return;
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
      this.messages = reset ? response.messages : response.messages.concat(this.messages);
      this.nextBeforeToken = response.nextBeforeToken;
    } catch (error) {
      this.status = `群消息加载失败：${errorText(error as ErrorDetail)}`;
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
    } catch (error) {
      this.status = `卡片加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.cardsLoading = false;
    }
  }

  private async sendRequest(request: SendGroupMessageRequest): Promise<void> {
    if (this.sending) return;
    this.sending = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const message = await this.friendRepository.sendGroupMessage(context, request);
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
    this.sendRequest({ groupId: this.group.id, kind: 'TEXT', text: value, cardId: '' });
  }

  private sendCard(card: FoodCard): void {
    this.sendRequest({ groupId: this.group.id, kind: 'CARD', text: '', cardId: card.id });
    this.cardPickerVisible = false;
  }

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

  private priceText(card: FoodCard): string {
    return card.priceFen > 0 ? `¥${(card.priceFen / 100).toFixed(2)}` : '价格待补充';
  }

  @Builder
  private header(): void {
    Row({ space: 10 }) {
      Text('群').fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.on_accent_action'))
        .width(48).height(48).textAlign(TextAlign.Center).padding({ top: 13 })
        .backgroundColor($r('app.color.leaf')).borderRadius(16).accessibilityLevel('no');
      Column({ space: 3 }) {
        Text(this.group.name).fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
          .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`${this.memberCount()} 人 · 自动更新`).fontSize(12)
          .fontColor($r('app.color.muted')).width('100%');
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Button('成员').height(44).fontSize(12).backgroundColor($r('app.color.accent_soft'))
        .fontColor($r('app.color.accent_action')).onClick((): void => {
          this.membersVisible = true;
        });
    }
    .width('100%').padding(10).backgroundColor($r('app.color.surface')).borderRadius(18)
    .border({ width: 1, color: $r('app.color.line') });
  }

  @Builder
  private sharedCard(card: FoodCard): void {
    Row({ space: 10 }) {
      if (card.photoUrl.length > 0) {
        Image(card.photoUrl).width(70).height(70).objectFit(ImageFit.Cover).borderRadius(12)
          .accessibilityText(`${card.productName}的实拍图`);
      } else {
        Image(coverFor(card.category)).width(70).height(70).objectFit(ImageFit.Cover).borderRadius(12)
          .accessibilityLevel('no');
      }
      Column({ space: 4 }) {
        Text(card.productName || '食刻卡片').fontSize(14).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
          .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`${categoryLabel(card.category)} · ${this.priceText(card)}`).fontSize(11)
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
  private messageContent(message: GroupMessage): void {
    if (message.kind === 'CARD') {
      if (message.sharedCard !== undefined) this.sharedCard(message.sharedCard);
      else {
        Text('卡片暂不可查看').fontSize(13).fontColor($r('app.color.muted')).padding(12)
          .backgroundColor($r('app.color.surface')).borderRadius(16);
      }
    } else {
      Text(message.text).fontSize(15).lineHeight(22)
        .fontColor(message.mine ? $r('app.color.on_accent_action') : $r('app.color.ink'))
        .padding({ left: 14, right: 14, top: 11, bottom: 11 })
        .backgroundColor(message.mine ? $r('app.color.accent_action') : $r('app.color.surface'))
        .borderRadius(18).constraintSize({ maxWidth: 270 });
    }
  }

  @Builder
  private messageRow(message: GroupMessage): void {
    Column({ space: 4 }) {
      if (!message.mine) {
        Text(message.sender.nickname).fontSize(11).fontColor($r('app.color.muted')).width('100%').padding({ left: 40 });
      }
      Row() {
        if (message.mine) {
          Blank();
        } else {
          SocialAvatar({ user: message.sender, avatarSize: 32 });
          Blank().width(8);
        }
        this.messageContent(message);
        if (!message.mine) Blank();
      }.width('100%').alignItems(VerticalAlign.Bottom);
      Text(messageTime(message.createdAt)).fontSize(10).fontColor($r('app.color.muted')).width('100%')
        .textAlign(message.mine ? TextAlign.End : TextAlign.Start)
        .padding({ left: message.mine ? 0 : 40, right: message.mine ? 2 : 0 });
    }.width('100%');
  }

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
        Text(card.productName || '食刻卡片').fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink'))
          .width(118).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(this.priceText(card)).fontSize(12).fontColor($r('app.color.accent_action'));
      }.alignItems(HorizontalAlign.Start);
      Button(this.sending ? '发送中' : '发送').height(40).fontSize(12).enabled(!this.sending)
        .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
        .onClick((): void => {
          this.sendCard(card);
        });
    }
    .padding(8).backgroundColor($r('app.color.surface')).borderRadius(14)
    .border({ width: 1, color: $r('app.color.line') });
  }

  @Builder
  private composer(): void {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.textDraft, placeholder: '输入群消息' }).layoutWeight(1).height(48).fontSize(15)
          .backgroundColor($r('app.color.canvas')).borderRadius(14).onChange((value: string): void => {
            this.textDraft = value;
          });
        Button('卡片').height(48).fontSize(12).backgroundColor($r('app.color.accent_soft'))
          .fontColor($r('app.color.accent_action')).enabled(!this.sending).onClick((): void => {
            this.cardPickerVisible = !this.cardPickerVisible;
            if (this.cardPickerVisible && this.cardCandidates.length === 0) this.loadCardCandidates();
          });
        Button('发送').height(48).fontSize(12).enabled(!this.sending).backgroundColor($r('app.color.accent_action'))
          .fontColor($r('app.color.on_accent_action')).onClick((): void => {
            this.sendText();
          });
      }.width('100%').alignItems(VerticalAlign.Center);
      if (this.cardPickerVisible && this.cardsLoading) {
        Row({ space: 8 }) {
          LoadingProgress().width(22).height(22).color($r('app.color.accent_action'));
          Text('正在读取可分享卡片').fontSize(13).fontColor($r('app.color.muted'));
        }.width('100%').height(56).justifyContent(FlexAlign.Center);
      } else if (this.cardPickerVisible && this.cardCandidates.length === 0) {
        Text('暂无可发送卡片，先收藏或发布一张公开卡片。').fontSize(12).fontColor($r('app.color.muted'))
          .width('100%').padding(8);
      } else if (this.cardPickerVisible) {
        List({ space: 10 }) {
          ForEach(this.cardCandidates, (card: FoodCard): void => {
            ListItem() { this.cardChoice(card); }
          }, (card: FoodCard): string => card.id);
        }.width('100%').height(96).listDirection(Axis.Horizontal).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring);
      }
    }
    .width('100%').padding(10).backgroundColor($r('app.color.surface')).borderRadius(18)
    .border({ width: 1, color: $r('app.color.line') });
  }

  @Builder
  private membersSheet(): void {
    Column({ space: 12 }) {
      Text('群成员').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).width('100%');
      if (this.detail === undefined || this.detailLoading) {
        Row({ space: 8 }) {
          LoadingProgress().width(22).height(22).color($r('app.color.accent_action'));
          Text('正在读取成员').fontSize(13).fontColor($r('app.color.muted'));
        }.width('100%').height(120).justifyContent(FlexAlign.Center);
      } else {
        List({ space: 8 }) {
          ForEach(this.detail.members, (member: GroupMemberProfile): void => {
            ListItem() {
              Row({ space: 10 }) {
                SocialAvatar({ user: member.user, avatarSize: 40 });
                Column({ space: 2 }) {
                  Text(member.user.nickname).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink'));
                  Text(member.role === 'OWNER' ? '群主' : member.user.friendCode).fontSize(11)
                    .fontColor($r('app.color.muted')).width('100%').maxLines(1);
                }.layoutWeight(1).alignItems(HorizontalAlign.Start);
                if (this.isOwner() && member.role !== 'OWNER') {
                  Button(this.memberActionUid === member.user.uid ? '处理中' : '移除').height(40).fontSize(12)
                    .enabled(this.memberActionUid.length === 0).backgroundColor($r('app.color.surface'))
                    .fontColor($r('app.color.danger')).border({ width: 1, color: $r('app.color.line') })
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
        .backgroundColor($r('app.color.surface')).fontColor($r('app.color.ink'))
        .border({ width: 1, color: $r('app.color.line') }).onClick((): void => {
          this.membersVisible = false;
        });
    }
    .width('100%').padding({ left: 20, right: 20, top: 18, bottom: 20 }).backgroundColor($r('app.color.surface'))
    .borderRadius(24).border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start);
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        Column({ space: 10 }) {
          this.header();
          if (this.status.length > 0) {
            Text(this.status).fontSize(12).lineHeight(18).fontColor($r('app.color.warning')).width('100%')
              .padding(9).backgroundColor($r('app.color.accent_soft')).borderRadius(12);
          }
          if (this.loading && this.messages.length === 0) {
            Column({ space: 10 }) {
              LoadingProgress().width(34).height(34).color($r('app.color.accent_action'));
              Text('正在加载群消息').fontSize(13).fontColor($r('app.color.muted'));
            }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
          } else if (this.messages.length === 0) {
            Column({ space: 10 }) {
              Image($r('app.media.ic_message')).width(54).height(54).objectFit(ImageFit.Contain).accessibilityLevel('no');
              Text('从一条群消息开始').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
              Text('可发送文字或分享一张公开食刻卡片。').fontSize(13).fontColor($r('app.color.muted'));
            }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
          } else {
            List({ space: 12 }) {
              if (this.nextBeforeToken.length > 0) {
                ListItem() {
                  Button(this.loadingOlder ? '加载中…' : '查看更早消息').width('100%').height(48).enabled(!this.loadingOlder)
                    .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.accent_action'))
                    .onClick((): void => {
                      this.loadMessages(false);
                    });
                }
              }
              ForEach(this.messages, (message: GroupMessage): void => {
                ListItem() { this.messageRow(message); }
              }, (message: GroupMessage): string => message.id);
            }
            .width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
            .stackFromEnd(true).maintainVisibleContentPosition(true).padding({ left: 2, right: 2, top: 4, bottom: 4 });
          }
          this.composer();
        }
        .width('100%').height('100%').padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .backgroundColor($r('app.color.canvas'));
        if (this.membersVisible) {
          Column() {}.width('100%').height('100%').backgroundColor($r('app.color.scrim'))
            .onClick((): void => {
              if (!this.leaving && this.memberActionUid.length === 0) this.membersVisible = false;
            });
          this.membersSheet();
        }
      }.width('100%').height('100%').backgroundColor($r('app.color.canvas'));
    }.title(this.group.name);
  }
}
