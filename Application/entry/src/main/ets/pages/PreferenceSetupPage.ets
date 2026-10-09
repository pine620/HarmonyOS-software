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
  @Builder private categories(less: boolean) { Flex({ wrap: FlexWrap.Wrap }) { ForEach(CATEGORY_V2_OPTIONS, (option: CategoryV2Option): void => { Button(option.label).constraintSize({ minHeight: 48 }).margin(4).enabled(!this.busy).onClick((): void => this.select(option.key, less)).attributeModifier(new ChoiceActionStyle((less ? this.value.lessCategories : this.value.likedCategories).includes(option.key))); }, (option: CategoryV2Option): string => option.key); } }
  build() {
    Scroll() {
      Column({ space: 16 }) {
        Column({ space: 8 }) {
          Text('吃得合口味').fontSize(26).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
          Text('告诉食刻你喜欢什么').fontSize(15).fontColor($r('app.color.action_text'))
          Text('随时可改，也可以跳过。只按你主动填写的分类、方式和预算推荐。').fontSize(13).lineHeight(20).fontColor($r('app.color.muted'))
        }.width('100%').alignItems(HorizontalAlign.Start).padding(20).backgroundColor($r('app.color.accent_soft')).borderRadius(24)
        Column({ space: 8 }) {
          Row() { Text('喜欢的口味').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1); Button('清除').enabled(!this.busy).attributeModifier(new QuietActionStyle()).onClick((): void => { void this.clear('LIKED'); }); }.width('100%')
          Text('多选几种，让推荐更对胃口').fontSize(13).fontColor($r('app.color.muted'))
          this.categories(false)
        }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor($r('app.color.surface')).borderRadius(24)
        Column({ space: 8 }) {
          Row() { Text('少推荐一些').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1); Button('清除').enabled(!this.busy).attributeModifier(new QuietActionStyle()).onClick((): void => { void this.clear('LESS'); }); }.width('100%')
          Text('只是少推荐，之后仍能主动查找').fontSize(13).fontColor($r('app.color.muted'))
          this.categories(true)
        }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor($r('app.color.surface')).borderRadius(24)
        Column({ space: 10 }) {
          Row() { Text('平时怎么吃').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1); Button('清除').enabled(!this.busy).attributeModifier(new QuietActionStyle()).onClick((): void => { void this.clear('MODE'); }); }.width('100%')
          Row({ space: 8 }) {
            ForEach(['ANY', 'DELIVERY', 'DINE_IN'], (mode: string): void => {
              Button(mode === 'ANY' ? '都可以' : mode === 'DELIVERY' ? '点外卖' : '去店里').layoutWeight(1).enabled(!this.busy)
                .attributeModifier(new ChoiceActionStyle(this.value.preferredMode === mode)).onClick((): void => { const p: TastePreference = copyPreference(this.value); p.preferredMode = mode as PreferredMode; this.value = p; });
            }, (mode: string): string => mode)
          }.width('100%')
          Row() { Text('常用预算').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1); Button('清除').enabled(!this.busy).attributeModifier(new QuietActionStyle()).onClick((): void => { void this.clear('BUDGET'); }); }.width('100%')
          Row({ space: 8 }) {
            TextInput({ text: this.minimum, placeholder: '最低 / 元' }).layoutWeight(1).height(48).enabled(!this.busy).attributeModifier(new FormInputStyle()).onChange((value: string): void => { this.minimum = value; })
            Text('—').fontColor($r('app.color.muted'))
            TextInput({ text: this.maximum, placeholder: '最高 / 元' }).layoutWeight(1).height(48).enabled(!this.busy).attributeModifier(new FormInputStyle()).onChange((value: string): void => { this.maximum = value; })
          }.width('100%')
          Text('留空不限预算；游客设置保存在本机，登录后使用账号设置。').fontSize(12).lineHeight(18).fontColor($r('app.color.muted'))
        }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor($r('app.color.surface')).borderRadius(24)
        if (this.message.length > 0) { Text(this.message).fontSize(13).lineHeight(20).fontColor($r('app.color.danger')).width('100%') }
        Button(this.busy ? '正在保存…' : '保存我的偏好').enabled(!this.busy).width('100%').attributeModifier(new PrimaryActionStyle()).onClick((): void => { void this.save(); })
        Row({ space: 12 }) {
          Button('全部清除').enabled(!this.busy).layoutWeight(1).attributeModifier(new DangerActionStyle()).onClick((): void => { void this.clear('ALL'); })
          Button('跳过 / 返回').enabled(!this.busy).layoutWeight(1).attributeModifier(new QuietActionStyle()).onClick((): void => this.finish())
        }.width('100%')
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').align(Alignment.TopStart).backgroundColor($r('app.color.canvas'))
      .onVisibleAreaChange([0, 1], (_visible: boolean, ratio: number): void => this.onVisibilityChanged(ratio > 0))
  }
}
