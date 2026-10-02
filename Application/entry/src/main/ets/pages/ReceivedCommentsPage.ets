import { common } from '@kit.AbilityKit';
import { FoodCard, ReceivedCommentItem, ReceivedCommentsResponse } from '../model/CloudContracts';
import { CardRepository } from '../repository/CardRepository';

interface CommentListError {
  message?: string;
}

function receivedDate(timestamp: number): string {
  const date: Date = new Date(timestamp);
  if (!Number.isFinite(date.getTime())) return '';
  const month: number = date.getMonth() + 1;
  const day: number = date.getDate();
  const hour: number = date.getHours();
  const minute: number = date.getMinutes();
  return `${date.getFullYear()}-${month < 10 ? `0${month}` : month.toString()}-` +
    `${day < 10 ? `0${day}` : day.toString()} ${hour < 10 ? `0${hour}` : hour.toString()}:` +
    `${minute < 10 ? `0${minute}` : minute.toString()}`;
}

@Component
export struct ReceivedCommentsPage {
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @State items: Array<ReceivedCommentItem> = [];
  @State nextPageToken: string = '';
  @State loading: boolean = false;
  @State initialLoaded: boolean = false;
  @State openingCardId: string = '';
  @State status: string = '';
  private failedReset: boolean = true;
  private failedOpenItem: ReceivedCommentItem | undefined = undefined;
  private repository: CardRepository = new CardRepository();
  private avatarGeneration: number = 0;
  private hydratingAvatarIds: Set<string> = new Set<string>();

  aboutToAppear(): void {
    if (!this.initialLoaded) void this.load(true);
  }

