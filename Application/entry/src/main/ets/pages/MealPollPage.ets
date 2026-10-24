/**
 * 【文件职责】群聊“一起选餐”投票页面（两步向导 + 排行榜）：
 *   发起：① 挑卡片（关键词 + 来源筛选，每次加载 3 张，可继续加载）→ ② 设置标题 / 记名或匿名 / 截止时间 → 创建投票后逐张添加所选卡片；
 *   进行中：顶部显示领先（或最终选定）的卡片，下面按票数排行，点选项即投票 / 改票；群成员可补充卡片，发起人可停止补充 / 提前结束 / 取消。
 * 投票进行中按退避策略轮询刷新。数据来自 MealRepository（shike-social）。
 * 【服务端约束】候选最多 12 个、每次候选查询最多返回 3 张、截止时间不超过 7 天；创建接口不带选项，所以选项在创建后逐张添加。
 */
import { ChoiceActionStyle, DangerActionStyle, FormInputStyle, PrimaryActionStyle, QuietActionStyle, SecondaryActionStyle, stage47ErrorText } from '../common/Stage47Ui';
import { util } from '@kit.ArkTS';
import { FoodCard } from '../model/CloudContracts';
import { MealPollResponse, MealPollOption, MealPollMutationRequest, CreateMealPollRequest, MealCandidatePage, MealCandidate, MealQuery, MealSource, PollVoter } from '../model/MealModels';
import { MealRepository } from '../repository/MealRepository';
import { AuthService } from '../service/AuthService';
import { PollBackoff } from '../service/PollBackoff';
import { coverFor } from '../components/FoodCover';

// 服务端规定的候选上限。
const MAX_POLL_OPTIONS: number = 12;
// 发起时至少挑选的卡片数。
const MIN_CREATE_OPTIONS: number = 2;
// 发起向导的步骤：PICK 挑卡片，SETTINGS 设置。
type CreateStep = 'PICK' | 'SETTINGS';
// 截止时间快捷选项（分钟，0 = 不截止，-1 = 自定义）。
const DEADLINE_PRESETS: Array<number> = [0, 30, 60, 120, -1];

// 截止快捷选项的文字。
function deadlineLabel(minutes: number): string {
  if (minutes === 0) return '不截止';
  if (minutes === -1) return '自定义';
  return minutes < 60 ? `${minutes} 分钟` : `${minutes / 60} 小时`;
}

// 云端错误对象中可能包含的字段。
interface PollErrorDetail {
  code?: string | number;
  message?: string;
}

