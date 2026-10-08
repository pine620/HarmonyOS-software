import { CardRepository } from '../repository/CardRepository';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { GroupConversationSummary, SendMessageRequest, SocialUser } from '../model/FriendModels';
import { FriendRepository } from '../repository/FriendRepository';
import { SocialAvatar } from '../components/social/SocialDisplay';
import { foodCardCategoryLabel, coverFor } from '../components/FoodCover';
import { ErrorDetail, errorText } from '../common/ErrorKit';

function emptyCard(): FoodCard {
  return {
    id: '', productName: '', brand: '', priceFen: 0, priceLabel: '', originalPriceFen: 0,
    specification: '', shop: '', sellingPoints: [], publicOffers: [], reviewText: '', tasteScore: 0,
    sourceLink: '', category: 'other', photoUrl: '', photoPath: '', photoBucket: '', photoWidth: 0,
    photoHeight: 0, photos: [], viewerIsOwner: false, likeCount: 0, favoriteCount: 0,
    viewerLiked: false, viewerFavorited: false, commentCount: 0, comments: [], district: '',
    distanceKm: 0, status: 'APPROVED', createdAt: 0
  };
}

@Component
export struct ShareCardPage {
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  private shareVisible: boolean = true;
  private onAppActiveChanged(): void { if (!this.appActive) this.aboutToDisappear(); else if (this.shareVisible) this.aboutToAppear(); }

  @StorageLink('accountContentRevision') @Watch('onAccountChanged') accountContentRevision: number = 0;
  @State contentAllowed: boolean = false;
  private generation: number = 0;
  private onAccountChanged(): void { this.aboutToDisappear(); if (this.shareVisible && this.appActive) this.aboutToAppear(); }
  aboutToDisappear(): void { this.generation++; this.contentAllowed = false; this.friends = []; this.groups = []; }
  @Prop card: FoodCard = emptyCard();
  onOpenChat: (friend: SocialUser) => void = (_friend: SocialUser): void => {};
  onOpenGroup: (group: GroupConversationSummary) => void = (_group: GroupConversationSummary): void => {};
  @State friends: Array<SocialUser> = [];
  @State groups: Array<GroupConversationSummary> = [];
  @State loading: boolean = false;
  @State groupsLoading: boolean = false;
  @State sendingUid: string = '';
  @State sentUid: string = '';
  @State sendingGroupId: string = '';
  @State sentGroupId: string = '';
  @State status: string = '';
  private repository: FriendRepository = new FriendRepository();

  aboutToAppear(): void {
    this.generation++; this.contentAllowed = false;
    void this.loadCurrentCard();
    this.loadFriends();
    this.loadGroups();
  }

  private async loadCurrentCard(): Promise<void> { const generation: number = this.generation; try { const card: FoodCard = await new CardRepository().detail(this.getUIContext().getHostContext() as common.UIAbilityContext, this.card.id); if (generation !== this.generation) return; this.card = card; this.contentAllowed = true; } catch (error) { if (generation === this.generation) { this.contentAllowed = false; this.status = errorText(error as ErrorDetail); } } }

