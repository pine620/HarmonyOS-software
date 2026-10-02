import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { coverFor } from '../components/FoodCover';
import { CardRepository } from '../repository/CardRepository';
import { AuthService } from '../service/AuthService';
import { CardVisit, CardVisitStore } from '../service/CardVisitStore';

interface HistoryError {
  message?: string;
}

function historyDate(timestamp: number): string {
  const date: Date = new Date(timestamp);
  if (!Number.isFinite(date.getTime())) return '';
  const month: number = date.getMonth() + 1;
  const day: number = date.getDate();
  return `${date.getFullYear()}-${month < 10 ? `0${month}` : month.toString()}-${day < 10 ? `0${day}` : day.toString()}`;
}

@Component
export struct CardHistoryPage {
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @State visits: Array<CardVisit> = [];
  @State openingCardId: string = '';
  @State clearPending: boolean = false;
  @State status: string = '';
  private repository: CardRepository = new CardRepository();

  aboutToAppear(): void {
    this.loadVisits();
  }

  private loadVisits(): void {
    const uid: string = AuthService.profile()?.uid || '';
    if (uid.length === 0) {
      this.visits = [];
      this.status = '登录状态已失效，请重新登录。';
      return;
    }
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.visits = CardVisitStore.list(context, uid);
      this.status = '';
    } catch (error) {
      this.status = `浏览记录读取失败：${(error as HistoryError).message || '请稍后重试'}`;
    }
  }

  private async openVisit(visit: CardVisit): Promise<void> {
    if (this.openingCardId.length > 0) return;
    this.openingCardId = visit.cardId;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const card: FoodCard = await this.repository.detail(context, visit.cardId);
      this.status = '';
      this.onOpenCard(card);
    } catch (error) {
      this.status = `卡片暂时无法打开：${(error as HistoryError).message || '请稍后重试'}`;
    } finally {
      this.openingCardId = '';
    }
  }

  private clearVisits(): void {
    const uid: string = AuthService.profile()?.uid || '';
    if (uid.length === 0) return;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      CardVisitStore.clear(context, uid);
      this.visits = [];
      this.status = '本机浏览记录已清空。';
      this.clearPending = false;
    } catch (error) {
      this.status = `清空失败：${(error as HistoryError).message || '请稍后重试'}`;
    }
  }

  build() {
    NavDestination() {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 3 }) {
            Text('浏览记录').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
            Text('只保存在本机，最多保留最近 100 张卡片')
              .fontSize(12).fontColor($r('app.color.muted'));
          }.alignItems(HorizontalAlign.Start);
          Blank();
          if (this.visits.length > 0) {
            Button(this.clearPending ? '取消' : '清空').height(44).fontSize(12)
              .backgroundColor($r('app.color.surface')).fontColor($r('app.color.danger'))
              .onClick((): void => { this.clearPending = !this.clearPending; });
          }
        }.width('100%').padding(14).backgroundColor($r('app.color.surface')).borderRadius(18);
        if (this.clearPending) {
          Column({ space: 8 }) {
            Text('确认清空这台设备上的浏览记录？').fontSize(13)
              .fontColor($r('app.color.ink')).width('100%');
            Button('确认清空').height(44).width('100%')
              .backgroundColor($r('app.color.danger_action')).fontColor($r('app.color.on_danger_action'))
              .onClick((): void => this.clearVisits());
          }.width('100%').padding(12).backgroundColor($r('app.color.danger_soft')).borderRadius(14);
        }
        if (this.status.length > 0) {
          Text(this.status).fontSize(12).fontColor($r('app.color.muted'))
            .width('100%').padding(10);
        }
        if (this.visits.length === 0) {
          Text('还没有浏览记录。打开商品卡片后，会在这里留下足迹。')
            .fontSize(14).fontColor($r('app.color.muted')).textAlign(TextAlign.Center)
            .width('100%').padding(28).backgroundColor($r('app.color.surface')).borderRadius(18);
        } else {
          List({ space: 8 }) {
            ForEach(this.visits, (visit: CardVisit): void => {
              ListItem() {
                Button() {
                  Row({ space: 12 }) {
                    Image(coverFor(visit.category)).width(58).height(58)
                      .objectFit(ImageFit.Cover).borderRadius(12).accessibilityLevel('no');
                    Column({ space: 4 }) {
                      Text(visit.productName).fontSize(15).fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.ink')).maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis });
                      if (visit.priceText.length > 0) {
                        Text(visit.priceText).fontSize(12).fontColor($r('app.color.accent_action'));
                      }
                      Text(historyDate(visit.visitedAt)).fontSize(11).fontColor($r('app.color.muted'));
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start);
                    Image($r('app.media.ic_chevron_right')).width(18).height(18).accessibilityLevel('no');
                  }.width('100%').padding(12);
                }.width('100%').padding(0).backgroundColor($r('app.color.surface'))
                  .borderRadius(16).enabled(this.openingCardId.length === 0)
                  .accessibilityText(`${visit.productName}，${historyDate(visit.visitedAt)}浏览，打开卡片`)
                  .onClick((): void => { void this.openVisit(visit); });
              }
            }, (visit: CardVisit): string => visit.cardId);
          }.width('100%').layoutWeight(1).edgeEffect(EdgeEffect.Spring).scrollBar(BarState.Off);
        }
      }.width('100%').height('100%').padding({ left: 16, right: 16, top: 12, bottom: 20 })
        .backgroundColor($r('app.color.canvas')).alignItems(HorizontalAlign.Start);
    }.title('浏览记录');
  }
}