// 卡片的店名。
function shopName(card: FoodCard): string {
  return card.merchantNameSnapshot || card.shop || '';
}

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
  private onAccountContentChanged(): void {
    this.aboutToDisappear(); this.response = undefined; this.resetPicker(); this.createRequest = undefined; this.pendingAddIds = [];
    this.activePollId = ''; this.step = 'PICK'; this.adding = false; this.busy = false;
    if (this.visibleLifecycle && this.appActive) this.aboutToAppear();
  }

  @Prop groupId: string = ''; @Prop pollId: string = ''; @Prop memberCount: number = 0;
  onDone: () => void = (): void => {}; onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @State response: MealPollResponse | undefined = undefined;
  // 挑卡片：已加载的候选、已选卡片编号、关键词、来源、是否已无更多。
  @State candidates: Array<MealCandidate> = []; @State selectedIds: Array<string> = [];
  @State keyword: string = ''; @State source: MealSource = 'ALL'; @State exhausted: boolean = false;
  // 设置：标题、匿名、截止快捷选项（分钟）与自定义分钟数。
  @State title: string = '一起选餐'; @State anonymous: boolean = false;
  @State deadlinePreset: number = 30; @State customMinutes: string = '';
  @State step: CreateStep = 'PICK';
  // 投票进行中是否正在补充卡片。
  @State adding: boolean = false;
  @State message: string = ''; @State busy: boolean = false;
  @State activePollId: string = '';
  private repo: MealRepository = new MealRepository(); private active: boolean = true;
  // 与聊天相同的退避策略（投票没有变化时 12 秒 → 30 秒 → 60 秒），节省 Cloud DB 读取。
  private poller: PollBackoff = new PollBackoff((): Promise<boolean> => this.pollOnce());
  // 创建请求在结果确认前保留，重试沿用原请求编号，避免重复创建。
  private createRequest: CreateMealPollRequest | undefined = undefined;
  // 投票已创建但还没加进去的卡片（重试时继续添加）。
  private pendingAddIds: Array<string> = [];

  // 页面出现：加载投票（或进入挑卡片）并开始轮询。
  aboutToAppear(): void {
    this.generation++; this.active = true;
    if (this.activePollId.length === 0) this.activePollId = this.pollId;
    if (this.activePollId.length > 0) void this.refresh();
    else if (this.candidates.length === 0) void this.loadCandidates();
    this.poller.start();
  }
  // 页面消失：停止轮询并清空状态。
  aboutToDisappear(): void { this.generation++; this.active = false; this.busy = false; this.response = undefined; this.poller.stop(); }
  // 后台轮询一次；返回投票是否变化，以便重置退避间隔。
  private async pollOnce(): Promise<boolean> { if (!this.active || this.activePollId.length === 0 || this.busy || this.adding) return false; const before: number = this.response === undefined ? -1 : this.response.poll.version; await this.refresh(); const after: number = this.response === undefined ? -1 : this.response.poll.version; return after !== before; }
  // 立即刷新投票详情。
  private async refresh(): Promise<void> { const generation: number = this.generation; const pollId: string = this.activePollId; if (pollId.length === 0) return; this.busy = true; try { const r: MealPollResponse = await this.repo.poll(pollId); if (!this.active || generation !== this.generation) return; this.response = r; this.message = ''; } catch (error) { if (!this.active || generation !== this.generation) return; this.response = undefined; this.message = stage47ErrorText(error as Object, '投票刷新失败。'); } finally { if (this.active && generation === this.generation) this.busy = false; } }

  // 清空挑卡片的状态。
  private resetPicker(): void { this.candidates = []; this.selectedIds = []; this.exhausted = false; }
  // 当前投票已有的卡片编号（补充时排除）。
  private existingCardIds(): Array<string> {
    const ids: Array<string> = [];
    if (this.response !== undefined) for (const option of this.response.options) if (option.card !== null) ids.push(option.card.id);
    return ids;
  }
  // 还能再选几张（发起时 12 张；补充时扣除已有选项）。
  private remainingSlots(): number {
    const used: number = this.response === undefined ? 0 : this.response.options.length;
    return Math.max(0, MAX_POLL_OPTIONS - used - this.selectedIds.length);
  }
  // 重新搜索：清空已加载的候选（保留已选卡片），再加载一批。
  private search(): void {
    const kept: Array<MealCandidate> = this.candidates.filter((c: MealCandidate): boolean => this.selectedIds.includes(c.card.id));
    this.candidates = kept; this.exhausted = false; void this.loadCandidates();
  }
  // 加载一批候选卡片（服务端每次最多 3 张，已加载和已在投票里的会被排除）。
  private async loadCandidates(): Promise<void> {
    if (this.busy) return;
    const generation: number = this.generation; this.busy = true; this.message = '';
    try {
      const excluded: Array<string> = this.candidates.map((c: MealCandidate): string => c.card.id).concat(this.existingCardIds());
      const query: MealQuery = { keyword: this.keyword.trim(), mode: 'ALL', categories: [], source: this.source, nearby: false,
        radiusMeters: 1000, coordinateSystem: 'GCJ02', excludedCardIds: excluded };
      const page: MealCandidatePage = await this.repo.candidates(query);
      if (!this.active || generation !== this.generation) return;
      this.candidates = this.candidates.concat(page.candidates);
      this.exhausted = page.sessionExhausted || page.candidates.length === 0;
    } catch (error) {
      if (!this.active || generation !== this.generation) return;
      this.message = stage47ErrorText(error as Object, '候选加载失败。');
    } finally { if (this.active && generation === this.generation) this.busy = false; }
  }
  // 勾选 / 取消勾选一张卡片。
  private toggleCard(cardId: string): void {
    if (this.selectedIds.includes(cardId)) { this.selectedIds = this.selectedIds.filter((id: string): boolean => id !== cardId); return; }
    if (this.remainingSlots() <= 0) { this.message = `候选最多 ${MAX_POLL_OPTIONS} 个。`; return; }
    this.selectedIds = this.selectedIds.concat([cardId]); this.message = '';
  }
  // 已选卡片对应的候选（保持勾选顺序）。
  private selectedCards(): Array<FoodCard> {
    const cards: Array<FoodCard> = [];
    for (const id of this.selectedIds) { const found: MealCandidate | undefined = this.candidates.find((c: MealCandidate): boolean => c.card.id === id); if (found !== undefined) cards.push(found.card); }
    return cards;
  }

  // 截止时间（毫秒时间戳）；不截止返回 null，自定义值无效时抛错。
  private deadlineAt(): number | null {
    if (this.deadlinePreset === 0) return null;
    const minutes: number = this.deadlinePreset === -1 ? Number(this.customMinutes.trim()) : this.deadlinePreset;
    if (!Number.isInteger(minutes) || minutes < 1 || minutes > 10080) throw new Error('自定义截止时间为 1–10080 分钟（最长 7 天）。');
    return Date.now() + minutes * 60000;
  }
  // 发起投票：创建投票，再把所选卡片逐张加进去。创建或添加失败时保留进度，重试会从断点继续。
  private async create(): Promise<void> {
    if (this.busy) return;
    const generation: number = this.generation; this.busy = true; this.message = '';
    try {
      if (this.createRequest === undefined && this.response === undefined) {
        if (this.title.trim().length === 0 || this.title.trim().length > 50) throw new Error('标题需为 1–50 个字。');
        this.createRequest = { requestId: util.generateRandomUUID(), groupId: this.groupId, title: this.title.trim(), mode: 'CARD',
          visibilityMode: this.anonymous ? 'ANONYMOUS' : 'NAMED', consumptionMode: 'ANY', deadlineAt: this.deadlineAt() };
        this.pendingAddIds = this.selectedIds.slice();
      }
      if (this.response === undefined && this.createRequest !== undefined) {
        const created: MealPollResponse = await this.repo.createPoll(this.createRequest);
        if (!this.active || generation !== this.generation) return;
        this.activePollId = created.poll.pollId; this.response = created; this.createRequest = undefined;
      }
      const failed: number = await this.addPending(generation);
      if (!this.active || generation !== this.generation) return;
      if (failed === 0) { this.resetPicker(); this.step = 'PICK'; this.poller.reset(); }
    } catch (error) {
      if (!this.active || generation !== this.generation) return;
      this.message = stage47ErrorText(error as Object, '创建未确认，请用原设置重试。');
    } finally { if (this.active && generation === this.generation) this.busy = false; }
  }
  // 逐张添加 pendingAddIds 中的卡片：“候选已存在”视为成功；群里有人看不到的卡片跳过并提示；其他错误中断，保留剩余进度。
  // 返回仍未添加的数量。
  private async addPending(generation: number): Promise<number> {
    const cards: Array<FoodCard> = this.selectedCards();
    const skipped: Array<string> = [];
    while (this.pendingAddIds.length > 0) {
      const response: MealPollResponse | undefined = this.response;
      if (response === undefined) break;
      const cardId: string = this.pendingAddIds[0];
      const card: FoodCard | undefined = cards.find((c: FoodCard): boolean => c.id === cardId);
      if (card === undefined) { this.pendingAddIds.shift(); continue; }
      const request: MealPollMutationRequest = { pollId: response.poll.pollId, version: response.poll.version, cardId: card.id, merchantId: card.merchantId };
      try {
        const result: MealPollResponse = await this.repo.mutatePoll('add-meal-poll-option', request);
        if (!this.active || generation !== this.generation) return this.pendingAddIds.length;
        this.response = result;
      } catch (error) {
        if (!this.active || generation !== this.generation) return this.pendingAddIds.length;
        const detail: PollErrorDetail = error as PollErrorDetail;
        const code: string = String(detail.code || '');
        const text: string = String(detail.message || '');
        if (!(code === 'CONFLICT' && text.includes('候选已存在'))) {
          if (code !== 'CONTENT_UNAVAILABLE' && code !== 'FORBIDDEN') {
            this.message = `${stage47ErrorText(error as Object, '添加卡片失败。')}还有 ${this.pendingAddIds.length} 张未添加，可重试继续添加。`;
            return this.pendingAddIds.length;
          }
          skipped.push(card.productName);
        }
      }
      this.pendingAddIds.shift();
    }
    if (skipped.length > 0) this.message = `群里有成员看不到这些卡片，已跳过：${skipped.join('、')}`;
    return this.pendingAddIds.length;
  }
  // 投票进行中补充卡片：把所选卡片逐张加入当前投票。
  private async addSelected(): Promise<void> {
    if (this.busy || this.selectedIds.length === 0) return;
    const generation: number = this.generation; this.busy = true; this.message = '';
    if (this.pendingAddIds.length === 0) this.pendingAddIds = this.selectedIds.slice();
    try {
      const failed: number = await this.addPending(generation);
      if (!this.active || generation !== this.generation) return;
      if (failed === 0) { this.resetPicker(); this.adding = false; this.poller.reset(); }
    } finally { if (this.active && generation === this.generation) this.busy = false; }
  }
  // 打开补充卡片面板。
  private startAdding(): void { this.resetPicker(); this.pendingAddIds = []; this.keyword = ''; this.adding = true; void this.loadCandidates(); }

  // 投票变更（投票 / 截止 / 取消 / 停止补充），完成后刷新。
  private async mutate(operation: string, optionId: string = ''): Promise<void> { const generation: number = this.generation; const response: MealPollResponse | undefined = this.response; if (response === undefined || this.busy) return; let failed: boolean = false; this.busy = true; try { const p: MealPollMutationRequest = { pollId: response.poll.pollId, version: response.poll.version, optionId }; const result: MealPollResponse = await this.repo.mutatePoll(operation, p); if (!this.active || generation !== this.generation) return; this.response = result; this.message = ''; this.poller.reset(); } catch (error) { if (!this.active || generation !== this.generation) return; failed = true; this.message = stage47ErrorText(error as Object, '操作失败，请刷新。'); } finally { if (this.active && generation === this.generation) this.busy = false; if (failed && this.active && generation === this.generation) void this.refresh(); } }
  // 当前用户是否为投票发起人（只有发起人可以截止 / 取消 / 停止补充）。
  private creator(): boolean { const profile = AuthService.profile(); return profile !== undefined && this.response !== undefined && profile.uid === this.response.poll.creatorUid; }
  // 选项显示名称（不可访问的候选单独提示）。
  private optionName(option: MealPollOption): string { return !option.accessible ? '候选已不可访问' : option.card !== null ? option.card.productName : option.merchant !== null ? option.merchant.name : '候选'; }
  // 按票数从高到低排列的选项（票数相同保持原顺序）。
  private rankedOptions(): Array<MealPollOption> {
    if (this.response === undefined) return [];
    const options: Array<MealPollOption> = this.response.options.slice();
    const order: Map<string, number> = new Map<string, number>();
    options.forEach((o: MealPollOption, i: number): void => { order.set(o.optionId, i); });
    return options.sort((a: MealPollOption, b: MealPollOption): number => (b.voteCount - a.voteCount) || ((order.get(a.optionId) || 0) - (order.get(b.optionId) || 0)));
  }
  // 已加载的投票（只在 response 已确定存在的视图中调用）。
  private current(): MealPollResponse { return this.response as MealPollResponse; }
  // 总票数（每人一票）。
  private totalVotes(): number { return this.response === undefined ? 0 : this.response.options.reduce((sum: number, o: MealPollOption): number => sum + o.voteCount, 0); }
  // 顶部要突出的选项：结束后是最终选定的，进行中是票数最多的（还没人投票时没有）。
  private highlightOption(): MealPollOption | undefined {
    const response: MealPollResponse | undefined = this.response;
    if (response === undefined) return undefined;
    if (response.poll.status === 'CLOSED') return response.options.find((o: MealPollOption): boolean => o.optionId === response.poll.winnerOptionId);
    const ranked: Array<MealPollOption> = this.rankedOptions();
    return ranked.length > 0 && ranked[0].voteCount > 0 ? ranked[0] : undefined;
  }
  // 顶部突出选项的图片（直接读状态，领先者变化时随之刷新）。
  private highlightImage(): ResourceStr {
    const option: MealPollOption | undefined = this.highlightOption();
    const card: FoodCard | null = option === undefined ? null : option.card;
    if (card === null) return $r('app.media.food_other');
    return card.photoUrl.length > 0 ? card.photoUrl : coverFor(card.category);
  }
  // 状态文字：进行中显示剩余时间。
  private statusText(): string {
    const response: MealPollResponse | undefined = this.response;
    if (response === undefined) return '';
    if (response.poll.status === 'CLOSED') return '投票已结束';
    if (response.poll.status === 'CANCELLED') return '投票已取消';
    if (response.poll.deadlineAt === null) return '投票进行中 · 不自动截止';
    const left: number = Math.max(0, Math.ceil((response.poll.deadlineAt - Date.now()) / 60000));
    return left >= 60 ? `投票进行中 · 还剩 ${Math.floor(left / 60)} 小时 ${left % 60} 分钟` : `投票进行中 · 还剩 ${left} 分钟`;
  }

  // 卡片缩略图。
  @Builder
  private thumb(card: FoodCard | null, size: number): void {
    if (card !== null) {
      Image(card.photoUrl.length > 0 ? card.photoUrl : coverFor(card.category)).width(size).height(size)
        .objectFit(ImageFit.Cover).borderRadius(10).syncLoad(false)
    } else {
      Column().width(size).height(size).borderRadius(10).backgroundColor($r('app.color.social_soft'))
    }
  }

  // 挑卡片区域（发起第 1 步与补充卡片共用）。
  @Builder
  private picker(): void {
    Row({ space: 8 }) {
      TextInput({ text: this.keyword, placeholder: '搜索菜品或店名' }).attributeModifier(new FormInputStyle('SOCIAL')).layoutWeight(1)
        .constraintSize({ minHeight: 44 }).enterKeyType(EnterKeyType.Search)
        .onChange((v: string): void => { this.keyword = v; }).onSubmit((): void => this.search())
      Button('搜索').constraintSize({ minHeight: 44 }).enabled(!this.busy).onClick((): void => this.search()).attributeModifier(new SecondaryActionStyle('SOCIAL'))
    }.width('100%')
    Row({ space: 6 }) {
      Button('全部').constraintSize({ minHeight: 36 }).fontSize(13).enabled(!this.busy).onClick((): void => { this.source = 'ALL'; this.search(); }).attributeModifier(new ChoiceActionStyle(this.source === 'ALL', 'SOCIAL'))
      Button('我收藏的').constraintSize({ minHeight: 36 }).fontSize(13).enabled(!this.busy).onClick((): void => { this.source = 'MY_COLLECTIONS'; this.search(); }).attributeModifier(new ChoiceActionStyle(this.source === 'MY_COLLECTIONS', 'SOCIAL'))
      Button('好友的').constraintSize({ minHeight: 36 }).fontSize(13).enabled(!this.busy).onClick((): void => { this.source = 'FRIENDS_ONLY'; this.search(); }).attributeModifier(new ChoiceActionStyle(this.source === 'FRIENDS_ONLY', 'SOCIAL'))
      Button('公开').constraintSize({ minHeight: 36 }).fontSize(13).enabled(!this.busy).onClick((): void => { this.source = 'PUBLIC_ONLY'; this.search(); }).attributeModifier(new ChoiceActionStyle(this.source === 'PUBLIC_ONLY', 'SOCIAL'))
    }.width('100%')
    ForEach(this.candidates, (candidate: MealCandidate): void => {
      Row({ space: 10 }) {
        Text(this.selectedIds.includes(candidate.card.id) ? '✓' : '').width(22).height(22).borderRadius(6).textAlign(TextAlign.Center)
          .fontSize(13).fontColor(Color.White)
          .backgroundColor(this.selectedIds.includes(candidate.card.id) ? $r('app.color.social_action') : Color.Transparent)
          .border({ width: 1.5, color: this.selectedIds.includes(candidate.card.id) ? $r('app.color.social_action') : $r('app.color.social_accent') })
        this.thumb(candidate.card, 44)
        Column({ space: 2 }) {
          Text(candidate.card.productName).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.social_ink')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text([shopName(candidate.card), candidate.reasons.length > 0 ? candidate.reasons[0] : ''].filter((s: string): boolean => s.length > 0).join(' · '))
            .fontSize(12).fontColor($r('app.color.social_muted')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text('详情').fontSize(12).fontColor($r('app.color.social_action')).padding(6).onClick((): void => this.onOpenCard(candidate.card))
      }.width('100%').padding(8).backgroundColor($r('app.color.social_surface')).borderRadius(12)
      .border({ width: this.selectedIds.includes(candidate.card.id) ? 2 : 1, color: this.selectedIds.includes(candidate.card.id) ? $r('app.color.social_action') : $r('app.color.social_line') })
      .onClick((): void => this.toggleCard(candidate.card.id))
      .accessibilityText((this.selectedIds.includes(candidate.card.id) ? '已选 ' : '未选 ') + candidate.card.productName)
    }, (candidate: MealCandidate): string => candidate.card.id)
    if (this.candidates.length === 0 && !this.busy) {
      Text('没有找到可选的卡片，换个关键词或来源试试。').fontSize(13).fontColor($r('app.color.social_muted'))
    }
    if (!this.exhausted) {
      Button(this.busy ? '加载中…' : '加载更多').constraintSize({ minHeight: 40 }).width('100%').enabled(!this.busy)
        .onClick((): void => { void this.loadCandidates(); }).attributeModifier(new QuietActionStyle('SOCIAL'))
    }
  }

  // 发起第 2 步：设置。
  @Builder
  private settings(): void {
    Text(`已选 ${this.selectedIds.length} 张卡片`).fontSize(13).fontColor($r('app.color.social_muted'))
    Text('标题').fontSize(13).fontColor($r('app.color.social_muted'))
    TextInput({ text: this.title }).attributeModifier(new FormInputStyle('SOCIAL')).maxLength(50).constraintSize({ minHeight: 48 })
      .onChange((v: string): void => { this.title = v; })
    Text('投票方式').fontSize(13).fontColor($r('app.color.social_muted'))
    Row({ space: 8 }) {
      Button('记名').constraintSize({ minHeight: 44 }).layoutWeight(1).onClick((): void => { this.anonymous = false; }).attributeModifier(new ChoiceActionStyle(!this.anonymous, 'SOCIAL'))
      Button('匿名').constraintSize({ minHeight: 44 }).layoutWeight(1).onClick((): void => { this.anonymous = true; }).attributeModifier(new ChoiceActionStyle(this.anonymous, 'SOCIAL'))
    }.width('100%')
    Text(this.anonymous ? '匿名：群里只看到票数' : '记名：群里能看到谁投了哪项').fontSize(12).fontColor($r('app.color.social_muted'))
    Text('截止时间').fontSize(13).fontColor($r('app.color.social_muted'))
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(DEADLINE_PRESETS, (minutes: number): void => {
        Button(deadlineLabel(minutes)).constraintSize({ minHeight: 36 }).fontSize(13).margin({ right: 6, bottom: 6 })
          .onClick((): void => { this.deadlinePreset = minutes; })
          .attributeModifier(new ChoiceActionStyle(this.deadlinePreset === minutes, 'SOCIAL'))
      }, (minutes: number): string => minutes.toString())
    }.width('100%')
    if (this.deadlinePreset === -1) {
      TextInput({ text: this.customMinutes, placeholder: '分钟数（1–10080）' }).type(InputType.Number).attributeModifier(new FormInputStyle('SOCIAL'))
        .constraintSize({ minHeight: 44 }).onChange((v: string): void => { this.customMinutes = v; })
    }
  }

  // 发起向导。
  @Builder
  private createWizard(): void {
    Row({ space: 6 }) {
      Text('1').width(20).height(20).borderRadius(10).textAlign(TextAlign.Center).fontSize(12).fontColor(Color.White).backgroundColor($r('app.color.social_action'))
      Text('挑卡片').fontSize(13).fontColor(this.step === 'PICK' ? $r('app.color.social_ink') : $r('app.color.social_muted'))
      Text('——').fontSize(12).fontColor($r('app.color.social_line'))
      Text('2').width(20).height(20).borderRadius(10).textAlign(TextAlign.Center).fontSize(12)
        .fontColor(this.step === 'SETTINGS' ? Color.White : $r('app.color.social_muted'))
        .backgroundColor(this.step === 'SETTINGS' ? $r('app.color.social_action') : $r('app.color.social_line'))
      Text('设置').fontSize(13).fontColor(this.step === 'SETTINGS' ? $r('app.color.social_ink') : $r('app.color.social_muted'))
    }
    if (this.step === 'PICK') {
      this.picker()
      Button(`下一步（已选 ${this.selectedIds.length}）`).constraintSize({ minHeight: 48 }).width('100%')
        .enabled(!this.busy && this.selectedIds.length >= MIN_CREATE_OPTIONS)
        .onClick((): void => { this.step = 'SETTINGS'; this.message = ''; }).attributeModifier(new PrimaryActionStyle('SOCIAL'))
      if (this.selectedIds.length < MIN_CREATE_OPTIONS) {
        Text(`至少选 ${MIN_CREATE_OPTIONS} 张卡片`).fontSize(12).fontColor($r('app.color.social_muted')).width('100%').textAlign(TextAlign.Center)
      }
    } else {
      Column({ space: 10 }) { this.settings() }.alignItems(HorizontalAlign.Start).width('100%').enabled(this.createRequest === undefined && !this.busy)
      if (this.createRequest !== undefined) { Text('创建结果尚未确认。重试会沿用原设置与请求编号，不会重复创建。').fontSize(12).fontColor($r('app.color.social_muted')) }
      Row({ space: 8 }) {
        Button('上一步').constraintSize({ minHeight: 48 }).enabled(!this.busy && this.createRequest === undefined)
          .onClick((): void => { this.step = 'PICK'; this.message = ''; }).attributeModifier(new SecondaryActionStyle('SOCIAL'))
        Button(this.createRequest === undefined ? `发起投票（${this.selectedIds.length} 个选项）` : '重试发起').constraintSize({ minHeight: 48 }).layoutWeight(1)
          .enabled(!this.busy).onClick((): void => { void this.create(); }).attributeModifier(new PrimaryActionStyle('SOCIAL'))
      }.width('100%')
    }
  }

  // 排行榜中的一行。
  @Builder
  private rankRow(option: MealPollOption, rank: number): void {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        Text(rank.toString()).fontSize(17).fontWeight(FontWeight.Bold).fontColor($r('app.color.social_action')).width(20).textAlign(TextAlign.Center)
        this.thumb(option.card, 40)
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(this.optionName(option)).fontSize(15).fontWeight(FontWeight.Medium).fontColor(option.accessible ? $r('app.color.social_ink') : $r('app.color.social_muted'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
            if (this.current().myVote === option.optionId) {
              Text('我投的').fontSize(11).fontColor($r('app.color.social_on_accent')).backgroundColor($r('app.color.social_soft')).borderRadius(8).padding({ left: 6, right: 6, top: 1, bottom: 1 })
            }
          }
          if (option.card !== null && shopName(option.card).length > 0) {
            Text(shopName(option.card)).fontSize(12).fontColor($r('app.color.social_muted')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(`${option.voteCount} 票`).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.social_on_accent'))
      }.width('100%')
      Progress({ value: option.voteCount, total: Math.max(this.totalVotes(), 1), type: ProgressType.Linear }).width('100%').height(6)
        .color($r('app.color.social_action')).backgroundColor($r('app.color.social_soft'))
      if (option.voters !== undefined && option.voters.length > 0) {
        Text(option.voters.map((v: PollVoter): string => v.nickname).join('、')).fontSize(12).fontColor($r('app.color.social_muted')).width('100%')
      }
      if (option.card !== null) {
        Text('查看详情').fontSize(12).fontColor($r('app.color.social_action'))
          .onClick((): void => { const card: FoodCard | null = option.card; if (card !== null) this.onOpenCard(card); })
      }
    }.width('100%').padding(10).alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.social_surface')).borderRadius(12)
    .border({ width: this.current().myVote === option.optionId ? 2 : 1, color: this.current().myVote === option.optionId ? $r('app.color.social_action') : $r('app.color.social_line') })
    .onClick((): void => {
      if (!this.busy && this.response !== undefined && option.accessible && this.current().poll.status === 'OPEN' && this.current().myVote !== option.optionId) void this.mutate('vote-meal-poll', option.optionId);
    })
    .accessibilityText(`${this.optionName(option)}，${option.voteCount} 票${this.current().myVote === option.optionId ? '，我投的' : ''}`)
  }

  // 投票进行中 / 已结束的排行榜视图。
  @Builder
  private leaderboard(): void {
    Text(this.current().poll.title).fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.social_ink'))
    Row({ space: 8 }) {
      Text(this.statusText()).fontSize(12).fontColor($r('app.color.social_on_accent')).backgroundColor($r('app.color.social_soft'))
        .borderRadius(10).padding({ left: 8, right: 8, top: 2, bottom: 2 })
      Text(this.current().poll.visibilityMode === 'ANONYMOUS' ? '匿名' : '记名').fontSize(12).fontColor($r('app.color.social_muted'))
    }
    // 顶部：领先 / 最终选定。
    Column({ space: 6 }) {
      if (this.current().poll.status === 'CLOSED' && this.current().poll.closeOutcome === 'NO_RESULT') {
        Text('没有结果').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.social_ink'))
        Text('没有有效的候选或投票，可以重新发起一次。').fontSize(12).fontColor($r('app.color.social_muted'))
      } else if (this.highlightOption() !== undefined) {
        Text(this.current().poll.status === 'CLOSED' ? '最终选定' : '目前领先').fontSize(12).fontColor($r('app.color.social_muted'))
        Image(this.highlightImage()).width(72).height(72).objectFit(ImageFit.Cover).borderRadius(12).syncLoad(false)
        Text(this.optionName(this.highlightOption() as MealPollOption)).fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.social_ink'))
      } else if (this.current().poll.status === 'OPEN') {
        Text('还没有人投票').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.social_ink'))
        Text('点下面的选项投出第一票').fontSize(12).fontColor($r('app.color.social_muted'))
      }
      Text(this.memberCount > 0 ? `${this.memberCount} 人中 ${this.totalVotes()} 人已投` : `共 ${this.totalVotes()} 票`).fontSize(12).fontColor($r('app.color.social_muted'))
    }.width('100%').padding(14).backgroundColor($r('app.color.social_surface')).borderRadius(14)
    .border({ width: 1, color: $r('app.color.social_line') })
    if (this.current().poll.status === 'OPEN') {
      Text(this.current().myVote.length > 0 ? '点其他选项可以改票' : '点选项即可投票').fontSize(12).fontColor($r('app.color.social_muted'))
    }
    ForEach(this.rankedOptions(), (option: MealPollOption, index: number): void => {
      this.rankRow(option, index + 1)
    }, (option: MealPollOption): string => option.optionId + ':' + option.voteCount + ':' + (this.current().myVote === option.optionId))
    if (this.current().poll.status === 'OPEN' && this.current().poll.acceptingOptions && this.current().options.length < MAX_POLL_OPTIONS) {
      Button('＋ 补充一张卡片').constraintSize({ minHeight: 44 }).width('100%').enabled(!this.busy)
        .onClick((): void => this.startAdding()).attributeModifier(new SecondaryActionStyle('SOCIAL'))
    } else if (this.current().poll.status === 'OPEN' && !this.current().poll.acceptingOptions) {
      Text('发起人已停止补充卡片').fontSize(12).fontColor($r('app.color.social_muted'))
    }
    if (this.pendingAddIds.length > 0) {
      Button('继续添加剩余卡片').constraintSize({ minHeight: 44 }).width('100%').enabled(!this.busy)
        .onClick((): void => { void this.create(); }).attributeModifier(new SecondaryActionStyle('SOCIAL'))
    }
    if (this.creator() && this.current().poll.status === 'OPEN') {
      Row({ space: 8 }) {
        if (this.current().poll.acceptingOptions) {
          Button('停止补充').constraintSize({ minHeight: 44 }).fontSize(13).layoutWeight(1).enabled(!this.busy)
            .onClick((): void => { void this.mutate('stop-meal-poll-options'); }).attributeModifier(new SecondaryActionStyle('SOCIAL'))
        }
        Button('提前结束').constraintSize({ minHeight: 44 }).fontSize(13).layoutWeight(1).enabled(!this.busy)
          .onClick((): void => { void this.mutate('close-meal-poll'); }).attributeModifier(new SecondaryActionStyle('SOCIAL'))
        Button('取消投票').constraintSize({ minHeight: 44 }).fontSize(13).layoutWeight(1).enabled(!this.busy)
          .onClick((): void => { void this.mutate('cancel-meal-poll'); }).attributeModifier(new DangerActionStyle('SOCIAL'))
      }.width('100%')
    }
    Button('刷新').constraintSize({ minHeight: 40 }).enabled(!this.busy).onClick((): void => { void this.refresh(); }).attributeModifier(new QuietActionStyle('SOCIAL'))
  }

  // 补充卡片面板。
  @Builder
  private addPanel(): void {
    Text('补充卡片').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.social_ink'))
    Text(`还能加 ${this.remainingSlots()} 张`).fontSize(12).fontColor($r('app.color.social_muted'))
    this.picker()
    Row({ space: 8 }) {
      Button('取消').constraintSize({ minHeight: 48 }).enabled(!this.busy)
        .onClick((): void => { this.adding = false; this.resetPicker(); this.pendingAddIds = []; this.message = ''; }).attributeModifier(new SecondaryActionStyle('SOCIAL'))
      Button(`加入投票（${this.selectedIds.length}）`).constraintSize({ minHeight: 48 }).layoutWeight(1)
        .enabled(!this.busy && this.selectedIds.length > 0).onClick((): void => { void this.addSelected(); }).attributeModifier(new PrimaryActionStyle('SOCIAL'))
    }.width('100%')
  }

  // 页面布局。
  build() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.response === undefined) {
          if (this.activePollId.length === 0 && this.pollId.length === 0) {
            Text('发起选餐').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.social_ink'))
            if (this.message.length > 0) { Text(this.message).fontSize(13).lineHeight(20).fontColor($r('app.color.danger')) }
            this.createWizard()
          } else {
            Text('群共同选餐').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.social_ink'))
            if (this.message.length > 0) { Text(this.message).fontSize(13).lineHeight(20).fontColor($r('app.color.danger')) }
            Text(this.busy ? '正在加载投票…' : '正在重新校验群成员资格与投票内容。').fontSize(13).fontColor($r('app.color.social_muted'))
            Button('重新加载').constraintSize({ minHeight: 48 }).enabled(!this.busy).onClick((): void => { void this.refresh(); }).attributeModifier(new SecondaryActionStyle('SOCIAL'))
          }
        } else if (this.adding) {
          if (this.message.length > 0) { Text(this.message).fontSize(13).lineHeight(20).fontColor($r('app.color.danger')) }
          this.addPanel()
        } else {
          if (this.message.length > 0) { Text(this.message).fontSize(13).lineHeight(20).fontColor($r('app.color.danger')) }
          this.leaderboard()
        }
        Button('返回群聊').constraintSize({ minHeight: 44 }).enabled(!this.busy).onClick((): void => this.onDone()).attributeModifier(new QuietActionStyle('SOCIAL'))
      }.width('100%').padding(16).backgroundColor($r('app.color.social_surface')).borderRadius(18)
      .border({ width: 1, color: $r('app.color.social_line') }).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').align(Alignment.TopStart).padding(14).backgroundColor($r('app.color.social_canvas'))
    .onVisibleAreaChange([0, 1], (_visible: boolean, ratio: number): void => this.onVisibilityChanged(ratio > 0))
  }
}
