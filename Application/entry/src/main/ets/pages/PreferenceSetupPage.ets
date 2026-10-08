import { ChoiceActionStyle, DangerActionStyle, FormInputStyle, PrimaryActionStyle, QuietActionStyle, stage47ErrorText } from '../common/Stage47Ui';
import { common } from '@kit.AbilityKit';
import { FoodCategoryV2 } from '../model/CloudContracts';
import { TastePreference, PreferredMode, PreferenceClearRequest, emptyPreference, copyPreference } from '../model/PreferenceModels';
import { CATEGORY_V2_OPTIONS, CategoryV2Option, parseYuanInputToFen, formatFenInput } from '../model/PublishingModels';
import { PreferenceRepository } from '../repository/PreferenceRepository';
import { AuthService } from '../service/AuthService';
@Component
export struct PreferenceSetupPage {
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  private onAppActiveChanged(): void { if (!this.appActive) this.aboutToDisappear(); else if (this.visibleLifecycle && this.appActive) this.aboutToAppear(); }
  private visibleLifecycle: boolean = true;
  private onVisibilityChanged(visible: boolean): void { if (this.visibleLifecycle === visible) return; this.visibleLifecycle = visible; if (visible && this.appActive) this.aboutToAppear(); else this.aboutToDisappear(); }
  @StorageLink('accountContentRevision') @Watch('onAccountContentChanged') accountContentRevision: number = 0;
  private onAccountContentChanged(): void { this.aboutToDisappear(); this.value = emptyPreference(); this.minimum = ''; this.maximum = ''; this.message = ''; this.busy = false; if (this.visibleLifecycle && this.appActive) this.aboutToAppear(); }

