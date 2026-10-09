import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { MerchantRankingRequest, MerchantRankingPage } from '../model/SocialDiscoveryModels';
import { SocialDiscoveryRepository } from '../repository/SocialDiscoveryRepository';
import { LocationService } from '../service/LocationService';
import { MapViewportStore } from '../service/MapViewportStore';
import { AuthService } from '../service/AuthService';
import { ChoiceActionStyle, QuietActionStyle, SecondaryActionStyle, featureUnavailable, stage47ErrorText } from '../common/Stage47Ui';
@Component
export struct RankingPage {
  @StorageLink('accountContentRevision') @Watch('onAccountChanged') accountContentRevision: number = 0;
  private onAccountChanged(): void { this.cards = []; this.cursor = ''; this.latitude = MapViewportStore.defaults().latitude; this.longitude = MapViewportStore.defaults().longitude; this.centerSource = 'DEFAULT'; this.generation++; if (this.active) void this.load(); }
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  private visibleLifecycle: boolean = true;
  private onAppActiveChanged(): void { if (!this.appActive) this.aboutToDisappear(); else if (this.visibleLifecycle) this.aboutToAppear(); }
  private onVisibilityChanged(visible: boolean): void { if (visible === this.visibleLifecycle) return; this.visibleLifecycle = visible; if (visible && this.appActive) this.aboutToAppear(); else this.aboutToDisappear(); }
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  onOpenRecommendations: () => void = (): void => {};
  @Prop @Watch('reload') revision: number = 0;
  @StorageLink('friendRelationshipRevision') @Watch('reload') relationshipRevision: number = 0;
  @State cards: Array<FoodCard> = []; @State kind: 'HIGH_SCORE' | 'FRIENDS' = 'HIGH_SCORE';
  @State cursor: string = ''; @State message: string = '使用默认中心，未主动定位。'; @State busy: boolean = false;
  @State loadFailed: boolean = false;
  @State featureNotReady: boolean = false;
  private latitude: number = MapViewportStore.defaults().latitude;
  private longitude: number = MapViewportStore.defaults().longitude;
  private centerSource: string = 'DEFAULT'; private generation: number = 0; private active: boolean = true;
  private repo: SocialDiscoveryRepository = new SocialDiscoveryRepository();
  aboutToAppear(): void { this.active = true; void this.load(); }
  aboutToDisappear(): void { this.active = false; this.generation++; this.cards = []; this.latitude = MapViewportStore.defaults().latitude; this.longitude = MapViewportStore.defaults().longitude; this.centerSource = 'DEFAULT'; }
  private reload(): void { this.cards = []; this.cursor = ''; if (this.active) void this.load(); }
  private async load(more: boolean = false): Promise<void> {
    const generation: number = ++this.generation; this.busy = true;
    this.loadFailed = false; this.featureNotReady = false;
    try { if (this.kind === 'FRIENDS' && AuthService.profile() === undefined) throw new Error('好友榜需登录。');
      const request: MerchantRankingRequest = { kind: this.kind, lat: this.latitude, lon: this.longitude, coordinateSystem: 'GCJ02', centerSource: this.centerSource, cursor: more ? this.cursor : '' };
      const result: MerchantRankingPage = await this.repo.ranking(request); if (!this.active || generation !== this.generation) return;
      this.cards = more ? this.cards.concat(result.cards.filter((c: FoodCard): boolean => !this.cards.some((r: FoodCard): boolean => r.id === c.id))) : result.cards;
      this.cursor = result.nextCursor; this.message = this.cards.length === 0 ? '当前范围暂无推荐。' :
        '已找到 ' + this.cards.length.toString() + ' 条推荐' + (this.cursor.length > 0 ? '，可继续加载。' : '。') + (result.coverage !== 'COMPLETE' ? ' 当前有界结果未覆盖全部卡片。' : '');
    } catch (error) { if (generation === this.generation) { this.cards = []; this.cursor = ''; this.loadFailed = true; this.featureNotReady = featureUnavailable(error as Object); this.message = stage47ErrorText(error as Object, '榜单加载失败。'); } }
    finally { if (generation === this.generation) this.busy = false; }
  }
  private async locate(): Promise<void> { const generation: number = ++this.generation; this.busy = true; try {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const point = await LocationService.getMapLocation(context); if (!this.active || generation !== this.generation) return; this.latitude = point.latitude; this.longitude = point.longitude; this.centerSource = 'LOCATION'; await this.load();
  } catch (error) { if (generation === this.generation) { this.latitude = MapViewportStore.defaults().latitude; this.longitude = MapViewportStore.defaults().longitude; this.centerSource = 'DEFAULT'; this.message = stage47ErrorText(error as Object, '定位未授权。') + ' 使用默认中心。'; await this.load(); } } finally { if (generation === this.generation) this.busy = false; } }

