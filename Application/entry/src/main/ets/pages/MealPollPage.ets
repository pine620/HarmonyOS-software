/**
 * 【文件职责】群聊“一起选餐”投票页面：创建投票、选择候选、投票、截止 / 取消；投票进行中按退避策略轮询刷新。数据来自 MealRepository（shike-social）。
 */
import { ChoiceActionStyle, DangerActionStyle, FormInputStyle, PrimaryActionStyle, QuietActionStyle, SecondaryActionStyle, stage47ErrorText } from '../common/Stage47Ui';
import { util } from '@kit.ArkTS';
import { FoodCard } from '../model/CloudContracts';
import { MealPollResponse, MealPollOption, MealPollMutationRequest, CreateMealPollRequest, MealCandidatePage, MealCandidate, MealQuery, PollVoter } from '../model/MealModels';
import { MealRepository } from '../repository/MealRepository';
import { AuthService } from '../service/AuthService';
import { PollBackoff } from '../service/PollBackoff';
// 选餐投票页面。
@Component
export struct MealPollPage {
  private generation: number = 0;
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  // App 前后台切换时暂停 / 恢复。
  private onAppActiveChanged(): void { if (!this.appActive) this.aboutToDisappear(); else if (this.visibleLifecycle && this.appActive) this.aboutToAppear(); }
  private visibleLifecycle: boolean = true;
  // 页面可见性变化时暂停 / 恢复。
  private onVisibilityChanged(visible: boolean): void { if (this.visibleLifecycle === visible) return; this.visibleLifecycle = visible; if (visible && this.appActive) this.aboutToAppear(); else this.aboutToDisappear(); }
  @StorageLink('accountContentRevision') @Watch('onAccountContentChanged') accountContentRevision: number = 0;
  // 换号时清空。
  private onAccountContentChanged(): void { this.aboutToDisappear(); this.response = undefined; this.candidates = []; this.createRequest = undefined; this.activePollId = ''; this.busy = false; if (this.visibleLifecycle && this.appActive) this.aboutToAppear(); }