  onDone: () => void = (): void => {};
  @State value: TastePreference = emptyPreference();
  @State minimum: string = ''; @State maximum: string = ''; @State message: string = ''; @State busy: boolean = false;
  private repo: PreferenceRepository = new PreferenceRepository(); private generation: number = 0;
  private context(): common.Context { return this.getUIContext().getHostContext() as common.Context; }
  aboutToAppear(): void { void this.load(); }
  aboutToDisappear(): void { this.generation++; }
  private async load(): Promise<void> { const generation: number = ++this.generation; this.busy = true; try { const p: TastePreference = await this.repo.get(this.context()); if (generation !== this.generation) return; this.value = p; this.minimum = formatFenInput(p.budgetMinFen); this.maximum = formatFenInput(p.budgetMaxFen); } catch (error) { if (generation === this.generation) this.message = stage47ErrorText(error as Object, '加载失败。'); } finally { if (generation === this.generation) this.busy = false; } }
  private select(key: FoodCategoryV2, less: boolean): void { const p: TastePreference = copyPreference(this.value); if (less) { p.lessCategories = p.lessCategories.includes(key) ? p.lessCategories.filter((x: FoodCategoryV2): boolean => x !== key) : p.lessCategories.concat(key); p.likedCategories = p.likedCategories.filter((x: FoodCategoryV2): boolean => x !== key); } else { p.likedCategories = p.likedCategories.includes(key) ? p.likedCategories.filter((x: FoodCategoryV2): boolean => x !== key) : p.likedCategories.concat(key); p.lessCategories = p.lessCategories.filter((x: FoodCategoryV2): boolean => x !== key); } this.value = p; }
  private async save(): Promise<void> { const generation: number = this.generation; if (this.busy) return; this.busy = true; try { const p: TastePreference = copyPreference(this.value); p.budgetMinFen = parseYuanInputToFen(this.minimum); p.budgetMaxFen = parseYuanInputToFen(this.maximum); const saved: TastePreference = await this.repo.save(this.context(), p); if (generation !== this.generation) return; this.value = saved; this.finish(); } catch (error) { if (generation !== this.generation) return; this.message = stage47ErrorText(error as Object, '保存失败。'); } finally { if (generation === this.generation) this.busy = false; } }
  private finish(): void { const profile = AuthService.profile(); this.repo.markSeen(this.context(), profile === undefined ? 'guest' : profile.uid); this.onDone(); }
  private async clear(field: 'ALL' | 'LIKED' | 'LESS' | 'MODE' | 'BUDGET'): Promise<void> { const generation: number = this.generation; if (this.busy) return; this.busy = true; try { const request: PreferenceClearRequest = { field, version: this.value.version }; const saved: TastePreference = await this.repo.clear(this.context(), request); if (generation !== this.generation) return; this.value = saved; this.minimum = formatFenInput(this.value.budgetMinFen); this.maximum = formatFenInput(this.value.budgetMaxFen); this.message = '已清除所选偏好。'; } catch (error) { if (generation !== this.generation) return; this.message = stage47ErrorText(error as Object, '清除失败。'); } finally { if (generation === this.generation) this.busy = false; } }
  @Builder private categories(less: boolean) { Flex({ wrap: FlexWrap.Wrap }) { ForEach(CATEGORY_V2_OPTIONS, (option: CategoryV2Option): void => { Button(option.label).height(48).margin(4).enabled(!this.busy).onClick((): void => this.select(option.key, less)).attributeModifier(new ChoiceActionStyle((less ? this.value.lessCategories : this.value.likedCategories).includes(option.key))); }, (option: CategoryV2Option): string => option.key); } }
  build() { Scroll() { Column({ space: 14 }) {
    Text('主动口味偏好').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
    Text('可以跳过。只使用你主动设置的四项；点赞、收藏、吃过和浏览不会改变长期偏好。游客设置保存在本机，登录后使用账号设置。').fontSize(14).fontColor($r('app.color.muted'))
    Row() { Text('喜欢的分类').layoutWeight(1); Button('清除此项').height(48).onClick((): void => { void this.clear('LIKED'); }).attributeModifier(new QuietActionStyle()); }
    this.categories(false)
    Row() { Text('少推荐的分类').layoutWeight(1); Button('清除此项').height(48).onClick((): void => { void this.clear('LESS'); }).attributeModifier(new QuietActionStyle()); }
    this.categories(true)
    Text('常用消费方式').fontSize(18)
    Row({ space: 8 }) { ForEach(['ANY', 'DELIVERY', 'DINE_IN'], (mode: string): void => { Button(mode === 'ANY' ? '不限' : mode === 'DELIVERY' ? '外卖' : '到店').height(48).onClick((): void => { const p: TastePreference = copyPreference(this.value); p.preferredMode = mode as PreferredMode; this.value = p; }).attributeModifier(new ChoiceActionStyle(this.value.preferredMode === mode)); }); }
    Button('清除消费方式').height(48).onClick((): void => { void this.clear('MODE'); }).attributeModifier(new QuietActionStyle())
    Text('常用预算（元，可留空）').fontSize(18)
    TextInput({ text: this.minimum, placeholder: '预算下限' }).attributeModifier(new FormInputStyle()).height(48).onChange((s: string): void => { this.minimum = s; })
    TextInput({ text: this.maximum, placeholder: '预算上限' }).attributeModifier(new FormInputStyle()).height(48).onChange((s: string): void => { this.maximum = s; })
    Button('清除预算').height(48).onClick((): void => { void this.clear('BUDGET'); }).attributeModifier(new QuietActionStyle())
    Text(this.message).fontSize(13).lineHeight(20).fontColor($r('app.color.danger'))
    Button(this.busy ? '保存中…' : '保存设置').height(48).enabled(!this.busy).onClick((): void => { void this.save(); }).attributeModifier(new PrimaryActionStyle()).width('100%')
    Button('全部清除').height(48).onClick((): void => { void this.clear('ALL'); }).attributeModifier(new DangerActionStyle())
    Button('跳过 / 返回').height(48).onClick((): void => this.finish()).attributeModifier(new QuietActionStyle())
  }.width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(18).border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start) }.width('100%').height('100%').align(Alignment.TopStart).padding(14).backgroundColor($r('app.color.canvas')).onVisibleAreaChange([0, 1], (_visible: boolean, ratio: number): void => this.onVisibilityChanged(ratio > 0)) }
}
