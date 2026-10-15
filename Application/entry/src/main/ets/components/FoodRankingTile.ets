import { PersonalPreviewRow } from '../service/PersonalPreviewLoader';

@Component
export struct FoodRankingTile {
  @ObjectLink row: PersonalPreviewRow;
  @Prop rank: number = 0;
  @Prop merchantName: string = '';
  @Prop busy: boolean = false;
  @Prop photoSize: number = 84;
  @Prop largeText: boolean = false;
  onOpen: (cardId: string) => void = (_cardId: string): void => {};
  private photoLabel(): string {
    if (this.row.card === undefined || this.row.state === 'UNAVAILABLE') return '暂不可访问';
    if (this.row.state === 'ERROR') return '图片未加载';
    return this.row.state === 'NO_IMAGE' ? '暂无图片' : '加载中';
  }
  private topRank(): boolean { return this.rank >= 1 && this.rank <= 3; }
  // Rows after the podium stay pictured but slightly smaller, so the top three read first.
  private resolvedPhotoSize(): number { return this.topRank() ? this.photoSize : Math.round(this.photoSize * 0.78); }
  private score(): string { return this.row.card === undefined ? '—' : this.row.card.tasteScore.toString(); }
  private rankBackground(): ResourceColor {
    if (this.rank === 1) return $r('app.color.food_ranking_rank_top');
    if (this.rank === 2) return $r('app.color.food_ranking_rank_second');
    if (this.rank === 3) return $r('app.color.food_ranking_rank_third');
    return $r('app.color.food_ranking_rank');
  }
  private accessibleLabel(): string {
    if (this.row.card === undefined) return '第 ' + this.rank.toString() + ' 名，卡片暂不可访问';
    return '第 ' + this.rank.toString() + ' 名，' + this.row.card.productName +
      '，' + (this.merchantName.length > 0 ? this.merchantName + '，' : '') +
      (this.row.card.authorNickname || '食刻用户') + '推荐，口味 ' + this.score() + ' 分，打开详情';
  }
  @Builder private photo() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.row.state === 'READY' && this.row.card !== undefined && this.row.card.photoUrl.length > 0) {
        Image(this.row.card.photoUrl).width(this.resolvedPhotoSize()).height(this.resolvedPhotoSize()).objectFit(ImageFit.Cover)
          .borderRadius(10).onError((): void => { this.row.state = 'ERROR'; });
      } else {
        Column({ space: 4 }) {
          Image($r('app.media.ic_service_card_photo')).width(28).height(28);
          Text(this.photoLabel()).fontSize(11).maxFontScale(1.3)
            .fontColor($r('app.color.food_ranking_muted')).textAlign(TextAlign.Center).maxLines(2);
        }.width(this.resolvedPhotoSize()).height(this.resolvedPhotoSize()).padding(4).justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.food_ranking_placeholder')).borderRadius(10);
      }
      if (this.topRank()) {
        // Podium ranks use a hand-stamped seal: dashed ring, slightly tilted.
        Text(this.rank.toString()).fontSize(15).maxFontScale(1.4).fontWeight(FontWeight.Bold).maxLines(1)
          .width(30).height(30).textAlign(TextAlign.Center).offset({ x: -4, y: -4 })
          .fontColor($r('app.color.food_ranking_accent')).backgroundColor($r('app.color.food_ranking_surface'))
          .borderRadius(15).border({ width: 1.6, color: $r('app.color.food_ranking_accent'), style: BorderStyle.Dashed })
          .rotate({ angle: -8 });
      } else {
        Text(this.rank.toString()).fontSize(13).maxFontScale(1.4).fontWeight(FontWeight.Bold).maxLines(1)
          .constraintSize({ minWidth: 26, minHeight: 20 }).padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .textAlign(TextAlign.Center)
          .fontColor($r('app.color.food_ranking_rank_text'))
          .backgroundColor(this.rankBackground()).borderRadius(6)
          .border({ width: 1, color: $r('app.color.food_ranking_surface') });
      }
    }.width(this.resolvedPhotoSize()).height(this.resolvedPhotoSize()).accessibilityLevel('no-hide-descendants');
  }
  @Builder private scoreNumber() {
    Row({ space: 2 }) {
      Text(this.score()).fontSize(26).maxFontScale(1.4).fontWeight(FontWeight.Bold).maxLines(1)
        .fontColor($r('app.color.food_ranking_accent'));
      Text('分').fontSize(13).maxFontScale(1.4).fontColor($r('app.color.food_ranking_accent')).margin({ bottom: 3 });
    }.alignItems(VerticalAlign.Bottom);
  }
  build() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: 12 }) {
        this.photo();
        Column({ space: 4 }) {
          Text(this.row.card?.productName || '卡片暂不可访问').fontSize(this.topRank() ? 17 : 15).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.food_ranking_ink')).maxLines(this.largeText ? 3 : 2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%');
          if (this.merchantName.trim().length > 0) {
            Text(this.merchantName).fontSize(13).fontColor($r('app.color.food_ranking_muted'))
              .maxLines(this.largeText ? 2 : 1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%');
          }
          Text((this.row.card?.authorNickname || '食刻用户') + '推荐').fontSize(12)
            .fontColor($r('app.color.food_ranking_muted')).maxLines(this.largeText ? 2 : 1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%');
          if (this.largeText) {
            Row({ space: 6 }) {
              Text('口味').fontSize(12).maxFontScale(1.4).fontColor($r('app.color.food_ranking_muted'));
              this.scoreNumber();
            }.padding({ left: 10, right: 10, top: 4, bottom: 4 }).margin({ top: 4 })
              .backgroundColor($r('app.color.food_ranking_score_surface')).borderRadius(10)
              .alignItems(VerticalAlign.Center);
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
        if (!this.largeText) {
          Column({ space: 2 }) {
            this.scoreNumber();
            Text('口味').fontSize(12).maxFontScale(1.4).fontColor($r('app.color.food_ranking_muted'));
          }.constraintSize({ minWidth: 56 }).padding({ left: 8, right: 8, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.food_ranking_score_surface')).borderRadius(12)
            .alignItems(HorizontalAlign.Center);
        }
      }.width('100%').alignItems(this.largeText ? VerticalAlign.Top : VerticalAlign.Center);
    }.width('100%').padding(8).backgroundColor($r('app.color.food_ranking_surface')).borderRadius(14)
      .border({ width: this.topRank() ? 1.4 : 1, color: this.topRank() ? $r('app.color.food_ranking_accent') :
        $r('app.color.food_ranking_line'), style: BorderStyle.Dashed })
      .constraintSize({ minHeight: this.topRank() ? 100 : 80 }).enabled(!this.busy && this.row.card !== undefined)
      .accessibilityGroup(true).accessibilityText(this.accessibleLabel())
      .onClick((): void => this.onOpen(this.row.cardId));
  }
}
