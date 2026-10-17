/**
 * 【文件职责】「今日吃什么」桌面卡片页面（2×2）：显示当前候选菜，点击“换一个”发送翻牌消息，点击菜品打开 App。
 */
import { serviceCardOpenAction } from '../../servicecard/ServiceCardPresentation';

const randomFoodCardStorage: LocalStorage = new LocalStorage();

// 翻牌消息参数。
interface FlipMessageParams {
  message: string;
}

// 翻牌消息动作。
interface FlipMessageAction {
  action: string;
  params: FlipMessageParams;
}

// 必须与 service/RandomFoodWidgetStore.ets 中的 RANDOM_FOOD_WIDGET_FLIP_MESSAGE 一致（卡片页面不能 import 会引入网络代码的应用服务，所以这里重复定义）。
const FLIP_MESSAGE: string = 'flip-random-food-widget';

// 卡片页面（数据由 RandomFoodWidgetStore 绑定）。
@Entry(randomFoodCardStorage)
@Component
struct RandomFoodCard {
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('state') state: string = 'EMPTY';
  @LocalStorageProp('cardId') cardId: string = '';
  @LocalStorageProp('dishName') dishName: string = '';
  @LocalStorageProp('dishMeta') dishMeta: string = '';
  @LocalStorageProp('sourceLabel') sourceLabel: string = '';
  @LocalStorageProp('looped') looped: boolean = false;
  @LocalStorageProp('emptyTitle') emptyTitle: string = '还没有候选菜';
  @LocalStorageProp('emptyHint') emptyHint: string = '打开食刻准备几道菜';
  @LocalStorageProp('coverImageName') @Watch('onCoverChanged') coverImageName: string = '';
  @State private coverFailed: boolean = false;

  // 封面变化时刷新。
  private onCoverChanged(): void {
    this.coverFailed = false;
  }

  // 是否有候选菜。
  private hasDish(): boolean {
    return this.state === 'DISH' && this.cardId.trim().length > 0;
  }

  // 是否有封面。
  private hasCover(): boolean {
    return this.hasDish() && !this.coverFailed && /^shike_food_[0-9a-f_]+$/.test(this.coverImageName);
  }

  // 打开当前菜品。
  private openDish(): void {
    postCardAction(this, serviceCardOpenAction(this.hasDish() ? this.cardId : ''));
  }

  // 翻到下一道。
  private flip(): void {
    const action: FlipMessageAction = { action: 'message', params: { message: FLIP_MESSAGE } };
    postCardAction(this, action);
  }

  // 小标签。
  @Builder
  private chip(text: string) {
    Text(text).fontSize(10).fontWeight(FontWeight.Medium).fontColor('#FFF8EC').maxLines(1)
      .height(20).padding({ left: 7, right: 7 }).borderRadius(10).backgroundColor('#8C14100A')
  }

  // 菜品区域。
  @Builder
  private dish() {
    Column() {
      Button({ type: ButtonType.Normal }) {
        Stack({ alignContent: Alignment.Top }) {
          Column() {}.width('100%').height('100%').backgroundColor($r('app.color.random_soft'))
          if (this.hasCover()) {
            Image(`memory://${this.coverImageName}`).width('100%').height('100%')
              .objectFit(ImageFit.Cover).accessibilityLevel('no')
              .onError((): void => { this.coverFailed = true; })
          }
          Row() {
            this.chip('今天吃什么')
            Blank()
            this.chip(this.sourceLabel)
          }.width('100%').padding({ left: 8, right: 8, top: 8 })
        }.width('100%').height('100%')
      }
      .width('100%').layoutWeight(1).padding(0).borderRadius(0)
      .backgroundColor(Color.Transparent).stateEffect(true)
      .accessibilityText(`${this.dishName}，打开详情`)
      .onClick((): void => this.openDish())

      Row({ space: 6 }) {
        Column({ space: 2 }) {
          Text(this.dishName).fontSize(14).fontWeight(FontWeight.Bold).fontColor($r('app.color.random_ink'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(this.looped ? '这一轮翻完了 · 打开食刻换一批' : this.dishMeta).fontSize(10)
            .fontColor(this.looped ? $r('app.color.random_accent') : $r('app.color.random_muted'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          Column() {
            SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(15)
              .fontColor([$r('app.color.random_on_accent')]).accessibilityLevel('no')
            Text('翻一张').fontSize(8).fontWeight(FontWeight.Bold).fontColor($r('app.color.random_on_accent'))
          }.justifyContent(FlexAlign.Center)
        }
        .width(44).height(44).backgroundColor($r('app.color.random_accent'))
        .accessibilityText('翻一张').onClick((): void => this.flip())
      }
      .width('100%').height(58).padding({ left: 10, right: 8 })
      .border({ width: { top: 1.2 }, color: $r('app.color.random_line'), style: BorderStyle.Dashed })
    }.width('100%').height('100%')
  }

  // 空状态。
  @Builder
  private empty() {
    Column({ space: 6 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.fork_knife')).fontSize(22)
          .fontColor([$r('app.color.random_accent')]).accessibilityLevel('no')
      }.width(44).height(44).borderRadius(22).backgroundColor($r('app.color.random_soft'))
      Text(this.emptyTitle).fontSize(13).fontWeight(FontWeight.Bold).fontColor($r('app.color.random_ink'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Button('打开食刻挑一挑', { type: ButtonType.Capsule, stateEffect: true }).fontSize(11)
        .fontWeight(FontWeight.Bold).fontColor($r('app.color.random_on_accent'))
        .backgroundColor($r('app.color.random_accent')).height(30).padding({ left: 12, right: 12 })
        .accessibilityText(`${this.emptyTitle}，${this.emptyHint}`)
        .onClick((): void => this.openDish())
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).padding(8)
    .borderRadius(18).border({ width: 1.4, color: $r('app.color.random_line'), style: BorderStyle.Dashed })
  }

  // 布局。
  build() {
    Column() {
      if (this.hasDish()) {
        this.dish()
      } else {
        this.empty()
      }
    }
    .width('100%').height('100%').padding(this.hasDish() ? 0 : 6)
    .backgroundColor($r('app.color.random_surface')).borderRadius(24).clip(true)
  }
}
