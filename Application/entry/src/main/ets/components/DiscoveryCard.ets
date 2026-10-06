import { FoodCard } from '../model/CloudContracts';
import { cardPriceText } from '../model/CardPrice';

@Component
export struct DiscoveryCard {
  @Require @Prop card: FoodCard;
  @Prop coverUrl: string = '';
  @Prop selected: boolean = false;
  onOpen: () => void = (): void => {};
  private merchantLabel(): string {
    const snapshot: string | undefined = this.card.merchantNameSnapshot;
    const name: string = snapshot === undefined || snapshot.length === 0 ? this.card.shop : snapshot;
    const mode: string = this.card.consumptionMode === 'DELIVERY' ? '外卖' : this.card.consumptionMode === 'DINE_IN' ? '到店' : '历史推荐';
    return (name.length > 0 ? name : '未关联店铺') + ' · ' + mode;
  }
  build() {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 5 }) {
        if (this.coverUrl.length > 0) {
          Image(this.coverUrl).width('100%').height(56).objectFit(ImageFit.Cover).borderRadius(9)
            .accessibilityText(this.card.productName + '实拍图');
        } else {
          Text(this.card.primaryPhotoLoadFailed === true ? '实拍图暂不可用' : '实拍图加载中')
            .width('100%').height(56).textAlign(TextAlign.Center).fontSize(12)
            .fontColor($r('app.color.muted')).backgroundColor($r('app.color.accent_soft')).borderRadius(9);
        }
        Text(this.card.productName).fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%');
        Text(this.merchantLabel()).fontSize(12).fontColor($r('app.color.muted'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%');
        Row({ space: 4 }) {
          Text(cardPriceText(this.card, '价格未知')).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.accent_action'))
          .maxLines(2).layoutWeight(1);
          Text('评分 ' + this.card.tasteScore).fontSize(12).fontColor($r('app.color.muted'));
        }.width('100%')
      }.width('100%').padding(8).alignItems(HorizontalAlign.Start)
    }.width('100%').padding(0).backgroundColor($r('app.color.surface')).borderRadius(13)
      .border({ width: this.selected ? 2 : 1, color: this.selected ? $r('app.color.accent_action') : $r('app.color.line') })
      .accessibilityText(this.card.productName + '，' + this.merchantLabel() + '，' + cardPriceText(this.card, '价格未知') + '，评分 ' + this.card.tasteScore)
      .onClick((): void => this.onOpen())
  }
}
