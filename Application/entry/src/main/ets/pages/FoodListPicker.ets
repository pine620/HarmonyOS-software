import { PrimaryActionStyle, SecondaryActionStyle, stage47ErrorText } from '../common/Stage47Ui';
import { FoodList, FoodListsPageResult, FoodListItemRequest } from '../model/FoodListModels';
import { FoodListRepository } from '../repository/FoodListRepository';
@Component
export struct FoodListPicker {
  private generation: number = 0;
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  private onAppActiveChanged(): void { if (!this.appActive) this.aboutToDisappear(); else if (this.visibleLifecycle && this.appActive) this.aboutToAppear(); }
  private visibleLifecycle: boolean = true;
  private onVisibilityChanged(visible: boolean): void { if (this.visibleLifecycle === visible) return; this.visibleLifecycle = visible; if (visible && this.appActive) this.aboutToAppear(); else this.aboutToDisappear(); }
  @StorageLink('accountContentRevision') @Watch('onAccountContentChanged') accountContentRevision: number = 0;
  private onAccountContentChanged(): void { this.aboutToDisappear(); this.lists = []; this.cursor = ''; this.busy = false; if (this.visibleLifecycle && this.appActive) this.aboutToAppear(); }

  @Prop cardId: string = ''; onDone: () => void = (): void => {};
  @State lists: Array<FoodList> = []; @State cursor: string = ''; @State message: string = ''; @State busy: boolean = false;
  private repo: FoodListRepository = new FoodListRepository(); private active: boolean = false;
  aboutToAppear(): void { this.generation++; this.active = true; void this.load(); }
  aboutToDisappear(): void { this.generation++; this.active = false; this.busy = false; this.lists = []; }
  private async load(more: boolean = false): Promise<void> { const generation: number = this.generation; this.busy = true; try { const page: FoodListsPageResult = await this.repo.lists(more ? this.cursor : ''); if (!this.active || generation !== this.generation) return; if (!this.active) return; this.lists = more ? this.lists.concat(page.lists) : [page.systemList].concat(page.lists); this.cursor = page.nextCursor; } catch (error) { if (!this.active || generation !== this.generation) return; if (this.active) this.message = stage47ErrorText(error as Object, '清单加载失败。'); } finally { if (this.active && generation === this.generation) this.busy = false; } }
  private async add(list: FoodList): Promise<void> { const generation: number = this.generation; this.busy = true; try { const request: FoodListItemRequest = { cardId: this.cardId, listId: list.listId, version: list.version }; await this.repo.addCard(request); if (!this.active || generation !== this.generation) return; if (!this.active) return; this.message = '已加入「' + list.name + '」，可继续加入其他清单。'; await this.load(); if (!this.active || generation !== this.generation) return; } catch (error) { if (!this.active || generation !== this.generation) return; if (this.active) this.message = stage47ErrorText(error as Object, '加入失败，请刷新后重试。'); } finally { if (this.active && generation === this.generation) this.busy = false; } }
  build() { Scroll() { Column({ space: 12 }) {
    Text('加入私人清单').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
    Text('同一张卡可加入多个清单。重复加入只保留一个引用。').fontSize(14).lineHeight(21).fontColor($r('app.color.muted'))
    Text(this.message).fontSize(13).lineHeight(20).fontColor($r('app.color.muted'))
    ForEach(this.lists, (list: FoodList): void => { Button(list.name).width('100%').height(48).enabled(!this.busy).onClick((): void => { void this.add(list); }).attributeModifier(new SecondaryActionStyle()); }, (list: FoodList): string => list.listId)
    if (this.cursor.length > 0) { Button('加载更多清单').height(48).enabled(!this.busy).onClick((): void => { void this.load(true); }).attributeModifier(new SecondaryActionStyle()) }
    Button('完成').height(48).onClick((): void => this.onDone()).attributeModifier(new PrimaryActionStyle()).width('100%')
  }.width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(18).border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start) }.width('100%').height('100%').align(Alignment.TopStart).padding(14).backgroundColor($r('app.color.canvas')).onVisibleAreaChange([0, 1], (_visible: boolean, ratio: number): void => this.onVisibilityChanged(ratio > 0)) }
}
