import { cardPriceText } from '../model/CardPrice';
import { PersonalPreviewRow } from '../service/PersonalPreviewLoader';

@Component
export struct PersonalPreviewTile {
  @ObjectLink row: PersonalPreviewRow;
  @Prop removable: boolean = false;
  @Prop busy: boolean = false;
  onOpen: (cardId: string) => void = (_cardId: string): void => {};
  onRemove: (cardId: string) => void = (_cardId: string): void => {};
  private label(): string {
    if (this.row.state === 'UNAVAILABLE') return '内容暂不可访问';
    if (this.row.card !== undefined) return this.row.card.productName;
    return this.row.state === 'ERROR' ? '预览读取失败' : '正在读取卡片…';
  }
  private photoLabel(): string {
    if (this.row.state === 'UNAVAILABLE') return '不可访问';
    if (this.row.state === 'NO_IMAGE') return '暂无图片';
    if (this.row.state === 'ERROR') return '图片未加载';
    return '加载中';
  }
  build() {
    Row({ space: 4 }) {
      Button() {
        Row({ space: 12 }) {
          if (this.row.card !== undefined && this.row.state === 'READY') {
            Image(this.row.card.photoUrl).width(64).height(64).objectFit(ImageFit.Cover).borderRadius(12)
              .accessibilityLevel('no').onError((): void => { this.row.state = 'ERROR'; });
          } else {
            Column() { Text(this.photoLabel()).fontSize(11).fontColor($r('app.color.muted')).textAlign(TextAlign.Center); }
              .width(64).height(64).backgroundColor($r('app.color.canvas')).borderRadius(12)
              .justifyContent(FlexAlign.Center).accessibilityLevel('no');
          }
          Column({ space: 4 }) {
            Text(this.label()).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink'))
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%');
            if (this.row.card !== undefined) {
              Text(cardPriceText(this.row.card)).fontSize(13).fontColor($r('app.color.action_text'));
              Text(this.row.visitedAt > 0 ? new Date(this.row.visitedAt).toLocaleDateString() : this.row.card.authorNickname || '食刻用户')
                .fontSize(12).fontColor($r('app.color.muted')).maxLines(1);
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start);
          if (!this.removable) { Image($r('app.media.ic_chevron_right')).width(20).height(20).accessibilityLevel('no'); }
        }.width('100%').padding(12);
      }.layoutWeight(1).padding(0).backgroundColor(Color.Transparent)
        .enabled(!this.busy && this.row.card !== undefined)
        .accessibilityText(`${this.label()}，打开详情`).onClick((): void => this.onOpen(this.row.cardId));
      if (this.removable) {
        Button('移除').constraintSize({ minWidth: 48, minHeight: 48 }).fontSize(12)
          .backgroundColor(Color.Transparent).fontColor($r('app.color.muted')).enabled(!this.busy)
          .accessibilityText('移除这条记录').onClick((): void => this.onRemove(this.row.cardId));
      }
    }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(16);
  }
}
