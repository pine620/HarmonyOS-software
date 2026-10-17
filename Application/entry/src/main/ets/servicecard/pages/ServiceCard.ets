/**
 * 【文件职责】「食刻推荐」桌面卡片页面（2×2 / 2×4）。数据通过 LocalStorage 由 ServiceCardStore 绑定；点击打开卡片详情，刷新按钮发送消息给扩展。
 */
import { serviceCardOpenAction, serviceCardPrice, serviceCardRefreshAction,
  serviceCardShortScore } from '../ServiceCardPresentation';

const serviceCardStorage: LocalStorage = new LocalStorage();

// 卡片页面（数据字段由 @LocalStorageProp 绑定）。
@Entry(serviceCardStorage)
@Component
struct ServiceCard {
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('formDimension') formDimension: number = 2;
  @LocalStorageProp('cardId') cardId: string = '';
  @LocalStorageProp('productName') productName: string = '附近值得一试';
  @LocalStorageProp('scoreText') scoreText: string = '';
  @LocalStorageProp('priceText') priceText: string = '';
  @LocalStorageProp('locationText') locationText: string = '20 km 内';
  @LocalStorageProp('categoryText') categoryText: string = '附近';
  @LocalStorageProp('photoPath') photoPath: string = '';
  @LocalStorageProp('photoBucket') photoBucket: string = '';
  @LocalStorageProp('coverCardId') coverCardId: string = '';
  @LocalStorageProp('coverPhotoPath') coverPhotoPath: string = '';
  @LocalStorageProp('coverPhotoBucket') coverPhotoBucket: string = '';
  @LocalStorageProp('coverImageName') @Watch('onCoverChanged') coverImageName: string = '';
  @State private cardHeight: number = 160;
  @State private coverFailed: boolean = false;

  // 封面变化时刷新。
  private onCoverChanged(): void {
    this.coverFailed = false;
  }

  // 是否有可展示的卡片。
  private hasCard(): boolean {
    return this.cardId.trim().length > 0;
  }

  // 是否有封面。
  private hasCover(): boolean {
    return this.hasCard() && !this.coverFailed && /^shike_cover_[0-9a-f_]+$/.test(this.coverImageName) &&
      this.coverCardId === this.cardId && this.coverPhotoPath === this.photoPath &&
      this.coverPhotoBucket === this.photoBucket && this.photoPath.length > 0;
  }

  // 打开推荐卡片。
  private openRecommendation(): void {
    postCardAction(this, serviceCardOpenAction(this.cardId));
  }

  // “打开”按钮的无障碍文本。
  private openLabel(): string {
    if (!this.hasCard()) return '打开食刻，发现附近好味道';
    return `${this.productName}，${this.categoryText}，${this.locationText}，` +
      `好味评分${serviceCardShortScore(this.scoreText)}，${serviceCardPrice(this.priceText)}，打开详情`;
  }

  // 顶部区域。
  @Builder
  private header() {
    Row({ space: 6 }) {
      Image($r('app.media.app_icon')).width(18).height(18).borderRadius(5)
        .accessibilityLevel('no')
      Text('食刻').fontSize(11).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ink')).layoutWeight(1).maxLines(1)
      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.ic_service_card_refresh')).width(17).height(17)
          .fillColor($r('app.color.muted')).accessibilityLevel('no')
      }
      .width(44).height(44).padding(0).borderRadius(12)
      .backgroundColor(Color.Transparent).stateEffect(true)
      .accessibilityText('刷新桌面推荐摘要')
      .accessibilityDescription('重新显示设备已缓存的推荐与封面，不下载新推荐')
      .onClick((): void => { postCardAction(this, serviceCardRefreshAction()); })
    }.width('100%').height(44)
  }

  // 文字摘要。
  @Builder
  private summary() {
    Button({ type: ButtonType.Normal }) {
      Column() {
        Text(this.hasCard() ? this.productName : '附近值得一试')
          .fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
          .width('100%').layoutWeight(1).maxLines(this.cardHeight >= 176 ? 2 : 1)
          .minFontSize('14vp').maxFontSize(this.formDimension === 3 ? 23 : 20)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.cardHeight >= 156) {
          Text(this.hasCard() ? `${this.categoryText} · ${this.locationText}` : '打开食刻，发现好味道')
            .fontColor($r('app.color.muted')).width('100%').height(14)
            .minFontSize('10vp').maxFontSize(11).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ bottom: 2 })
        }
        if (this.hasCard()) {
          Row({ space: 8 }) {
            Text(serviceCardShortScore(this.scoreText)).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.ink')).width(48).height(24)
              .textAlign(TextAlign.Center).minFontSize('10vp').maxFontSize(11).maxLines(1)
              .backgroundColor($r('app.color.accent_soft')).borderRadius(8)
            Text(serviceCardPrice(this.priceText)).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.ink')).layoutWeight(1).height(24)
              .minFontSize('10vp').maxFontSize(14).maxLines(1).textAlign(TextAlign.End)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%').height(24).margin({ top: 4 })
        }
        Row() {
          Text(this.hasCard() ? '查看详情' : '去发现').fontColor($r('app.color.service_card_link'))
            .layoutWeight(1).minFontSize('10vp').maxFontSize(11).maxLines(1)
          Image($r('app.media.ic_service_card_chevron')).width(12).height(12)
            .fillColor($r('app.color.service_card_link')).accessibilityLevel('no')
        }.width('100%').height(18).margin({ top: 4 })
      }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
    }
    .width('100%').layoutWeight(1).padding(0).borderRadius(8)
    .backgroundColor(Color.Transparent).stateEffect(true)
    .accessibilityGroup(true).accessibilityText(this.openLabel())
    .onClick((): void => { this.openRecommendation(); })
  }

  // 封面。
  @Builder
  private cover() {
    Button({ type: ButtonType.Normal }) {
      Stack() {
        Column({ space: 8 }) {
          Image($r('app.media.ic_service_card_photo')).width(28).height(28)
            .fillColor($r('app.color.muted')).accessibilityLevel('no')
          Text(this.hasCard() ? (this.photoPath.length > 0 ? '封面待加载' : '暂无封面') : '发现好味道')
            .fontColor($r('app.color.muted'))
            .minFontSize('10vp').maxFontSize(11).maxLines(1)
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
        if (this.hasCover()) {
          Image(`memory://${this.coverImageName}`).width('100%').height('100%')
            .objectFit(ImageFit.Cover).accessibilityLevel('no')
            .onError((): void => { this.coverFailed = true; })
        }
      }.width('100%').height('100%')
    }
    .width('36%').height('100%').padding(0).margin({ left: 12 }).borderRadius(16)
    .backgroundColor($r('app.color.accent_soft')).clip(true).stateEffect(true)
    .accessibilityText(this.hasCover() ? `${this.productName}的封面，打开详情` : this.openLabel())
    .onClick((): void => { this.openRecommendation(); })
  }

  // 布局（按尺寸切换）。
  build() {
    Row() {
      Column() {
        this.header()
        this.summary()
      }.layoutWeight(1).height('100%').alignItems(HorizontalAlign.Start)
      if (this.formDimension === 3) {
        this.cover()
      }
    }
    .width('100%').height('100%').padding(this.cardHeight < 156 ? 10 : 12)
    .backgroundColor($r('app.color.surface')).borderRadius(24)
    .onSizeChange((_oldSize: SizeOptions, newSize: SizeOptions): void => {
      const height: number = Number(newSize.height);
      if (Number.isFinite(height) && height > 0 && this.cardHeight !== height) this.cardHeight = height;
    })
  }
}
