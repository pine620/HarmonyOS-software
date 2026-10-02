import { common } from '@kit.AbilityKit';
import { coverFor } from '../components/FoodCover';
import { cardPriceText } from '../model/CardPrice';
import { FoodCard } from '../model/CloudContracts';
import { CardRepository } from '../repository/CardRepository';

interface FavoritePageError {
  message?: string;
}

@Component
export struct FavoriteCardsPage {
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @State cards: Array<FoodCard> = [];
  @State loading: boolean = false;
  @State loaded: boolean = false;
  @State errorMessage: string = '';
  private repository: CardRepository = new CardRepository();

  private async refresh(): Promise<void> {
    if (this.loading) return;
    this.loading = true;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.cards = await this.repository.myFavoriteCards(context);
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = `收藏加载失败：${(error as FavoritePageError).message || '请稍后重试'}`;
    } finally {
      this.loading = false;
      this.loaded = true;
    }
  }

  @Builder
  private favoriteRow(card: FoodCard) {
    Button() {
      Row({ space: 12 }) {
        Image(card.photoUrl.length > 0 ? card.photoUrl : coverFor(card.category))
          .width(64).height(64).objectFit(ImageFit.Cover).borderRadius(14)
          .accessibilityLevel('no');
        Column({ space: 5 }) {
          Text(card.productName).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ink')).width('100%').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(cardPriceText(card)).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(card.priceFen > 0 ? $r('app.color.accent_action') : $r('app.color.muted'));
          if (card.authorNickname !== undefined && card.authorNickname.length > 0) {
            Text(card.authorNickname).fontSize(12).fontColor($r('app.color.muted'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
        Image($r('app.media.ic_chevron_right')).width(20).height(20).accessibilityLevel('no');
      }.width('100%').padding(12);
    }
    .width('100%').padding(0).backgroundColor($r('app.color.surface'))
    .borderRadius(18).border({ width: 1, color: $r('app.color.line') })
    .accessibilityText(`${card.productName}，${cardPriceText(card)}，打开卡片详情`)
    .onClick((): void => this.onOpenCard(card));
  }

  build() {
    NavDestination() {
      Column({ space: 14 }) {
        Row() {
          Column({ space: 3 }) {
            Text('我的收藏').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
            Text(`已收藏 ${this.cards.length} 张商品卡片`)
              .fontSize(12).fontColor($r('app.color.muted'));
          }.alignItems(HorizontalAlign.Start);
          Blank();
          Button(this.loading ? '刷新中' : '刷新').height(48).enabled(!this.loading)
            .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.accent_action'))
            .onClick((): void => { void this.refresh(); });
        }
        .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(18)
        .border({ width: 1, color: $r('app.color.line') });

        if (this.errorMessage.length > 0) {
          Text(this.errorMessage).fontSize(13).lineHeight(20)
            .fontColor($r('app.color.warning')).width('100%')
            .padding(12).backgroundColor($r('app.color.accent_soft')).borderRadius(14);
        }

        if (!this.loaded || (this.loading && this.cards.length === 0)) {
          Column({ space: 10 }) {
            LoadingProgress().width(36).height(36).color($r('app.color.accent_action'));
            Text('正在加载收藏…').fontSize(13).fontColor($r('app.color.muted'));
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
        } else if (this.cards.length === 0) {
          Column({ space: 12 }) {
            Image($r('app.media.food_other')).width(140).height(140)
              .objectFit(ImageFit.Contain).accessibilityLevel('no');
            Text(this.errorMessage.length > 0 ? '暂时无法加载收藏' : '还没有收藏商品卡片')
              .fontSize(19).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink'));
            Text(this.errorMessage.length > 0 ? '请点击右上角刷新后重试。' : '在卡片详情点击收藏后，它会出现在这里。')
              .fontSize(13).fontColor($r('app.color.muted')).textAlign(TextAlign.Center);
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          .padding(24).backgroundColor($r('app.color.surface')).borderRadius(20)
          .border({ width: 1, color: $r('app.color.line') });
        } else {
          List({ space: 12 }) {
            ForEach(this.cards, (card: FoodCard): void => {
              ListItem() { this.favoriteRow(card); }
            }, (card: FoodCard): string => card.id);
          }.width('100%').layoutWeight(1).edgeEffect(EdgeEffect.Spring);
        }
      }
      .width('100%').height('100%').padding({ left: 20, right: 20, top: 12, bottom: 20 })
      .backgroundColor($r('app.color.canvas')).alignItems(HorizontalAlign.Start);
    }
    .title('我的收藏')
    .onShown((): void => { void this.refresh(); });
  }
}
