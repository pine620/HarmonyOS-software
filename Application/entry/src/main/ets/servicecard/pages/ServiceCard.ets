import { SERVICE_CARD_REFRESH_MESSAGE } from '../../service/ServiceCardInteraction';

const serviceCardStorage = new LocalStorage();

@Entry(serviceCardStorage)
@Component
struct ServiceCard {
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('cardId') cardId: string = '';
  @LocalStorageProp('productName') productName: string = '附近值得一试';
  @LocalStorageProp('scoreText') scoreText: string = '实拍推荐';
  @LocalStorageProp('priceText') priceText: string = '打开食刻发现好味道';
  @LocalStorageProp('locationText') locationText: string = '20 km 内';
  @LocalStorageProp('categoryText') categoryText: string = '附近';

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Image($r('app.media.app_icon')).width(32).height(32).borderRadius(10)
          .accessibilityLevel('no')
        Column({ space: 1 }) {
          Text('食刻推荐').fontSize(15).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink')).width('100%')
          Text(`${this.categoryText} · ${this.locationText}`).fontSize(11)
            .fontColor($r('app.color.leaf')).width('100%').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')

      Text(this.productName).fontSize(19).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.ink')).width('100%').maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Row({ space: 8 }) {
        Text(this.scoreText).fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_accent_action'))
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor($r('app.color.accent_action')).borderRadius(12)
        Text(this.priceText).fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent_action')).layoutWeight(1).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%')

      Row({ space: 8 }) {
        Button('刷新')
          .layoutWeight(1).height(48).fontSize(12).fontWeight(FontWeight.Medium)
          .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent_action'))
          .border({ width: 1, color: $r('app.color.line') })
          .accessibilityText('刷新桌面推荐摘要')
          .accessibilityDescription('使用设备本地已缓存的公开推荐重新绘制卡片，不访问网络')
          .onClick((): void => {
            postCardAction(this, {
              action: 'message',
              params: { message: SERVICE_CARD_REFRESH_MESSAGE }
            });
          })
        Button('打开')
          .layoutWeight(1).height(48).fontSize(12).fontWeight(FontWeight.Bold)
          .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
          .accessibilityText(this.cardId.length > 0 ? '打开这份真实推荐' : '打开附近真实推荐')
          .onClick((): void => {
            postCardAction(this, {
              action: 'router',
              bundleName: 'com.wyq.shike',
              abilityName: 'EntryAbility',
              params: {
                shikeRoute: this.cardId.length > 0 ? 'card' : 'tab',
                shikeCardId: this.cardId,
                shikeTab: '0'
              }
            });
          })
      }.width('100%').height(48)
    }
    .width('100%').height('100%').padding(16)
    .backgroundColor($r('app.color.surface')).borderRadius(24)
  }
}
