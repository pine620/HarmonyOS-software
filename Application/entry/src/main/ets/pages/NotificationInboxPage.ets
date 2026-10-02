import { common } from '@kit.AbilityKit';
import { NotificationItem, NotificationsResponse } from '../model/NotificationModels';
import { NotificationRepository } from '../repository/NotificationRepository';

interface NotificationError {
  message?: string;
}

function notificationDay(timestamp: number): string {
  const date: Date = new Date(timestamp);
  if (!Number.isFinite(date.getTime())) return '较早';
  const today: Date = new Date();
  if (date.getFullYear() === today.getFullYear() && date.getMonth() === today.getMonth() &&
    date.getDate() === today.getDate()) return '今天';
  const yesterday: Date = new Date(today.getTime() - 24 * 60 * 60 * 1000);
  if (date.getFullYear() === yesterday.getFullYear() && date.getMonth() === yesterday.getMonth() &&
    date.getDate() === yesterday.getDate()) return '昨天';
  return `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`;
}

function notificationTime(timestamp: number): string {
  const date: Date = new Date(timestamp);
  if (!Number.isFinite(date.getTime())) return '';
  const minute: number = date.getMinutes();
  return `${date.getHours()}:${minute < 10 ? `0${minute}` : minute}`;
}

@Component
export struct NotificationInboxPage {
  onOpenNotification: (notificationId: string) => Promise<void> =
    async (_notificationId: string): Promise<void> => {};
  @State items: Array<NotificationItem> = [];
  @State nextPageToken: string = '';
  @State unreadCount: number = 0;
  @State loading: boolean = false;
  @State loaded: boolean = false;
  @State markingAll: boolean = false;
  @State openingId: string = '';
  @State status: string = '';
  private repository: NotificationRepository = new NotificationRepository();

  aboutToAppear(): void {
    void this.load(true);
  }

  private appendUnique(existing: Array<NotificationItem>, next: Array<NotificationItem>): Array<NotificationItem> {
    const result: Array<NotificationItem> = existing.slice();
    for (const item of next) {
      if (!result.some((current: NotificationItem): boolean => current.id === item.id)) result.push(item);
    }
    return result;
  }