  @Prop groupId: string = ''; @Prop pollId: string = ''; onDone: () => void = (): void => {}; onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @State response: MealPollResponse | undefined = undefined; @State candidates: Array<MealCandidate> = [];
  @State title: string = '一起选餐'; @State mode: 'CARD' | 'MERCHANT' = 'CARD'; @State anonymous: boolean = false;
  @State consumption: 'ANY' | 'DELIVERY' | 'DINE_IN' = 'ANY'; @State deadlineMinutes: string = ''; @State message: string = ''; @State busy: boolean = false;
  private repo: MealRepository = new MealRepository(); private active: boolean = true;
  // 与聊天相同的退避策略（投票没有变化时 12 秒 → 30 秒 → 60 秒），节省 Cloud DB 读取。
  private poller: PollBackoff = new PollBackoff((): Promise<boolean> => this.pollOnce());
  @State activePollId: string = '';
  private createRequest: CreateMealPollRequest | undefined = undefined;
  // 页面出现：加载投票并开始轮询。
  aboutToAppear(): void { this.generation++; this.active = true; if (this.activePollId.length === 0) this.activePollId = this.pollId; if (this.activePollId.length > 0) void this.refresh(); this.poller.start(); }
  // 页面消失：停止轮询并清空状态。
  aboutToDisappear(): void { this.generation++; this.active = false; this.busy = false; this.response = undefined; this.candidates = []; this.poller.stop(); }
  // 后台轮询一次；返回投票是否变化，以便重置退避间隔。
  private async pollOnce(): Promise<boolean> { if (!this.active || this.activePollId.length === 0 || this.busy) return false; const before: number = this.response === undefined ? -1 : this.response.poll.version; await this.refresh(); const after: number = this.response === undefined ? -1 : this.response.poll.version; return after !== before; }
  // 立即刷新投票详情。
  private async refresh(): Promise<void> { const generation: number = this.generation; const pollId: string = this.activePollId; if (pollId.length === 0) return; this.busy = true; try { const r: MealPollResponse = await this.repo.poll(pollId); if (!this.active || generation !== this.generation) return; if (this.active) { this.response = r; this.message = ''; } } catch (error) { if (!this.active || generation !== this.generation) return; if (this.active) { this.response = undefined; this.candidates = []; this.message = stage47ErrorText(error as Object, '投票刷新失败。'); } } finally { if (this.active && generation === this.generation) this.busy = false; } }
  // 创建投票。
  private async create(): Promise<void> { const generation: number = this.generation; this.busy = true; try { if (this.createRequest === undefined) { const minutes: number | null = this.deadlineMinutes.trim().length === 0 ? null : Number(this.deadlineMinutes); if (minutes !== null && (!Number.isInteger(minutes) || minutes < 1 || minutes > 10080)) throw new Error('截止时间为 1–10080 分钟，可留空。'); const p: CreateMealPollRequest = { requestId: util.generateRandomUUID(), groupId: this.groupId, title: this.title, mode: this.mode, visibilityMode: this.anonymous ? 'ANONYMOUS' : 'NAMED', consumptionMode: this.consumption, deadlineAt: minutes === null ? null : Date.now() + minutes * 60000 }; this.createRequest = p; } const result: MealPollResponse = await this.repo.createPoll(this.createRequest); if (!this.active || generation !== this.generation) return; if (this.active) { this.activePollId = result.poll.pollId; this.response = result; this.createRequest = undefined; this.poller.reset(); } } catch (error) { if (!this.active || generation !== this.generation) return; this.message = stage47ErrorText(error as Object, '创建未确认，请用原设置重试。'); } finally { if (this.active && generation === this.generation) this.busy = false; } }
  // 投票变更（加选项 / 投票 / 截止 / 取消 / 停止加选项），完成后刷新。
  private async mutate(operation: string, optionId: string = '', candidate: FoodCard | undefined = undefined): Promise<void> { const generation: number = this.generation; const response: MealPollResponse | undefined = this.response; if (response === undefined || this.busy) return; let failed: boolean = false; this.busy = true; try { const p: MealPollMutationRequest = { pollId: response.poll.pollId, version: response.poll.version, optionId, cardId: candidate === undefined ? undefined : candidate.id, merchantId: candidate === undefined ? undefined : candidate.merchantId }; const result: MealPollResponse = await this.repo.mutatePoll(operation, p); if (!this.active || generation !== this.generation) return; if (this.active) { this.response = result; this.message = ''; this.poller.reset(); } } catch (error) { if (!this.active || generation !== this.generation) return; failed = true; this.message = stage47ErrorText(error as Object, '操作失败，请刷新。'); } finally { if (this.active && generation === this.generation) this.busy = false; if (failed && this.active && generation === this.generation) void this.refresh(); } }
  // 加载可加入投票的候选卡片。
  private async loadCandidates(): Promise<void> { const generation: number = this.generation; this.busy = true; try { const r: MealPollResponse | undefined = this.response; const query: MealQuery = { keyword: '', mode: r === undefined || r.poll.consumptionMode === 'ANY' ? 'ALL' : r.poll.consumptionMode, categories: [], source: 'ALL', nearby: false, radiusMeters: 1000, coordinateSystem: 'GCJ02', excludedCardIds: this.candidates.map((c: MealCandidate): string => c.card.id) }; const page: MealCandidatePage = await this.repo.candidates(query); if (!this.active || generation !== this.generation) return; if (this.active) this.candidates = this.candidates.concat(page.candidates); } catch (error) { if (!this.active || generation !== this.generation) return; this.message = stage47ErrorText(error as Object, '候选加载失败。'); } finally { if (this.active && generation === this.generation) this.busy = false; } }
  // 当前用户是否为投票发起人（只有发起人可以截止 / 取消）。
  private creator(): boolean { const profile = AuthService.profile(); return profile !== undefined && this.response !== undefined && profile.uid === this.response.poll.creatorUid; }
  // 选项显示名称（不可见的候选显示“候选已不可用”）。
  private optionName(option: MealPollOption): string { return !option.accessible ? '候选已不可访问' : option.card !== null ? option.card.productName : option.merchant !== null ? option.merchant.name : '候选'; }
  // 页面布局。
  build() { Scroll() { Column({ space: 12 }) {
    Text('群共同选餐').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.social_ink'))
    Text(this.message).fontSize(13).lineHeight(20).fontColor($r('app.color.danger'))
    if (this.response === undefined) {
      if (this.activePollId.length === 0 && this.pollId.length === 0) {
        Column({ space: 12 }) {
          Text('标题'); TextInput({ text: this.title }).attributeModifier(new FormInputStyle('SOCIAL')).constraintSize({ minHeight: 48 }).onChange((v: string): void => { this.title = v; })
          Row({ space: 8 }) { Button('菜品投票').constraintSize({ minHeight: 48 }).onClick((): void => { this.mode = 'CARD'; }).attributeModifier(new ChoiceActionStyle(this.mode === 'CARD', 'SOCIAL')); Button('商家投票').constraintSize({ minHeight: 48 }).onClick((): void => { this.mode = 'MERCHANT'; }).attributeModifier(new ChoiceActionStyle(this.mode === 'MERCHANT', 'SOCIAL')); }
          Text(this.mode === 'CARD' ? '菜品投票' : '商家投票')
          Button(this.anonymous ? '匿名（点击改记名）' : '记名（点击改匿名）').constraintSize({ minHeight: 48 }).onClick((): void => { this.anonymous = !this.anonymous; }).attributeModifier(new SecondaryActionStyle('SOCIAL'))
          Row({ space: 8 }) { Button('不限方式').constraintSize({ minHeight: 48 }).onClick((): void => { this.consumption = 'ANY'; }).attributeModifier(new ChoiceActionStyle(this.consumption === 'ANY', 'SOCIAL')); Button('外卖').constraintSize({ minHeight: 48 }).onClick((): void => { this.consumption = 'DELIVERY'; }).attributeModifier(new ChoiceActionStyle(this.consumption === 'DELIVERY', 'SOCIAL')); Button('到店').constraintSize({ minHeight: 48 }).onClick((): void => { this.consumption = 'DINE_IN'; }).attributeModifier(new ChoiceActionStyle(this.consumption === 'DINE_IN', 'SOCIAL')); }
          Text('截止（分钟，留空无自动截止）'); TextInput({ text: this.deadlineMinutes }).attributeModifier(new FormInputStyle('SOCIAL')).constraintSize({ minHeight: 48 }).onChange((v: string): void => { this.deadlineMinutes = v; })
        }.enabled(this.createRequest === undefined && !this.busy)
        if (this.createRequest !== undefined) { Text('创建结果尚未确认。重试沿用原设置与请求编号，避免重复创建。'); }
        Button(this.createRequest === undefined ? '发起投票' : '重试原投票请求').constraintSize({ minHeight: 48 }).enabled(!this.busy).onClick((): void => { void this.create(); }).attributeModifier(new PrimaryActionStyle('SOCIAL')).width('100%')
      } else { Text('正在重新校验群成员资格与投票内容。'); Button('重新加载').constraintSize({ minHeight: 48 }).enabled(!this.busy).onClick((): void => { void this.refresh(); }).attributeModifier(new SecondaryActionStyle('SOCIAL')); }
    } else {
      Text(this.response.poll.title).fontSize(20)
      Text(this.response.poll.visibilityMode === 'ANONYMOUS' ? '匿名：仅显示票数和你的选择' : '记名：群内可见投票者')
      Text((this.response.poll.status === 'OPEN' ? '投票进行中' : this.response.poll.status === 'CLOSED' ? '投票已结束' : '投票已取消') + (this.response.poll.deadlineAt === null ? '' : ' · 截止 ' + new Date(this.response.poll.deadlineAt).toLocaleString()))
      if (this.response.poll.status === 'CLOSED') { Text(this.response.poll.closeOutcome === 'NO_RESULT' ? '无结果：没有有效候选或有效票，可发起新投票。' : '结果已固定；胜者后来不可访问时保留结果，不重新选择。'); }
      Button('刷新').constraintSize({ minHeight: 48 }).enabled(!this.busy).onClick((): void => { void this.refresh(); }).attributeModifier(new QuietActionStyle('SOCIAL'))
      ForEach(this.response.options, (option: MealPollOption): void => { Column({ space: 8 }) {
        Text(this.optionName(option) + ' · ' + option.voteCount.toString() + ' 票' + (this.response !== undefined && this.response.poll.winnerOptionId === option.optionId ? ' · 固定赢家' : '')).fontSize(18)
        if (option.voters !== undefined) { Text(option.voters.map((v: PollVoter): string => v.nickname).join('、')); }
        Button(this.response !== undefined && this.response.myVote === option.optionId ? '我的选择（可改票）' : '投这项').constraintSize({ minHeight: 48 }).enabled(!this.busy && option.accessible && this.response !== undefined && this.response.poll.status === 'OPEN').onClick((): void => { void this.mutate('vote-meal-poll', option.optionId); }).attributeModifier(new ChoiceActionStyle(this.response !== undefined && this.response.myVote === option.optionId, 'SOCIAL'))
        if (option.card !== null) { Button('查看详情').constraintSize({ minHeight: 48 }).onClick((): void => { const card: FoodCard | null = option.card; if (card !== null) this.onOpenCard(card); }).attributeModifier(new SecondaryActionStyle('SOCIAL')); }
      }.padding(12).width('100%').backgroundColor($r('app.color.social_canvas')).borderRadius(12); }, (option: MealPollOption): string => option.optionId)
      if (this.response.poll.status === 'OPEN' && this.response.poll.acceptingOptions) { Button('从本次候选添加 / 更多').constraintSize({ minHeight: 48 }).enabled(!this.busy).onClick((): void => { void this.loadCandidates(); }).attributeModifier(new SecondaryActionStyle('SOCIAL')); ForEach(this.candidates, (candidate: MealCandidate): void => { Button(this.response !== undefined && this.response.poll.mode === 'MERCHANT' ? '添加商家 · ' + (candidate.card.merchantNameSnapshot || candidate.card.shop) : '添加菜品 · ' + candidate.card.productName).constraintSize({ minHeight: 48 }).enabled(!this.busy).onClick((): void => { void this.mutate('add-meal-poll-option', '', candidate.card); }).attributeModifier(new SecondaryActionStyle('SOCIAL')); }); }
      if (this.creator() && this.response.poll.status === 'OPEN') { Button('停止添加候选').constraintSize({ minHeight: 48 }).enabled(!this.busy).onClick((): void => { void this.mutate('stop-meal-poll-options'); }).attributeModifier(new SecondaryActionStyle('SOCIAL')); Button('提前结束并固化结果').constraintSize({ minHeight: 48 }).enabled(!this.busy).onClick((): void => { void this.mutate('close-meal-poll'); }).attributeModifier(new SecondaryActionStyle('SOCIAL')); Button('取消投票').constraintSize({ minHeight: 48 }).enabled(!this.busy).onClick((): void => { void this.mutate('cancel-meal-poll'); }).attributeModifier(new DangerActionStyle('SOCIAL')); }
    }
    Button('返回群聊').constraintSize({ minHeight: 48 }).onClick((): void => this.onDone()).attributeModifier(new QuietActionStyle('SOCIAL'))
  }.width('100%').padding(16).backgroundColor($r('app.color.social_surface')).borderRadius(18).border({ width: 1, color: $r('app.color.social_line') }).alignItems(HorizontalAlign.Start).enabled(!this.busy) }.width('100%').height('100%').align(Alignment.TopStart).padding(14).backgroundColor($r('app.color.social_canvas')).onVisibleAreaChange([0, 1], (_visible: boolean, ratio: number): void => this.onVisibilityChanged(ratio > 0)) }
}
