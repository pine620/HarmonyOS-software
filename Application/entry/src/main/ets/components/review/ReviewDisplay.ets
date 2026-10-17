/**
 * 【文件职责】卡片展示组件（全 App 卡片外观的核心）：ReviewCard 主组件及分类标签、价格徽标、证据徽标。
 * 数据来自 CloudCardViewMapper 转换后的 ReviewCardViewData；marketStyle=true 时使用推荐流（发现页）配色与精简布局。
 */
import { common } from '@kit.AbilityKit';
import { ImageRepository } from '../../service/ImageRepository';
// 证据徽标的语气：已核实 / 辅助信息 / 待确认。
export type EvidenceTone = 'verified' | 'assisted' | 'pending';

// ReviewCard 需要的全部展示数据（已格式化好的文本）。
export interface ReviewCardViewData {
  id: string;
  productName: string;
  shop: string;
  categoryLabel: string;
  coverUrl: string;
  coverLoading: boolean;
  coverFailed: boolean;
  photoAlt: string;
  priceText: string;
  originalPriceText: string;
  reviewSummary: string;
  tasteScoreText: string;
  tags: Array<string>;
  evidenceLabel: string;
  evidenceTone: EvidenceTone;
  authorName: string;
  timeLabel: string;
  locationLabel: string;
}

// 空数据（组件默认值）。
export function emptyReviewCardViewData(): ReviewCardViewData {
  return {
    id: '',
    productName: '未命名美食',
    shop: '',
    categoryLabel: '其他',
    coverUrl: '',
    coverLoading: false,
    coverFailed: false,
    photoAlt: '美食实拍图',
    priceText: '价格待补充',
    originalPriceText: '',
    reviewSummary: '',
    tasteScoreText: '',
    tags: [],
    evidenceLabel: '待确认',
    evidenceTone: 'pending',
    authorName: '',
    timeLabel: '',
    locationLabel: ''
  };
}

// 分类标签组件。
@Component
export struct FoodTag {
  @Prop label: string = '';
  @Prop selected: boolean = false;
  @Prop marketStyle: boolean = false;

  build() {
    Text(this.label.length > 0 ? this.label : '未分类')
      .fontSize(12)
      .fontWeight(this.selected ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.marketStyle ? (this.selected ? $r('app.color.discovery_on_gold') : $r('app.color.discovery_ink')) :
        (this.selected ? $r('app.color.on_accent_action') : $r('app.color.ink')))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor(this.marketStyle ? (this.selected ? $r('app.color.discovery_gold') : $r('app.color.discovery_soft')) :
        (this.selected ? $r('app.color.accent_action') : $r('app.color.accent_soft')))
      .border({ width: this.selected ? 2 : 1, color: this.marketStyle ?
        (this.selected ? $r('app.color.discovery_on_gold') : $r('app.color.discovery_line')) :
        (this.selected ? $r('app.color.on_accent_action') : $r('app.color.line')) })
      .borderRadius(14)
      .accessibilityText(`${this.label.length > 0 ? this.label : '未分类'}标签` +
        `${this.selected ? '，已选中' : ''}`);
  }
}

// 价格徽标组件。
@Component
export struct PriceBadge {
  @Prop priceText: string = '价格待补充';
  @Prop originalPriceText: string = '';
  @Prop marketStyle: boolean = false;