  private async load(reset: boolean): Promise<void> {
    if (this.loading || (!reset && this.nextPageToken.length === 0)) return;
    this.loading = true;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const response: NotificationsResponse = await this.repository.list(context, reset ? '' : this.nextPageToken, 20);
      this.items = reset ? response.items : this.appendUnique(this.items, response.items);
      this.nextPageToken = response.nextPageToken;
      this.unreadCount = response.unreadCount;
      this.loaded = true;
      this.status = '';
    } catch (error) {
      const detail: NotificationError = error as NotificationError;
      this.status = `通知加载失败：${detail.message || '请检查网络后重试'}`;
    } finally {
      this.loading = false;
    }
  }

  private async markAllRead(): Promise<void> {
    if (this.markingAll || this.unreadCount === 0) return;
    this.markingAll = true;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.markAllRead(context);
      const now: number = Date.now();
      for (const item of this.items) item.readAt = now;
      this.items = this.items.slice();
      this.unreadCount = 0;
      this.status = '';
      AppStorage.setOrCreate('notificationForegroundRevision',
        (AppStorage.get<number>('notificationForegroundRevision') || 0) + 1);
    } catch (error) {
      const detail: NotificationError = error as NotificationError;
      this.status = `全部已读未完成：${detail.message || '请稍后重试'}`;
    } finally {
      this.markingAll = false;
    }
  }

  private async open(item: NotificationItem): Promise<void> {
    if (this.openingId.length > 0) return;
    this.openingId = item.id;
    try {
      await this.onOpenNotification(item.id);
      if (item.readAt === 0) {
        item.readAt = Date.now();
        this.items = this.items.slice();
        this.unreadCount = Math.max(0, this.unreadCount - 1);
      }
      this.status = '';
    } catch (error) {
      const detail: NotificationError = error as NotificationError;
      this.status = `通知暂时无法打开：${detail.message || '请稍后重试'}`;
    } finally {
      this.openingId = '';
    }
  }

  private showDay(index: number): boolean {
    return index === 0 || notificationDay(this.items[index - 1].createdAt) !==
      notificationDay(this.items[index].createdAt);
  }

  @Builder
  private eventRow(item: NotificationItem, index: number): void {
    Column({ space: 8 }) {
      if (this.showDay(index)) {
        Text(notificationDay(item.createdAt)).fontSize(13).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.muted')).width('100%').padding({ top: 8, bottom: 2 });
      }
      Button() {
        Row({ space: 10 }) {
          Column({ space: 6 }) {
            Row({ space: 8 }) {
              Text(item.title).fontSize(15).fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.ink')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
              Blank();
              if (item.readAt === 0) {
                Text('未读').fontSize(11).fontColor($r('app.color.ink'));
              }
            }.width('100%');
            Text(item.body).fontSize(13).lineHeight(19).fontColor($r('app.color.muted'))
              .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
            Text(notificationTime(item.createdAt)).fontSize(11).fontColor($r('app.color.muted'))
              .width('100%');
          }.layoutWeight(1).alignItems(HorizontalAlign.Start);
        }.width('100%').padding(14);
      }
      .width('100%').padding(0).backgroundColor(item.readAt === 0 ?
        $r('app.color.accent_soft') : $r('app.color.surface'))
      .borderRadius(16).border({ width: 1, color: $r('app.color.line') })
      .enabled(this.openingId.length === 0)
      .accessibilityText(`${item.readAt === 0 ? '未读，' : ''}${item.title}，${item.body}，打开通知`)
      .onClick((): void => { void this.open(item); });
    }.width('100%');
  }

  build() {
    NavDestination() {
      Column({ space: 12 }) {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text('通知').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
            Text(this.unreadCount > 0 ? `${this.unreadCount} 条未读` : '全部已读')
              .fontSize(13).fontColor($r('app.color.muted'));
          }.alignItems(HorizontalAlign.Start);
          Blank();
          Button('全部已读').height(48).fontSize(12).enabled(this.unreadCount > 0 && !this.markingAll)
            .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.ink'))
            .accessibilityText('将全部通知标记为已读')
            .onClick((): void => { void this.markAllRead(); });
        }.width('100%').padding(14).backgroundColor($r('app.color.surface')).borderRadius(18);
        if (this.status.length > 0) {
          Row({ space: 8 }) {
            Text(this.status).fontSize(12).lineHeight(18).fontColor($r('app.color.warning'))
              .layoutWeight(1).maxLines(3);
            Button('重试').height(48).fontSize(12).enabled(!this.loading)
              .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.ink'))
              .onClick((): void => { void this.load(true); });
          }.width('100%').padding(10).backgroundColor($r('app.color.surface')).borderRadius(14);
        }
        if (this.loading && this.items.length === 0) {
          Row({ space: 8 }) {
            LoadingProgress().width(22).height(22).color($r('app.color.accent_action'));
            Text('正在加载通知…').fontSize(13).fontColor($r('app.color.muted'));
          }.width('100%').height(64).justifyContent(FlexAlign.Center);
        } else if (this.loaded && this.items.length === 0 && this.status.length === 0) {
          Text('还没有通知。新的好友、消息和评论动态会显示在这里。')
            .fontSize(14).lineHeight(21).fontColor($r('app.color.muted')).textAlign(TextAlign.Center)
            .width('100%').padding(28).backgroundColor($r('app.color.surface')).borderRadius(18);
        } else {
          List({ space: 8 }) {
            ForEach(this.items, (item: NotificationItem, index: number): void => {
              ListItem() { this.eventRow(item, index); }
            }, (item: NotificationItem): string => item.id);
            if (this.nextPageToken.length > 0) {
              ListItem() {
                Button(this.loading ? '加载中…' : '加载更多').height(48).width('100%').enabled(!this.loading)
                  .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.ink'))
                  .onClick((): void => { void this.load(false); });
              }
            }
          }.width('100%').layoutWeight(1).edgeEffect(EdgeEffect.Spring).scrollBar(BarState.Off);
        }
        Button('刷新通知').height(48).width('100%').enabled(!this.loading)
          .backgroundColor($r('app.color.surface')).fontColor($r('app.color.ink'))
          .border({ width: 1, color: $r('app.color.line') })
          .onClick((): void => { void this.load(true); });
      }.width('100%').height('100%').padding({ left: 16, right: 16, top: 12, bottom: 20 })
        .backgroundColor($r('app.color.canvas')).alignItems(HorizontalAlign.Start);
    }.title('通知');
  }
}
