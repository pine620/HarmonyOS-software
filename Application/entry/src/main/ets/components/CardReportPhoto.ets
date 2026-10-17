/**
 * 【文件职责】举报 / 审核页面中的一张图片：按举报权限（普通用户或审核员）读取图片，页面离开即释放。
 */
import { common } from '@kit.AbilityKit';
import { ImageRepository } from '../service/ImageRepository';
import { ContentPageGuard, ContentPageTicket } from '../service/ContentPageGuard';
import { DiscoveryActionStyle } from './DiscoveryVisuals';
// 举报图片组件。
@Component
export struct CardReportPhoto {
  @Prop @Watch('reload') mediaId: string = '';
  @Prop reportId: string = '';
  @Prop admin: boolean = false;
  @Prop cover: boolean = true;
  @StorageLink('stage47AppActive') @Watch('reload') appActive: boolean = true;
  @StorageLink('authSessionRevision') @Watch('reload') sessionRevision: number = 0;
  @StorageLink('accountContentRevision') @Watch('reload') contentRevision: number = 0;
  @State url: string = '';
  @State failed: boolean = false;
  private mounted: boolean = false;
  private guard: ContentPageGuard = new ContentPageGuard();
  // 挂载时开始加载。
  aboutToAppear(): void { this.mounted = true; this.reload(); }
  // 卸载时关闭守卫并清空地址。
  aboutToDisappear(): void { this.mounted = false; this.guard.close(); this.url = ''; }
  // 重新加载（参数变化时）。
  private reload(): void {
    this.guard.close(); this.url = ''; this.failed = false;
    if (!this.mounted || !this.appActive || this.mediaId.length === 0) return;
    this.guard.open(); void this.load();
  }
  // 通过 ImageRepository.getCardReportPhotoUrl 读取图片地址。
  private async load(): Promise<void> {
    const ticket: ContentPageTicket = this.guard.ticket();
    if (!this.guard.valid(ticket)) return;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const url: string = await ImageRepository.getCardReportPhotoUrl(context, this.mediaId, this.reportId, this.admin, this.cover,
        async (): Promise<boolean> => this.guard.valid(ticket));
      if (this.guard.valid(ticket)) { this.url = url; this.failed = url.length === 0; }
    } catch (_error) { if (this.guard.valid(ticket)) this.failed = true; }
  }
  // 图片解码失败：删除缓存后重新加载一次。
  private async decodeFailed(): Promise<void> {
    const ticket: ContentPageTicket = this.guard.ticket();
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.url = ''; this.failed = true;
    try { await ImageRepository.reportDecodeFailure(context, this.mediaId, this.cover ? 'COVER_480' : 'ORIGINAL', this.admin ? 'REPORT' : 'PUBLIC', this.admin ? this.reportId : ''); } catch (_error) { }
    if (!this.guard.valid(ticket)) return;
  }
  // 图片或占位。
  build() {
    Stack() {
      if (this.url.length > 0) {
        Image(this.url).width('100%').height('100%').objectFit(this.cover ? ImageFit.Cover : ImageFit.Contain)
          .accessibilityText('举报卡片图片').onError((): void => { void this.decodeFailed(); })
      } else if (this.failed) {
        Button('重试图片').attributeModifier(new DiscoveryActionStyle()).onClick((): void => this.reload())
      } else {
        Image($r('app.media.ic_discovery_all')).width(36).height(36).opacity(0.5).accessibilityText('图片加载中')
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.discovery_soft')).borderRadius(16).clip(true)
  }
}
