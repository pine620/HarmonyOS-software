import { common } from '@kit.AbilityKit';
import { ImageRepository } from '../service/ImageRepository';
import { ContentPageGuard, ContentPageTicket } from '../service/ContentPageGuard';
import { DiscoveryActionStyle } from './DiscoveryVisuals';
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
  aboutToAppear(): void { this.mounted = true; this.reload(); }
  aboutToDisappear(): void { this.mounted = false; this.guard.close(); this.url = ''; }
  private reload(): void {
    this.guard.close(); this.url = ''; this.failed = false;
    if (!this.mounted || !this.appActive || this.mediaId.length === 0) return;
    this.guard.open(); void this.load();
  }
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
  private async decodeFailed(): Promise<void> {
    const ticket: ContentPageTicket = this.guard.ticket();
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.url = ''; this.failed = true;
    try { await ImageRepository.reportDecodeFailure(context, this.mediaId, this.cover ? 'COVER_480' : 'ORIGINAL', this.admin ? 'REPORT' : 'PUBLIC', this.admin ? this.reportId : ''); } catch (_error) { }
    if (!this.guard.valid(ticket)) return;
  }
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
