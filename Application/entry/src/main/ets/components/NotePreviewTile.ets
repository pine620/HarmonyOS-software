import { PagePaletteName, pageColor } from '../common/PagePaletteUi';
import { cardPriceText } from '../model/CardPrice';
import { PersonalPreviewRow } from '../service/PersonalPreviewLoader';

@Component
export struct NotePreviewTile {
  @Prop palette: PagePaletteName = 'SOCIAL';
  @ObjectLink row: PersonalPreviewRow;
  @Prop busy: boolean = false;
  onOpen: (cardId: string) => void = (_cardId: string): void => {};
  private label(): string {
    if (this.row.state === 'UNAVAILABLE') return '内容暂不可访问';
    return this.row.card === undefined ? '正在读取卡片…' : this.row.card.productName;
  }
  private photoLabel(): string {
    return this.row.state === 'NO_IMAGE' ? '暂无实拍' : this.row.state === 'ERROR' ? '实拍暂不可用' : '正在加载实拍';
  }
  build() {
    Button() {
      Column({ space: 0 }) {
        if (this.row.card !== undefined && this.row.state === 'READY') {
          Image(this.row.card.photoUrl).width('100%').aspectRatio(1).objectFit(ImageFit.Cover)
            .borderRadius({ topLeft: 18, topRight: 18 }).accessibilityLevel('no')
            .onError((): void => { this.row.state = 'ERROR'; });
        } else {
          Column() { Text(this.photoLabel()).fontSize(12).fontColor(pageColor(this.palette, 'muted')).textAlign(TextAlign.Center); }
            .width('100%').aspectRatio(1).backgroundColor(pageColor(this.palette, 'soft')).justifyContent(FlexAlign.Center);
        }
        Column({ space: 6 }) {
          Text(this.label()).fontSize(15).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'ink'))
            .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
          if (this.row.card !== undefined) {
            Text(cardPriceText(this.row.card)).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(pageColor(this.palette, 'action')).width('100%').maxLines(2);
          }
        }.width('100%').padding(12).alignItems(HorizontalAlign.Start);
      }.width('100%');
    }.type(ButtonType.Normal).width('100%').padding(0).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(18)
      .constraintSize({ minHeight: 48 }).enabled(!this.busy && this.row.card !== undefined && this.row.state !== 'UNAVAILABLE')
      .accessibilityText(this.label() + '，打开详情').onClick((): void => this.onOpen(this.row.cardId));
  }
}