  build() {
    Row({ space: 6 }) {
      Text(this.priceText)
        .fontSize(this.marketStyle ? 18 : 16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.marketStyle ? $r('app.color.discovery_accent') : $r('app.color.accent_action'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
      if (this.originalPriceText.length > 0) {
        Text(`原价 ${this.originalPriceText}`)
          .width('42%')
          .fontSize(12)
          .fontColor(this.marketStyle ? $r('app.color.discovery_muted') : $r('app.color.muted'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
    }
    .width('100%')
    .accessibilityGroup(true)
    .accessibilityText(this.originalPriceText.length > 0
      ? `${this.priceText}，原价 ${this.originalPriceText}` : this.priceText);
  }
}

// 证据徽标组件（例如“实拍公开”）。
@Component
export struct EvidenceBadge {
  @Prop label: string = '待确认';
  @Prop tone: EvidenceTone = 'pending';
  @Prop marketStyle: boolean = false;

  // 徽标文字颜色。
  private textColor(): Resource {
    if (this.tone === 'verified') return $r('app.color.leaf');
    if (this.tone === 'assisted') return this.marketStyle ? $r('app.color.discovery_accent') : $r('app.color.accent_action');
    return $r('app.color.warning');
  }

  // 徽标的无障碍描述。
  private description(): string {
    if (this.tone === 'verified') return '此卡片已公开，配有发布者实拍图';
    if (this.tone === 'assisted') return '商品事实由图片或来源信息辅助填写';
    return '商品事实仍待发布者补充确认';
  }

  build() {
    Text(this.label.length > 0 ? this.label : '待确认')
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.textColor())
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: 8, right: 8, top: 5, bottom: 5 })
      .backgroundColor(this.marketStyle ? $r('app.color.discovery_surface') : $r('app.color.surface'))
      .border({ width: 1, color: this.textColor() })
      .borderRadius(12)
      .accessibilityText(`${this.label.length > 0 ? this.label : '待确认'}，${this.description()}`);
  }
}

// 卡片主组件：封面、名称、店铺、价格、评分与点评摘要。
@Component
export struct ReviewCard {
  @Prop @Watch('onDataChanged') data: ReviewCardViewData = emptyReviewCardViewData();
  @Prop featured: boolean = false;
  @Prop coverScale: number = 1;
  @Prop marketStyle: boolean = false;
  @Prop motionEnabled: boolean = true;
  onOpen: (id: string) => void = (_id: string): void => {};
  @State nativeCoverFailed: string = '';
  onCoverFailed: () => void = (): void => {};
  onCoverDecoded: (id: string, url: string) => void = (_id: string, _url: string): void => {};

  // 数据变化时重新计算图片解码尺寸等状态。
  private onDataChanged(): void {
    if (this.data.coverUrl.length === 0 || this.data.coverLoading || this.data.coverUrl !== this.nativeCoverFailed) this.nativeCoverFailed = '';
  }

  // 图片解码尺寸（按显示宽度限制，节省内存）。
  private decodeSize(): ImageSourceSize {
    const size: ImageSourceSize = { width: 180 * this.coverScale, height: this.photoHeight() };
    return size;
  }
  // 封面显示高度（保持原图比例并限制范围）。
  private photoHeight(): number {
    const height: number = this.marketStyle ? this.featured ? 186 : 132 : this.featured ? 224 : 142;
    return Math.round(height * this.coverScale);
  }

  // 点评摘要最多显示的行数。
  private reviewLineCount(): number {
    return this.marketStyle ? 1 : this.featured ? 3 : 2;
  }
  // 按 marketStyle 选择的配色（正文 / 次要 / 强调 / 表面 / 柔和）。
  private inkColor(): Resource { return this.marketStyle ? $r('app.color.discovery_ink') : $r('app.color.ink'); }
  private mutedColor(): Resource { return this.marketStyle ? $r('app.color.discovery_muted') : $r('app.color.muted'); }
  private accentColor(): Resource { return this.marketStyle ? $r('app.color.discovery_accent') : $r('app.color.accent_action'); }
  private surfaceColor(): Resource { return this.marketStyle ? $r('app.color.discovery_surface') : $r('app.color.surface'); }
  private softColor(): Resource { return this.marketStyle ? $r('app.color.discovery_soft') : $r('app.color.accent_soft'); }

  // 封面状态文字（加载中 / 无图 / 无权限等）。
  private coverStatusText(): string {
    if (this.data.coverLoading) return '正在加载实拍图';
    if (this.data.coverFailed) return '实拍图暂时不可用';
    return '暂无实拍图';
  }

  // 封面的无障碍描述。
  private coverDescription(): string {
    if (this.data.coverLoading) return '图片就绪后将自动显示';
    if (this.data.coverFailed) return '可稍后刷新推荐再试';
    return '商品信息仍可查看';
  }

  // 元信息行（时间、位置等）。
  private metadataText(): string {
    const parts: Array<string> = [];
    if (this.data.authorName.length > 0) parts.push(this.data.authorName);
    if (this.data.timeLabel.length > 0) parts.push(this.data.timeLabel);
    if (this.data.locationLabel.length > 0) parts.push(this.data.locationLabel);
    return parts.join(' · ');
  }

  // 整张卡片的无障碍朗读文本。
  private accessibilitySummary(): string {
    const parts: Array<string> = [
      this.data.productName,
      this.data.priceText,
      this.data.evidenceLabel
    ];
    if (this.data.shop.length > 0) parts.push(this.data.shop);
    if (this.data.tasteScoreText.length > 0) parts.push('口味 ' + this.data.tasteScoreText);
    if (this.data.reviewSummary.length > 0) parts.push(this.data.reviewSummary);
    if (this.data.coverLoading) parts.push('实拍图正在加载');
    else if (this.data.coverFailed) parts.push('实拍图暂时不可用');
    return parts.join('，');
  }

  // 卡片布局。
  build() {
    Column({ space: this.marketStyle ? 0 : 10 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        if (this.data.coverUrl.length > 0 && this.nativeCoverFailed !== this.data.coverUrl) {
          Image(this.data.coverUrl)
            .width('100%')
            .height(this.photoHeight())
            .objectFit(ImageFit.Contain)
            .autoResize(true).syncLoad(false).sourceSize(this.decodeSize())
            .borderRadius(this.marketStyle ? 16 : 18)
            .onError((): void => {
              this.nativeCoverFailed = this.data.coverUrl;
              void ImageRepository.reportDecodeFailureByUrl(this.getUIContext().getHostContext() as common.Context, this.data.coverUrl).catch((): void => {});
              this.onCoverFailed();
            })
            .onComplete((event): void => {
              if (event !== undefined && event.loadingStatus === 1) {
                this.onCoverDecoded(this.data.id, this.data.coverUrl);
              }
            })
            .accessibilityText(this.data.photoAlt.length > 0
              ? this.data.photoAlt : `${this.data.productName}实拍图`);
        } else {
          Column({ space: 6 }) {
            Text(this.coverStatusText())
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.inkColor());
            Text(this.coverDescription())
              .fontSize(12)
              .fontColor(this.mutedColor());
          }
          .width('100%')
          .height(this.photoHeight())
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.softColor())
          .borderRadius(16)
          .accessibilityText(this.data.productName + '，' + this.coverStatusText());
        }

        // 发现页（market）卡片只保留名称、店铺、价格与口味；分类已在筛选栏中体现，不再重复显示。
        if (!this.marketStyle) {
          Row() {
            Blank();
            Text(this.data.categoryLabel.length > 0 ? this.data.categoryLabel : '其他')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_accent_action'));
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .backgroundColor($r('app.color.accent_action'));
        }
      }
      .width('100%');

      Column({ space: this.marketStyle ? 7 : 10 }) {
        Row({ space: 8 }) {
          Text(this.data.productName)
            .fontSize(this.marketStyle ? 15 : 17)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.inkColor())
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          if (this.featured && !this.marketStyle) {
            EvidenceBadge({ label: this.data.evidenceLabel, tone: this.data.evidenceTone });
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top);

        if (this.data.shop.length > 0) {
          Text(this.data.shop)
            .width('100%')
            .fontSize(12)
            .fontColor(this.mutedColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }

        if (this.marketStyle) {
          Row({ space: 6 }) {
            PriceBadge({ priceText: this.data.priceText, originalPriceText: this.data.originalPriceText, marketStyle: true })
              .layoutWeight(1);
            if (this.data.tasteScoreText.length > 0) {
              Text('口味 ' + this.data.tasteScoreText)
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.accentColor())
                .maxLines(1)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor(this.softColor())
                .borderRadius(10)
                .accessibilityText('口味评分 ' + this.data.tasteScoreText);
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center);
        } else {
          PriceBadge({ priceText: this.data.priceText, originalPriceText: this.data.originalPriceText, marketStyle: this.marketStyle });

          if (this.data.tasteScoreText.length > 0) {
            Text('口味 ' + this.data.tasteScoreText)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.accentColor())
              .padding({ left: 8, right: 8, top: 5, bottom: 5 })
              .backgroundColor(this.softColor())
              .borderRadius(10)
              .accessibilityText('口味评分 ' + this.data.tasteScoreText);
          }
        }

        if (this.data.reviewSummary.length > 0 && !this.marketStyle) {
          Text(this.data.reviewSummary)
            .width('100%')
            .fontSize(14)
            .lineHeight(21)
            .fontColor(this.inkColor())
            .maxLines(this.reviewLineCount())
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }

        if (this.featured && this.data.tags.length > 0) {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.data.tags.slice(0, this.marketStyle ? 1 : 3), (tag: string) => {
              Column() {
                FoodTag({ label: tag, marketStyle: this.marketStyle });
              }.margin({ right: 6, bottom: 6 });
            }, (tag: string, index: number): string => `${tag}-${index}`)
          }
          .width('100%');
        }

        if (this.metadataText().length > 0 && !this.marketStyle) {
          Text(this.metadataText())
            .width('100%')
            .fontSize(12)
            .fontColor(this.mutedColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
        if (this.marketStyle && this.featured) {
          EvidenceBadge({ label: this.data.evidenceLabel, tone: this.data.evidenceTone, marketStyle: true });
        }
      }.width('100%').padding(this.marketStyle ? 10 : 0)
    }
    .width('100%')
    .padding(this.marketStyle ? 0 : 12)
    .backgroundColor(this.surfaceColor())
    .border({ width: this.marketStyle ? 1.2 : 1, color: this.marketStyle ? $r('app.color.discovery_line') : $r('app.color.line'),
      style: this.marketStyle ? BorderStyle.Dashed : BorderStyle.Solid })
    .borderRadius(this.marketStyle ? 16 : 20).clip(this.marketStyle)
    .clickEffect({ level: this.motionEnabled ? ClickEffectLevel.MIDDLE : ClickEffectLevel.LIGHT, scale: this.motionEnabled ? this.marketStyle ? 0.985 : 0.98 : 1 })
    .accessibilityGroup(true)
    .accessibilityRole(AccessibilityRoleType.BUTTON)
    .accessibilityText(this.accessibilitySummary())
    .accessibilityDescription('轻点查看实拍卡详情')
    .onClick((): void => {
      this.onOpen(this.data.id);
    });
  }
}