  private async load(reset: boolean): Promise<void> {
    if (this.loading) return;
    this.loading = true;
    this.failedOpenItem = undefined;
    if (reset) {
      this.avatarGeneration += 1;
      this.hydratingAvatarIds.clear();
    }
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const token: string = reset ? '' : this.nextPageToken;
      const result: ReceivedCommentsResponse = await this.repository.receivedComments(context, token);
      this.items = reset ? result.items : [...this.items, ...result.items];
      this.nextPageToken = result.nextPageToken;
      this.initialLoaded = true;
      this.status = '';
      const generation: number = this.avatarGeneration;
      for (const item of result.items) void this.hydrateAvatar(item, generation);
    } catch (error) {
      this.failedReset = reset;
      this.status = `评论加载失败：${(error as CommentListError).message || '请稍后重试'}`;
    } finally {
      this.loading = false;
    }
  }

  private async hydrateAvatar(item: ReceivedCommentItem, generation: number): Promise<void> {
    if (typeof item.authorAvatarPath !== 'string' || item.authorAvatarPath.length === 0 ||
      this.hydratingAvatarIds.has(item.id)) return;
    this.hydratingAvatarIds.add(item.id);
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const url: string = await this.repository.hydrateReceivedCommentAvatar(context, item);
      if (generation !== this.avatarGeneration || url.length === 0) return;
      this.items = this.items.map((current: ReceivedCommentItem): ReceivedCommentItem => {
        if (current.id !== item.id) return current;
        return {
          id: current.id, cardId: current.cardId, cardName: current.cardName,
          authorNickname: current.authorNickname, authorAvatarUrl: url,
          authorAvatarPath: current.authorAvatarPath || '', authorAvatarBucket: current.authorAvatarBucket || '',
          content: current.content, kind: current.kind, createdAt: current.createdAt
        };
      });
    } catch (_error) {
      // An optional avatar must not stop the comment list from rendering.
    } finally {
      if (generation === this.avatarGeneration) this.hydratingAvatarIds.delete(item.id);
    }
  }

  private async openComment(item: ReceivedCommentItem): Promise<void> {
    if (this.openingCardId.length > 0) return;
    this.openingCardId = item.cardId;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const card: FoodCard = await this.repository.detail(context, item.cardId);
      this.status = '';
      this.failedOpenItem = undefined;
      this.onOpenCard(card);
    } catch (error) {
      this.failedOpenItem = item;
      this.status = `卡片暂时无法打开：${(error as CommentListError).message || '请稍后重试'}`;
    } finally {
      this.openingCardId = '';
    }
  }

  private retry(): void {
    const failedItem: ReceivedCommentItem | undefined = this.failedOpenItem;
    if (failedItem !== undefined) {
      void this.openComment(failedItem);
      return;
    }
    void this.load(this.failedReset);
  }

  build() {
    NavDestination() {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 3 }) {
            Text('评论').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
            Text('别人评论我的卡片，或回复我的评论')
              .fontSize(12).fontColor($r('app.color.muted'));
          }.alignItems(HorizontalAlign.Start);
          Blank();
          Button('刷新').height(44).fontSize(12).enabled(!this.loading)
            .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.accent_action'))
            .onClick((): void => { void this.load(true); });
        }.width('100%').padding(14).backgroundColor($r('app.color.surface')).borderRadius(18);
        if (this.status.length > 0) {
          Row({ space: 8 }) {
            Text(this.status).fontSize(12).fontColor($r('app.color.warning'))
              .layoutWeight(1).maxLines(3);
            Button('重试').height(44).fontSize(12).enabled(!this.loading)
              .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.accent_action'))
              .onClick((): void => this.retry());
          }.width('100%').padding(10).backgroundColor($r('app.color.surface')).borderRadius(14);
        }
        if (this.loading && this.items.length === 0) {
          Row({ space: 8 }) {
            LoadingProgress().width(22).height(22).color($r('app.color.accent_action'));
            Text('正在加载评论…').fontSize(13).fontColor($r('app.color.muted'));
          }.width('100%').height(64).justifyContent(FlexAlign.Center);
        } else if (this.initialLoaded && this.items.length === 0 && this.status.length === 0) {
          Text('还没有收到评论或回复。')
            .fontSize(14).fontColor($r('app.color.muted')).textAlign(TextAlign.Center)
            .width('100%').padding(28).backgroundColor($r('app.color.surface')).borderRadius(18);
        } else {
          List({ space: 8 }) {
            ForEach(this.items, (item: ReceivedCommentItem): void => {
              ListItem() {
                Button() {
                  Column({ space: 8 }) {
                    Row({ space: 10 }) {
                      if (typeof item.authorAvatarUrl === 'string' && item.authorAvatarUrl.length > 0) {
                        Image(item.authorAvatarUrl).width(40).height(40).borderRadius(20)
                          .objectFit(ImageFit.Cover).accessibilityLevel('no');
                      } else {
                        Image($r('app.media.app_icon')).width(40).height(40).borderRadius(20)
                          .objectFit(ImageFit.Cover).accessibilityLevel('no');
                      }
                      Column({ space: 3 }) {
                        Row({ space: 8 }) {
                          Text(item.authorNickname).fontSize(14).fontWeight(FontWeight.Medium)
                            .fontColor($r('app.color.ink')).maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1);
                          Text(receivedDate(item.createdAt)).fontSize(11)
                            .fontColor($r('app.color.muted')).maxLines(1);
                        }.width('100%');
                        Text(item.kind === 'REPLY' ? '回复了你' : '评论了你的卡片')
                          .fontSize(12).fontColor($r('app.color.accent_action'));
                      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
                    }.width('100%');
                    Text(item.content).fontSize(14).fontColor($r('app.color.ink'))
                      .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
                    Text(`来自卡片：${item.cardName}`).fontSize(12).fontColor($r('app.color.muted'))
                      .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
                  }.width('100%').alignItems(HorizontalAlign.Start).padding(14);
                }.width('100%').padding(0).backgroundColor($r('app.color.surface'))
                  .borderRadius(16).enabled(this.openingCardId.length === 0)
                  .accessibilityText(`${item.authorNickname}${item.kind === 'REPLY' ? '回复了你' : '评论了你的卡片'}，打开卡片`)
                  .onClick((): void => { void this.openComment(item); });
              }
            }, (item: ReceivedCommentItem): string => `${item.id}:${item.authorAvatarUrl || ''}`);
            if (this.nextPageToken.length > 0) {
              ListItem() {
                Button(this.loading ? '加载中…' : '加载更多').height(48).width('100%').enabled(!this.loading)
                  .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.accent_action'))
                  .onClick((): void => { void this.load(false); });
              }
            }
          }.width('100%').layoutWeight(1).edgeEffect(EdgeEffect.Spring).scrollBar(BarState.Off);
        }
      }.width('100%').height('100%').padding({ left: 16, right: 16, top: 12, bottom: 20 })
        .backgroundColor($r('app.color.canvas')).alignItems(HorizontalAlign.Start);
    }.title('评论');
  }
}
