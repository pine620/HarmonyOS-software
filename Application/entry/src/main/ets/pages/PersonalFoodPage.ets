import { ChoiceActionStyle, DangerActionStyle, FormInputStyle, FormNoteStyle, PrimaryActionStyle, QuietActionStyle, stage47ErrorText } from '../common/Stage47Ui';
import { PersonalFoodState, PersonalFoodRequest, emptyPersonal, PersonalFoodStatus } from '../model/FoodListModels';
import { FoodListRepository } from '../repository/FoodListRepository';
@Component
export struct PersonalFoodPage {
  private generation: number = 0;
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  private onAppActiveChanged(): void { if (!this.appActive) this.aboutToDisappear(); else if (this.visibleLifecycle && this.appActive) this.aboutToAppear(); }
  private visibleLifecycle: boolean = true;
  private onVisibilityChanged(visible: boolean): void { if (this.visibleLifecycle === visible) return; this.visibleLifecycle = visible; if (visible && this.appActive) this.aboutToAppear(); else this.aboutToDisappear(); }
  @StorageLink('accountContentRevision') @Watch('onAccountContentChanged') accountContentRevision: number = 0;
  private onAccountContentChanged(): void { this.aboutToDisappear(); this.value = emptyPersonal(this.cardId); this.note = ''; this.date = ''; this.score = ''; this.state = 'NONE'; this.busy = false; if (this.visibleLifecycle && this.appActive) this.aboutToAppear(); }

  @Prop cardId: string = ''; onDone: () => void = (): void => {};
  @State value: PersonalFoodState = emptyPersonal(''); @State note: string = ''; @State date: string = ''; @State score: string = ''; @State state: PersonalFoodStatus = 'NONE'; @State message: string = ''; @State busy: boolean = false;
  private repo: FoodListRepository = new FoodListRepository(); private active: boolean = true;
  aboutToAppear(): void { this.generation++; this.active = true; void this.load(); } aboutToDisappear(): void { this.generation++; this.active = false; this.busy = false; this.note = ''; }
  private async load(): Promise<void> { const generation: number = this.generation; this.busy = true; try { const p: PersonalFoodState = await this.repo.personal(this.cardId); if (!this.active || generation !== this.generation) return; if (!this.active) return; this.value = p; this.note = p.privateNote; this.date = p.eatenAt === null ? '' : new Date(p.eatenAt + 8 * 3600000).toISOString().slice(0, 10); this.score = p.personalScore === null ? '' : p.personalScore.toString(); this.state = p.state; } catch (error) { if (!this.active || generation !== this.generation) return; this.message = stage47ErrorText(error as Object, '加载失败。'); } finally { if (this.active && generation === this.generation) this.busy = false; } }
  private async save(clear: boolean = false): Promise<void> { const generation: number = this.generation; this.busy = true; try { const date: number | null = clear || this.date.trim().length === 0 ? null : Date.parse(this.date.trim() + 'T00:00:00+08:00'); if (date !== null && (!/^\d{4}-\d{2}-\d{2}$/.test(this.date) || !Number.isFinite(date) || new Date(date + 8 * 3600000).toISOString().slice(0, 10) !== this.date.trim())) throw new Error('日期需为 YYYY-MM-DD。'); const score: number | null = clear || this.score.trim().length === 0 ? null : Number(this.score); if (score !== null && (!Number.isInteger(score) || score < 1 || score > 10)) throw new Error('个人评分为 1–10 整数。'); const request: PersonalFoodRequest = { cardId: this.cardId, state: clear ? 'NONE' : this.state, privateNote: clear ? '' : this.note, eatenAt: date, personalScore: score, version: this.value.version, updatedAt: this.value.updatedAt, clear }; await this.repo.savePersonal(request); if (!this.active || generation !== this.generation) return; this.onDone(); } catch (error) { if (!this.active || generation !== this.generation) return; this.message = stage47ErrorText(error as Object, '保存失败。'); } finally { if (this.active && generation === this.generation) this.busy = false; } }
  build() { Scroll() { Column({ space: 14 }) {
    Text('我的私人记录').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
    Text('只供本人查看；不会进入卡片、群、分享网页或其他人的接口。').fontSize(14).lineHeight(21).fontColor($r('app.color.muted'))
    Row({ space: 8 }) { Button('未标记').height(48).onClick((): void => { this.state = 'NONE'; }).attributeModifier(new ChoiceActionStyle(this.state === 'NONE')); Button('想吃').height(48).onClick((): void => { this.state = 'WANT_TO_EAT'; }).attributeModifier(new ChoiceActionStyle(this.state === 'WANT_TO_EAT')); Button('吃过').height(48).onClick((): void => { this.state = 'EATEN'; }).attributeModifier(new ChoiceActionStyle(this.state === 'EATEN')); }
    Text('当前：' + (this.state === 'EATEN' ? '吃过' : this.state === 'WANT_TO_EAT' ? '想吃' : '未标记'))
    Text('私人备注（最多 2000 字）');
    TextArea({ text: this.note, placeholder: '仅自己可见' }).attributeModifier(new FormNoteStyle()).height(160).maxLength(2000).onChange((v: string): void => { this.note = v; })
    Text('吃过日期（可留空）');
    TextInput({ text: this.date, placeholder: 'YYYY-MM-DD' }).attributeModifier(new FormInputStyle()).height(48).onChange((v: string): void => { this.date = v; })
    Text('个人评分（1–10，可留空）');
    TextInput({ text: this.score }).attributeModifier(new FormInputStyle()).height(48).onChange((v: string): void => { this.score = v; })
    Text(this.message).fontSize(13).lineHeight(20).fontColor($r('app.color.danger'));
    Button('保存').height(48).enabled(!this.busy).onClick((): void => { void this.save(); }).attributeModifier(new PrimaryActionStyle()).width('100%')
    Button('手动清理私人记录').height(48).enabled(!this.busy).onClick((): void => { void this.save(true); }).attributeModifier(new DangerActionStyle());
    Button('返回').height(48).onClick((): void => this.onDone()).attributeModifier(new QuietActionStyle())
  }.width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(18).border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start) }.width('100%').height('100%').align(Alignment.TopStart).padding(14).backgroundColor($r('app.color.canvas')).onVisibleAreaChange([0, 1], (_visible: boolean, ratio: number): void => this.onVisibilityChanged(ratio > 0)) }
}