  @Builder
  private resultState() {
    Column({ space: 12 }) {
      if (this.busy) {
        LoadingProgress().width(36).height(36).color($r('app.color.accent_action'))
        Text('正在加载榜单').fontSize(16).fontColor($r('app.color.ink'))
      } else {
        Text(this.featureNotReady ? '榜单暂未开放' : this.loadFailed ? '榜单暂时加载失败' : '附近暂无推荐')
          .fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink'))
        Text(this.message)
          .fontSize(14).lineHeight(21).textAlign(TextAlign.Center).fontColor($r('app.color.muted')).width('100%')
        if (this.featureNotReady) {
          Button('返回推荐').attributeModifier(new SecondaryActionStyle()).height(48)
            .onClick((): void => this.onOpenRecommendations())
        } else if (this.loadFailed) {
          Button('重新加载').attributeModifier(new SecondaryActionStyle()).height(48)
            .onClick((): void => { void this.load(); })
        }
      }
    }.width('100%').padding({ left: 24, right: 24, top: 32, bottom: 32 })
      .backgroundColor($r('app.color.surface')).borderRadius(18)
      .border({ width: 1, color: $r('app.color.line') }).margin({ top: 12 })
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Row({ space: 8 }) {
          Text('榜单').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).layoutWeight(1)
          Button('刷新').attributeModifier(new QuietActionStyle()).height(48).enabled(!this.busy)
            .onClick((): void => { void this.load(); })
        }.width('100%')
        Text('发现附近的口味高分').fontSize(13).fontColor($r('app.color.muted'))
        Row({ space: 8 }) {
          Button('高评分').attributeModifier(new ChoiceActionStyle(this.kind === 'HIGH_SCORE'))
            .height(48).layoutWeight(1).enabled(!this.busy).onClick((): void => {
              if (this.kind !== 'HIGH_SCORE') { this.kind = 'HIGH_SCORE'; this.reload(); }
            })
          Button('当前好友').attributeModifier(new ChoiceActionStyle(this.kind === 'FRIENDS'))
            .height(48).layoutWeight(1).enabled(!this.busy).onClick((): void => {
              if (this.kind !== 'FRIENDS') { this.kind = 'FRIENDS'; this.reload(); }
            })
        }.width('100%')
        Row({ space: 8 }) {
          Text((this.centerSource === 'DEFAULT' ? '默认中心' : '本次定位') + ' · 20 km')
            .fontSize(13).fontColor($r('app.color.muted')).layoutWeight(1)
          Button('重新定位').attributeModifier(new QuietActionStyle()).height(48)
            .enabled(!this.busy && !this.featureNotReady).onClick((): void => { void this.locate(); })
        }.width('100%')
        Divider().color($r('app.color.line'))
        if (this.cards.length === 0) { this.resultState(); }
        else {
          Text(this.message).fontSize(13).fontColor($r('app.color.muted'))
          ForEach(this.cards, (card: FoodCard): void => {
            Button() {
              Column({ space: 8 }) {
                Row({ space: 12 }) {
                  Text(card.productName).fontSize(16).fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.ink')).layoutWeight(1)
                  Text(card.tasteScore.toString() + ' 分').fontSize(14).fontColor($r('app.color.leaf'))
                }.width('100%')
                if (card.visibility === 'FRIENDS') {
                  Text('仅好友可见').fontSize(12).fontColor($r('app.color.muted'))
                }
              }.width('100%').alignItems(HorizontalAlign.Start)
            }.attributeModifier(new SecondaryActionStyle()).width('100%')
              .padding(16).onClick((): void => this.onOpenCard(card))
          }, (card: FoodCard): string => card.id)
        }
        if (this.cursor.length > 0) {
          Button(this.busy ? '加载中…' : '继续加载').attributeModifier(new SecondaryActionStyle())
            .width('100%').height(48).enabled(!this.busy).onClick((): void => { void this.load(true); })
        }
        Text('评分优先 · 点赞与踩不参与排序').fontSize(12).fontColor($r('app.color.muted'))
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 24 }).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').align(Alignment.TopStart).backgroundColor($r('app.color.canvas'))
      .onVisibleAreaChange([0, 1], (_visible: boolean, ratio: number): void => this.onVisibilityChanged(ratio > 0))
  }
}
