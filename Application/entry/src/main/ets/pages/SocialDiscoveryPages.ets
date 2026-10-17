/**
 * 【文件职责】本机草稿箱页面 DraftsPage（文件名是历史遗留，实际内容与“社交发现”无关）。
 * 列出当前账号的草稿，点击后通过 onRestore 回调交给 Index 打开发布页恢复编辑，也可删除草稿。
 * 【页面生命周期模式】多个页面共用同一套写法：监听 AppStorage 中的 stage47AppActive（App 是否在前台）与
 * accountContentRevision（账号内容版本），App 进入后台或换号时清空数据，回到前台且页面可见时重新加载；
 * generation 计数让异步加载在页面状态变化后自动作废。
 */
import { DangerActionStyle, SecondaryActionStyle, stage47ErrorText } from '../common/Stage47Ui';
import { common } from '@kit.AbilityKit';
import { LocalDraft } from '../model/DraftModels';
import { DraftStore } from '../service/DraftStore';
import { AuthService } from '../service/AuthService';
// 草稿箱页面。
@Component
export struct DraftsPage {
  private generation: number = 0;
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  // App 前后台切换时暂停 / 恢复。
  private onAppActiveChanged(): void { if (!this.appActive) this.aboutToDisappear(); else if (this.visibleLifecycle && this.appActive) this.aboutToAppear(); }
  private visibleLifecycle: boolean = true;
  // 页面可见性变化时暂停 / 恢复。
  private onVisibilityChanged(visible: boolean): void { if (this.visibleLifecycle === visible) return; this.visibleLifecycle = visible; if (visible && this.appActive) this.aboutToAppear(); else this.aboutToDisappear(); }
  @StorageLink('accountContentRevision') @Watch('onAccountContentChanged') accountContentRevision: number = 0;
  // 账号内容变化（换号）时清空并重新加载。
  private onAccountContentChanged(): void { this.aboutToDisappear(); this.drafts = []; if (this.visibleLifecycle && this.appActive) this.aboutToAppear(); }

  onRestore: (draft: LocalDraft) => void = (_draft: LocalDraft): void => {};
  @State drafts: Array<LocalDraft> = []; @State message: string = '';
  private active: boolean = true;
  // 取得宿主上下文。
  private context(): common.Context { return this.getUIContext().getHostContext() as common.Context; }
  // 页面出现时加载 / 消失时清空。
  aboutToAppear(): void { this.generation++; this.active = true; void this.load(); } aboutToDisappear(): void { this.generation++; this.active = false; this.drafts = []; }
  // 读取当前账号的草稿列表。
  private async load(): Promise<void> { const generation: number = this.generation; const profile = AuthService.profile(); if (profile === undefined) return; try { const rows: Array<LocalDraft> = await DraftStore.list(this.context(), profile.uid); if (!this.active || generation !== this.generation) return; if (this.active) this.drafts = rows; const count: number = await DraftStore.reminders(this.context(), profile.uid); if (!this.active || generation !== this.generation) return; if (count > 0) this.message = count.toString() + ' 个草稿将在 3 天内过期，请及时处理。'; } catch (error) { if (!this.active || generation !== this.generation) return; this.message = stage47ErrorText(error as Object, '草稿加载失败。'); } }
  // 删除一个草稿后刷新列表。
  private async remove(draft: LocalDraft): Promise<void> { const generation: number = this.generation; try { await DraftStore.remove(this.context(), draft.ownerUid, draft.draftId); if (!this.active || generation !== this.generation) return; await this.load(); if (!this.active || generation !== this.generation) return; } catch (error) { if (!this.active || generation !== this.generation) return; this.message = stage47ErrorText(error as Object, '删除失败。'); } }
  // 页面布局。
  build() { Scroll() { Column({ space: 12 }) {
    Text('本机草稿箱').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.personal_ink'))
    Text('新发布与编辑合计最多 10 个；30 天未编辑清理。草稿按账号隔离。').fontSize(14).lineHeight(21).fontColor($r('app.color.personal_muted'))
    Text(this.message).fontSize(13).lineHeight(20).fontColor($r('app.color.personal_muted'))
    ForEach(this.drafts, (draft: LocalDraft): void => { Row({ space: 8 }) { Button((draft.draftType === 'EDIT' ? '编辑 · ' : '新建 · ') + (draft.form.productName || '未命名')).constraintSize({ minHeight: 64 }).layoutWeight(1).onClick((): void => this.onRestore(draft)).attributeModifier(new SecondaryActionStyle()); Button('删除').constraintSize({ minHeight: 48 }).onClick((): void => { void this.remove(draft); }).attributeModifier(new DangerActionStyle()); } }, (draft: LocalDraft): string => draft.draftId)
  }.width('100%').padding(16).backgroundColor($r('app.color.personal_surface')).borderRadius(18).border({ width: 1, color: $r('app.color.personal_line') }).alignItems(HorizontalAlign.Start) }.width('100%').height('100%').align(Alignment.TopStart).padding(14).backgroundColor($r('app.color.personal_canvas')).onVisibleAreaChange([0, 1], (_visible: boolean, ratio: number): void => this.onVisibilityChanged(ratio > 0)) }
}
