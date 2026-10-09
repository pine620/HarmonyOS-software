import { common } from '@kit.AbilityKit';
import { ImageRepository } from '../../service/ImageRepository';
export type EvidenceTone = 'verified' | 'assisted' | 'pending';

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

@Component
export struct FoodTag {
  @Prop label: string = '';
  @Prop selected: boolean = false;

  build() {
    Text(this.label.length > 0 ? this.label : '未分类')
      .fontSize(12)
      .fontWeight(this.selected ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.selected ? $r('app.color.on_accent_action') : $r('app.color.ink'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor(this.selected ? $r('app.color.accent_action') : $r('app.color.accent_soft'))
      .border({ width: this.selected ? 2 : 1, color: this.selected
        ? $r('app.color.on_accent_action') : $r('app.color.line') })
      .borderRadius(14)
      .accessibilityText(`${this.label.length > 0 ? this.label : '未分类'}标签` +
        `${this.selected ? '，已选中' : ''}`);
  }
}

@Component
export struct PriceBadge {
  @Prop priceText: string = '价格待补充';
  @Prop originalPriceText: string = '';

  build() {
    Row({ space: 6 }) {
      Text(this.priceText)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent_action'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
      if (this.originalPriceText.length > 0) {
        Text(`原价 ${this.originalPriceText}`)
          .width('42%')
          .fontSize(12)
          .fontColor($r('app.color.muted'))
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

@Component
export struct EvidenceBadge {
  @Prop label: string = '待确认';
  @Prop tone: EvidenceTone = 'pending';

  private textColor(): Resource {
    if (this.tone === 'verified') return $r('app.color.leaf');
    if (this.tone === 'assisted') return $r('app.color.accent_action');
    return $r('app.color.warning');
  }

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
      .backgroundColor($r('app.color.surface'))
      .border({ width: 1, color: this.textColor() })
      .borderRadius(12)
      .accessibilityText(`${this.label.length > 0 ? this.label : '待确认'}，${this.description()}`);
  }
}

@Component
export struct ReviewCard {
  @Prop @Watch('onDataChanged') data: ReviewCardViewData = emptyReviewCardViewData();
  @Prop featured: boolean = false;
  @Prop coverScale: number = 1;
  onOpen: (id: string) => void = (_id: string): void => {};
  @State nativeCoverFailed: string = '';
  onCoverFailed: () => void = (): void => {};
  onCoverDecoded: (id: string, url: string) => void = (_id: string, _url: string): void => {};

  private onDataChanged(): void {
    if (this.data.coverUrl.length === 0 || this.data.coverLoading || this.data.coverUrl !== this.nativeCoverFailed) this.nativeCoverFailed = '';
  }

  private decodeSize(): ImageSourceSize {
    const size: ImageSourceSize = { width: 180 * this.coverScale, height: this.photoHeight() };
    return size;
  }
  private photoHeight(): number {
    return Math.round((this.featured ? 224 : 142) * this.coverScale);
  }

  private reviewLineCount(): number {
    return this.featured ? 3 : 2;
  }

  private coverStatusText(): string {
    if (this.data.coverLoading) return '正在加载实拍图';
    if (this.data.coverFailed) return '实拍图暂时不可用';
    return '暂无实拍图';
  }

  private coverDescription(): string {
    if (this.data.coverLoading) return '图片就绪后将自动显示';
    if (this.data.coverFailed) return '可稍后刷新推荐再试';
    return '商品信息仍可查看';
  }

  private metadataText(): string {
    const parts: Array<string> = [];
    if (this.data.authorName.length > 0) parts.push(this.data.authorName);
    if (this.data.timeLabel.length > 0) parts.push(this.data.timeLabel);
    if (this.data.locationLabel.length > 0) parts.push(this.data.locationLabel);
    return parts.join(' · ');
  }

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

  build() {
    Column({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        if (this.data.coverUrl.length > 0 && this.nativeCoverFailed !== this.data.coverUrl) {
          Image(this.data.coverUrl)
            .width('100%')
            .height(this.photoHeight())
            .objectFit(ImageFit.Contain)
            .autoResize(true).syncLoad(false).sourceSize(this.decodeSize())
            .borderRadius(18)
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
              .fontColor($r('app.color.ink'));
            Text(this.coverDescription())
              .fontSize(12)
              .fontColor($r('app.color.muted'));
          }
          .width('100%')
          .height(this.photoHeight())
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.accent_soft'))
          .borderRadius(16)
          .accessibilityText(this.data.productName + '，' + this.coverStatusText());
        }

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
      .width('100%');

      Row({ space: 8 }) {
        Text(this.data.productName)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.ink'))
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        if (this.featured) {
          EvidenceBadge({ label: this.data.evidenceLabel, tone: this.data.evidenceTone });
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top);

      if (this.data.shop.length > 0) {
        Text(this.data.shop)
          .width('100%')
          .fontSize(12)
          .fontColor($r('app.color.muted'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }

      PriceBadge({ priceText: this.data.priceText, originalPriceText: this.data.originalPriceText });

      if (this.data.tasteScoreText.length > 0) {
        Text('口味 ' + this.data.tasteScoreText)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent_action'))
          .padding({ left: 8, right: 8, top: 5, bottom: 5 })
          .backgroundColor($r('app.color.accent_soft'))
          .borderRadius(10)
          .accessibilityText('口味评分 ' + this.data.tasteScoreText);
      }

      if (this.data.reviewSummary.length > 0) {
        Text(this.data.reviewSummary)
          .width('100%')
          .fontSize(14)
          .lineHeight(21)
          .fontColor($r('app.color.ink'))
          .maxLines(this.reviewLineCount())
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }

      if (this.featured && this.data.tags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(this.data.tags.slice(0, 3), (tag: string) => {
            Column() {
              FoodTag({ label: tag });
            }.margin({ right: 6, bottom: 6 });
          }, (tag: string, index: number): string => `${tag}-${index}`)
        }
        .width('100%');
      }

      if (this.metadataText().length > 0) {
        Text(this.metadataText())
          .width('100%')
          .fontSize(12)
          .fontColor($r('app.color.muted'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line') })
    .borderRadius(20)
    .clickEffect({ level: ClickEffectLevel.MIDDLE, scale: 0.98 })
    .accessibilityGroup(true)
    .accessibilityRole(AccessibilityRoleType.BUTTON)
    .accessibilityText(this.accessibilitySummary())
    .accessibilityDescription('轻点查看实拍卡详情')
    .onClick((): void => {
      this.onOpen(this.data.id);
    });
  }
}
