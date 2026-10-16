import { AppDestinationStyle } from '../common/AppPageUi';
import { StateView } from '../common/StateViewUi';
import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { coverFor } from '../components/FoodCover';
import { cardPriceText } from '../model/CardPrice';
import { CardRepository } from '../repository/CardRepository';
import { ErrorDetail, errorText } from '../common/ErrorKit';

// Pack 4.3 (2026-10-15): split out of ProfileSubPages.ets without behaviour changes.

function priceText(card: FoodCard): string {
  return cardPriceText(card);
}

function statusText(card: FoodCard): string {
  return card.status === 'APPROVED' ? '已发布' : '已下架';
}

@Component
export struct MyPublishedPage {
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  onCardsChanged: () => void = (): void => {};
  @State cards: Array<FoodCard> = [];
  @State pendingDeleteCardId: string = '';
  @State status: string = '';
  @State loading: boolean = false;
  @State loaded: boolean = false;
  private repository: CardRepository = new CardRepository();
  private hasBeenShown: boolean = false;

  aboutToAppear(): void {
    void this.refresh();
  }

  private async refresh(): Promise<void> {
    if (this.loading) return;
    this.loading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.cards = await this.repository.myCards(context);
      this.status = '';
    } catch (error) {
      this.status = `商品卡片加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.loading = false;
      this.loaded = true;
    }
  }

  private requestDeleteCard(cardId: string): void {
    this.pendingDeleteCardId = cardId;
    this.status = '删除后卡片将立即隐藏，清理请求会保存在云端，请再次确认。';
  }

  private async deleteCard(cardId: string): Promise<void> {
    if (this.loading) return;
    this.loading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.deleteOwn(context, cardId);
      this.cards = await this.repository.myCards(context);
      this.pendingDeleteCardId = '';
      this.status = '卡片已隐藏，相关数据已进入云端清理流程。';
      this.onCardsChanged();
    } catch (error) {
      this.status = `删除失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.loading = false;
    }
  }

  @Builder
  private cardRow(card: FoodCard) {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Image(card.photoUrl.length > 0 ? card.photoUrl : coverFor(card.category)).width(64).height(64)
          .objectFit(ImageFit.Cover).borderRadius(14).accessibilityLevel('no')
        Column({ space: 5 }) {
          Text(card.productName).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.personal_ink')).width('100%').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(priceText(card)).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(card.priceFen > 0 ? $r('app.color.personal_action') : $r('app.color.personal_muted'))
            .width('100%').maxLines(1)
          Row({ space: 8 }) {
            Text(statusText(card)).fontSize(12)
              .fontColor(card.status === 'APPROVED' ? $r('app.color.leaf') : $r('app.color.danger'))
            if (card.district.length > 0) {
              Text(card.district).fontSize(12).fontColor($r('app.color.personal_muted'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }.width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Image($r('app.media.ic_chevron_right')).width(24).height(24).objectFit(ImageFit.Contain)
          .accessibilityLevel('no')
      }
      .width('100%').accessibilityGroup(true)
      .accessibilityText(`${card.productName}，${priceText(card)}，${statusText(card)}`)
      .accessibilityDescription('点击查看卡片详情')
      .onClick(() => this.onOpenCard(card))

      if (this.pendingDeleteCardId === card.id) {
          Column({ space: 10 }) {
            Text('确认删除这张卡片？内容将立即隐藏。')
              .fontSize(13).lineHeight(20).fontColor($r('app.color.danger')).width('100%')
            Row({ space: 10 }) {
              Button('取消').layoutWeight(1).height(48)
                .backgroundColor($r('app.color.personal_surface')).fontColor($r('app.color.personal_muted'))
                .border({ width: 1, color: $r('app.color.personal_line') })
                .onClick(() => {
                  this.pendingDeleteCardId = '';
                  this.status = '';
                })
              Button('确认删除').layoutWeight(1).height(48).enabled(!this.loading)
                .backgroundColor($r('app.color.danger_action')).fontColor($r('app.color.on_danger_action'))
                .onClick((): void => { void this.deleteCard(card.id); })
            }.width('100%')
          }
          .width('100%').padding(12).backgroundColor($r('app.color.danger_soft')).borderRadius(14)
      } else {
          Row() {
            Blank()
            Button('删除').height(44).fontSize(13)
              .backgroundColor($r('app.color.personal_surface')).fontColor($r('app.color.danger'))
              .border({ width: 1, color: $r('app.color.personal_line') })
              .onClick(() => this.requestDeleteCard(card.id))
          }.width('100%').height(44)
      }
    }
    .width('100%').padding(12).backgroundColor($r('app.color.personal_surface')).borderRadius(18)
    .border({ width: 1, color: $r('app.color.personal_line') })
  }

  build() {
    NavDestination() {
      Column({ space: 14 }) {
        Row() {
          Column({ space: 3 }) {
            Text('我的卡片').fontSize(20).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.personal_ink'))
            Text(`共 ${this.cards.length} 张商品卡片`)
              .fontSize(12).fontColor($r('app.color.personal_muted'))
          }.alignItems(HorizontalAlign.Start)
          Blank()
          Button(this.loading ? '刷新中' : '刷新').height(48).enabled(!this.loading)
            .backgroundColor($r('app.color.personal_soft')).fontColor($r('app.color.personal_action'))
            .onClick((): void => { void this.refresh(); })
        }
        .width('100%').padding(16).backgroundColor($r('app.color.personal_surface')).borderRadius(18)
        .border({ width: 1, color: $r('app.color.personal_line') })

        if (this.status.length > 0) {
          Text(this.status).fontSize(13).lineHeight(20)
            .fontColor(this.status.includes('失败') ? $r('app.color.warning') : $r('app.color.personal_muted'))
            .width('100%').padding(12).backgroundColor($r('app.color.personal_soft')).borderRadius(14)
        }

        if (!this.loaded || (this.loading && this.cards.length === 0)) {
          Column() {
            StateView({ kind: 'LOADING', palette: 'PERSONAL', title: '正在加载我的卡片…', skeletonRows: 3 })
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.cards.length === 0) {
          Column() {
            if (this.status.includes('失败')) {
              StateView({ kind: 'ERROR', palette: 'PERSONAL', icon: 'offline', title: '暂时无法加载卡片',
                hint: '网络恢复后点重试。', actionLabel: '重试', onAction: (): void => { void this.refresh(); } })
            } else {
              StateView({ kind: 'EMPTY', palette: 'PERSONAL', icon: 'card', title: '还没有发布卡片',
                hint: '完成第一张推荐卡后，它会出现在这里。' })
            }
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          List({ space: 12 }) {
            ForEach(this.cards, (card: FoodCard) => {
              ListItem() { this.cardRow(card) }
            }, (card: FoodCard) => card.id)
          }.width('100%').layoutWeight(1).edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%').height('100%').padding({ left: 20, right: 20, top: 12, bottom: 20 })
      .backgroundColor($r('app.color.personal_canvas')).alignItems(HorizontalAlign.Start)
    }.attributeModifier(new AppDestinationStyle('我的卡片', $r('app.color.personal_canvas'), $r('app.color.personal_header'), 'PERSONAL')).onShown((): void => {
      if (this.hasBeenShown) {
        void this.refresh();
      } else {
        this.hasBeenShown = true;
      }
    })
  }
}