  private async loadFriends(): Promise<void> {
    if (this.loading) return;
    this.loading = true; const generation: number = this.generation; const owner: string = AccountRequestGuard.owner();
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const response = await this.repository.listFriends(context);
      if (generation !== this.generation || owner !== AccountRequestGuard.owner()) return;
      this.friends = response.friends;
      this.status = '';
    } catch (error) {
      this.status = `好友加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.loading = false;
    }
  }

  private async loadGroups(): Promise<void> {
    if (this.groupsLoading) return;
    this.groupsLoading = true; const generation: number = this.generation; const owner: string = AccountRequestGuard.owner();
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const response = await this.repository.listGroupConversations(context);
      if (generation !== this.generation || owner !== AccountRequestGuard.owner()) return;
      this.groups = response.groups;
    } catch (error) {
      this.status = `群聊加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.groupsLoading = false;
    }
  }

  private async shareWith(friend: SocialUser): Promise<void> {
    if (!this.contentAllowed || this.sendingUid.length > 0) return;
    this.sendingUid = friend.uid;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const request: SendMessageRequest = {
        friendUid: friend.uid, kind: 'CARD', text: '', link: '', cardId: this.card.id
      };
      await this.repository.sendMessage(context, request);
      this.sentUid = friend.uid;
      this.status = `已把卡片发给 ${friend.nickname}。`;
    } catch (error) {
      this.status = `卡片发送失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.sendingUid = '';
    }
  }

  private priceText(): string {
    return this.card.priceFen > 0 ? `¥${(this.card.priceFen / 100).toFixed(2)}` : '价格待补充';
  }

  private handleFriendAction(friend: SocialUser): void {
    if (this.sentUid === friend.uid) {
      this.onOpenChat(friend);
      return;
    }
    this.shareWith(friend);
  }

  private async shareWithGroup(group: GroupConversationSummary): Promise<void> {
    if (!this.contentAllowed || this.sendingGroupId.length > 0) return;
    this.sendingGroupId = group.id;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.sendGroupMessage(context, {
        groupId: group.id, kind: 'CARD', text: '', cardId: this.card.id
      });
      this.sentGroupId = group.id;
      this.status = `已把卡片发到「${group.name}」。`;
    } catch (error) {
      this.status = `卡片发送失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.sendingGroupId = '';
    }
  }

  private handleGroupAction(group: GroupConversationSummary): void {
    if (this.sentGroupId === group.id) {
      this.onOpenGroup(group);
      return;
    }
    this.shareWithGroup(group);
  }

  @Builder
  private cardPreview(): void {
    Row({ space: 12 }) {
      if (this.card.photoUrl.length > 0) {
        Image(this.card.photoUrl).width(88).height(88).objectFit(ImageFit.Cover).borderRadius(14)
          .accessibilityText(`${this.card.productName}的实拍图`);
      } else {
        Image(coverFor(this.card.category)).width(88).height(88).objectFit(ImageFit.Cover).borderRadius(14)
          .accessibilityLevel('no');
      }
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          Image($r('app.media.ic_card_share')).width(20).height(20).objectFit(ImageFit.Contain)
            .accessibilityLevel('no');
          Text('准备发送').fontSize(11).fontColor($r('app.color.leaf'));
        }.width('100%');
        Text(this.card.productName || '食刻卡片').fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.ink')).width('100%').maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`${foodCardCategoryLabel(this.card)} · ${this.priceText()}`)
          .fontSize(13).fontColor($r('app.color.muted')).width('100%');
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
    }
    .width('100%').padding(14).backgroundColor($r('app.color.accent_soft')).borderRadius(20)
    .border({ width: 1, color: $r('app.color.line') });
  }

  @Builder
  private friendRow(friend: SocialUser): void {
    Row({ space: 12 }) {
      SocialAvatar({ user: friend, avatarSize: 52 });
      Column({ space: 4 }) {
        Text(friend.nickname).fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
          .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(friend.friendCode).fontSize(12).fontColor($r('app.color.muted')).width('100%').maxLines(1);
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Button(this.sendingUid === friend.uid ? '发送中' : (this.sentUid === friend.uid ? '打开聊天' : '发送'))
        .height(48)
        .enabled(this.contentAllowed && this.sendingUid.length === 0).backgroundColor($r('app.color.accent_action'))
        .fontColor($r('app.color.on_accent_action')).onClick((): void => {
          this.handleFriendAction(friend);
        });
    }
    .width('100%').padding({ top: 10, bottom: 10 });
  }

  @Builder
  private groupRow(group: GroupConversationSummary): void {
    Row({ space: 12 }) {
      Text('群').fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.on_accent_action'))
        .width(48).height(48).textAlign(TextAlign.Center).padding({ top: 13 })
        .backgroundColor($r('app.color.leaf')).borderRadius(16).accessibilityLevel('no');
      Column({ space: 4 }) {
        Text(group.name).fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
          .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`${group.memberCount} 人群聊`).fontSize(12).fontColor($r('app.color.muted')).width('100%');
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Button(this.sendingGroupId === group.id ? '发送中' : (this.sentGroupId === group.id ? '打开群聊' : '发送'))
        .height(48).enabled(this.contentAllowed && this.sendingGroupId.length === 0).backgroundColor($r('app.color.accent_action'))
        .fontColor($r('app.color.on_accent_action')).onClick((): void => {
          this.handleGroupAction(group);
        });
    }
    .width('100%').padding({ top: 10, bottom: 10 });
  }

  build() {
    NavDestination() {
      Column({ space: 16 }) {
        Column({ space: 4 }) {
          Text('发送给好友').fontSize(25).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
            .width('100%');
          Text('只显示已互相确认的食刻好友').fontSize(13).fontColor($r('app.color.muted')).width('100%');
        }.width('100%').alignItems(HorizontalAlign.Start);
        if (this.contentAllowed) { this.cardPreview(); } else { Text('正在重新验证卡片，发送暂不可用。'); }
        if (this.status.length > 0) {
          Text(this.status).fontSize(12).lineHeight(18).fontColor($r('app.color.warning')).width('100%')
            .padding(10).backgroundColor($r('app.color.accent_soft')).borderRadius(12);
        }
        if (this.loading) {
          Column({ space: 10 }) {
            LoadingProgress().width(34).height(34).color($r('app.color.accent_action'));
            Text('正在加载好友').fontSize(13).fontColor($r('app.color.muted'));
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
        } else if (this.friends.length === 0 && !this.groupsLoading && this.groups.length === 0) {
          Column({ space: 10 }) {
            Image($r('app.media.ic_message')).width(54).height(54).objectFit(ImageFit.Contain)
              .accessibilityLevel('no');
            Text('还没有可发送的好友').fontSize(18).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink'));
            Text('先到“好友”页搜索食刻号并互相确认，再回来发送这张卡片。')
              .fontSize(13).lineHeight(20).fontColor($r('app.color.muted')).textAlign(TextAlign.Center)
              .width('82%');
            Button('重新加载').height(48).backgroundColor($r('app.color.accent_soft'))
              .fontColor($r('app.color.accent_action')).onClick((): void => {
                this.loadFriends();
              });
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
        } else {
          List() {
            if (this.friends.length > 0) {
              ListItem() {
                Text('好友').fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).width('100%')
                  .padding({ top: 8, bottom: 4 });
              }
            }
            ForEach(this.friends, (friend: SocialUser): void => {
              ListItem() {
                Column() {
                  this.friendRow(friend);
                  Divider().strokeWidth(1).color($r('app.color.line'));
                }.width('100%');
              }
            }, (friend: SocialUser): string => friend.uid);
            if (this.groups.length > 0) {
              ListItem() {
                Text('群聊').fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).width('100%')
                  .padding({ top: 12, bottom: 4 });
              }
            }
            ForEach(this.groups, (group: GroupConversationSummary): void => {
              ListItem() {
                Column() {
                  this.groupRow(group);
                  Divider().strokeWidth(1).color($r('app.color.line'));
                }.width('100%');
              }
            }, (group: GroupConversationSummary): string => group.id);
          }
          .width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
          .padding({ left: 14, right: 14 }).backgroundColor($r('app.color.surface')).borderRadius(20)
          .border({ width: 1, color: $r('app.color.line') });
        }
      }
      .width('100%').height('100%').padding({ left: 16, right: 16, top: 14, bottom: 20 })
      .backgroundColor($r('app.color.canvas')).alignItems(HorizontalAlign.Start);
    }.title('发送卡片').onShown((): void => { this.shareVisible = true; this.aboutToAppear(); }).onHidden((): void => { this.shareVisible = false; this.aboutToDisappear(); });
  }
}
