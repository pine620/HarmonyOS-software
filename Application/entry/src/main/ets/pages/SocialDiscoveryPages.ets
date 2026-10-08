import { DangerActionStyle, QuietActionStyle, SecondaryActionStyle, stage47ErrorText } from '../common/Stage47Ui';
import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { MealHistoryPage, MealHistoryItem } from '../model/MealModels';
import { LocalDraft } from '../model/DraftModels';
import { MealRepository } from '../repository/MealRepository';
import { DraftStore } from '../service/DraftStore';
import { AuthService } from '../service/AuthService';
@Component
export struct MealHistoryPageView {
  private generation: number = 0;
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  private onAppActiveChanged(): void { if (!this.appActive) this.aboutToDisappear(); else if (this.visibleLifecycle && this.appActive) this.aboutToAppear(); }
  private visibleLifecycle: boolean = true;
  private onVisibilityChanged(visible: boolean): void { if (this.visibleLifecycle === visible) return; this.visibleLifecycle = visible; if (visible && this.appActive) this.aboutToAppear(); else this.aboutToDisappear(); }
  @StorageLink('accountContentRevision') @Watch('onAccountContentChanged') accountContentRevision: number = 0;
  private onAccountContentChanged(): void { this.aboutToDisappear(); this.items = []; this.cursor = ''; if (this.visibleLifecycle && this.appActive) this.aboutToAppear(); }

  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @State items: Array<MealHistoryItem> = []; @State cursor: string = ''; @State message: string = '';
  private repo: MealRepository = new MealRepository(); private active: boolean = true;
  aboutToAppear(): void { this.generation++; this.active = true; void this.load(); } aboutToDisappear(): void { this.generation++; this.active = false; this.items = []; }
  private async load(more: boolean = false): Promise<void> { const generation: number = this.generation; try { const r: MealHistoryPage = await this.repo.history(more ? this.cursor : ''); if (!this.active || generation !== this.generation) return; if (this.active) { this.items = more ? this.items.concat(r.items) : r.items; this.cursor = r.nextCursor; } } catch (error) { if (!this.active || generation !== this.generation) return; this.message = stage47ErrorText(error as Object, '历史加载失败。'); } }
  build() { Scroll() { Column({ space: 12 }) {
    Text('我的选餐历史').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
    Text('历史只供查看，不参与推荐学习。').fontSize(14).lineHeight(21).fontColor($r('app.color.muted'))
    Text(this.message).fontSize(13).lineHeight(20).fontColor($r('app.color.muted'))
    ForEach(this.items, (item: MealHistoryItem): void => { Button(new Date(item.selectedAt).toLocaleString() + ' · ' + (item.card === null ? '该内容已不可访问' : item.card.productName)).height(64).enabled(item.card !== null).onClick((): void => { const card: FoodCard | null = item.card; if (card !== null) this.onOpenCard(card); }).attributeModifier(new SecondaryActionStyle()); }, (item: MealHistoryItem): string => item.historyId)
    if (this.cursor.length > 0) { Button('加载更多').height(48).onClick((): void => { void this.load(true); }).attributeModifier(new SecondaryActionStyle()) }
  }.width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(18).border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start) }.width('100%').height('100%').align(Alignment.TopStart).padding(14).backgroundColor($r('app.color.canvas')).onVisibleAreaChange([0, 1], (_visible: boolean, ratio: number): void => this.onVisibilityChanged(ratio > 0)) }
}
@Component
export struct DraftsPage {
  private generation: number = 0;
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  private onAppActiveChanged(): void { if (!this.appActive) this.aboutToDisappear(); else if (this.visibleLifecycle && this.appActive) this.aboutToAppear(); }
  private visibleLifecycle: boolean = true;
  private onVisibilityChanged(visible: boolean): void { if (this.visibleLifecycle === visible) return; this.visibleLifecycle = visible; if (visible && this.appActive) this.aboutToAppear(); else this.aboutToDisappear(); }
  @StorageLink('accountContentRevision') @Watch('onAccountContentChanged') accountContentRevision: number = 0;
  private onAccountContentChanged(): void { this.aboutToDisappear(); this.drafts = []; if (this.visibleLifecycle && this.appActive) this.aboutToAppear(); }

  onRestore: (draft: LocalDraft) => void = (_draft: LocalDraft): void => {};
  @State drafts: Array<LocalDraft> = []; @State message: string = '';
  private active: boolean = true;
  private context(): common.Context { return this.getUIContext().getHostContext() as common.Context; }
  aboutToAppear(): void { this.generation++; this.active = true; void this.load(); } aboutToDisappear(): void { this.generation++; this.active = false; this.drafts = []; }
  private async load(): Promise<void> { const generation: number = this.generation; const profile = AuthService.profile(); if (profile === undefined) return; try { const rows: Array<LocalDraft> = await DraftStore.list(this.context(), profile.uid); if (!this.active || generation !== this.generation) return; if (this.active) this.drafts = rows; const count: number = await DraftStore.reminders(this.context(), profile.uid); if (!this.active || generation !== this.generation) return; if (count > 0) this.message = count.toString() + ' 个草稿将在 3 天内过期，请及时处理。'; } catch (error) { if (!this.active || generation !== this.generation) return; this.message = stage47ErrorText(error as Object, '草稿加载失败。'); } }
  private async remove(draft: LocalDraft): Promise<void> { const generation: number = this.generation; try { await DraftStore.remove(this.context(), draft.ownerUid, draft.draftId); if (!this.active || generation !== this.generation) return; await this.load(); if (!this.active || generation !== this.generation) return; } catch (error) { if (!this.active || generation !== this.generation) return; this.message = stage47ErrorText(error as Object, '删除失败。'); } }
  build() { Scroll() { Column({ space: 12 }) {
    Text('本机草稿箱').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
    Text('新发布与编辑合计最多 10 个；30 天未编辑清理。草稿按账号隔离。').fontSize(14).lineHeight(21).fontColor($r('app.color.muted'))
    Text(this.message).fontSize(13).lineHeight(20).fontColor($r('app.color.muted'))
    ForEach(this.drafts, (draft: LocalDraft): void => { Row({ space: 8 }) { Button((draft.draftType === 'EDIT' ? '编辑 · ' : '新建 · ') + (draft.form.productName || '未命名')).height(64).layoutWeight(1).onClick((): void => this.onRestore(draft)).attributeModifier(new SecondaryActionStyle()); Button('删除').height(48).onClick((): void => { void this.remove(draft); }).attributeModifier(new DangerActionStyle()); } }, (draft: LocalDraft): string => draft.draftId)
  }.width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(18).border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start) }.width('100%').height('100%').align(Alignment.TopStart).padding(14).backgroundColor($r('app.color.canvas')).onVisibleAreaChange([0, 1], (_visible: boolean, ratio: number): void => this.onVisibilityChanged(ratio > 0)) }
}
