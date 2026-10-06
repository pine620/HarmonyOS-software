import { FoodCard } from '../model/CloudContracts';
import { MapMerchant } from '../model/DiscoveryModels';
import { DiscoveryCard } from './DiscoveryCard';

@Component
export struct MerchantRecommendationSheet {
  @Require @Prop merchant: MapMerchant;
  @Prop cards: Array<FoodCard> = [];
  @Prop status: string = '';
  @Prop loading: boolean = false;
  @Prop nextCursor: string = '';
  onClose: () => void = (): void => {};
  onMore: () => void = (): void => {};
  onRetry: () => void = (): void => {};
  onOpen: (card: FoodCard) => void = (_card: FoodCard): void => {};
  build() {
    Column({ space: 8 }) {
      Row() {
        Text(this.merchant.name).fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).layoutWeight(1)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
        Button('关闭店铺').height(48).fontSize(12).onClick((): void => this.onClose())
          .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.accent_action'));
      }.width('100%')
      Text(this.merchant.address).fontSize(12).fontColor($r('app.color.muted')).maxLines(2).width('100%');
      Text('商家推荐不受当前分类／价格筛选影响').fontSize(12).fontColor($r('app.color.muted')).width('100%');
      Text(this.status).fontSize(12).fontColor($r('app.color.ink')).width('100%');
      Button('刷新商家推荐').height(48).enabled(!this.loading).onClick((): void => this.onRetry());
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.cards, (card: FoodCard) => {
            Column() { DiscoveryCard({ card, coverUrl: card.photoUrl, onOpen: (): void => this.onOpen(card) }) }.width(164)
          }, (card: FoodCard): string => card.id + ':' + card.photoUrl)
          if (this.nextCursor.length > 0) {
            Button(this.loading ? '加载中…' : '更多推荐').height(48).enabled(!this.loading).onClick((): void => this.onMore());
          }
        }
      }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
    }.width('100%').padding(12).backgroundColor($r('app.color.surface')).borderRadius(18)
      .border({ width: 1, color: $r('app.color.line') })
  }
}
