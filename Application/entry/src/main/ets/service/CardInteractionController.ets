import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { CardReactionType } from '../model/CloudContracts';
import { InteractionReaction, InteractionState, InteractionCommit, InteractionReceipt, InteractionCounts,
  InteractionPatch, InteractionExpected, InteractionWriteRequest, InteractionJournal, InteractionView,
  validInteractionReaction } from '../model/CardInteractionModels';
import { CardInteractionRepository } from '../repository/CardInteractionRepository';
import { AccountRequestGuard } from './AccountRequestGuard';
import { AuthSessionStore } from './AuthSessionStore';
import { CloudBusinessError, ReadCancelledError } from './CloudReadErrors';
import { ReadRequestOptions } from './ReadScheduler';

const JOURNAL_STORE: string = 'shike_card_interaction_v3';
const JOURNAL_TTL: number = 24 * 60 * 60 * 1000;
const COUNTS_MAX_RETRIES: number = 3;
type InteractionListener = (view: InteractionView) => void;

/** Per account/card coordinator outlives the page. A UI deadline never releases a write slot. */
export class CardInteractionController {
  private static controllers: Map<string, CardInteractionController> = new Map<string, CardInteractionController>();
  private static wires: Map<string, Promise<void>> = new Map<string, Promise<void>>();
  private static flushTail: Promise<void> = Promise.resolve();
  private readonly owner: string;
  private readonly session: number;
  private readonly cardId: string;
  private readonly key: string;
  private readonly store: preferences.Preferences;
  private repository: CardInteractionRepository = new CardInteractionRepository();
  private listeners: Map<number, InteractionListener> = new Map<number, InteractionListener>();
  private listenerId: number = 0;
  private confirmed: InteractionState | undefined = undefined;
  private counts: InteractionCounts | undefined = undefined;
  private desiredReaction: InteractionReaction | undefined = undefined;
  private desiredFavorite: boolean | undefined = undefined;
  private pending: InteractionJournal | undefined = undefined;
  private wireBusy: boolean = false;
  private journalBusy: boolean = false;
  private recovering: boolean = false;
  private stateFlight: Promise<void> | undefined = undefined;
  private stateAgain: boolean = false;
  private favoriteRevision: number = 0;
  private countsTimer: number = -1;
  private countsBusy: boolean = false;
  private countsAgain: boolean = false;
  private deadline: number = -1;
  private message: string = '';
  private countsMessage: string = '';
  // Incremented on every applied write receipt. A read that starts and ends in a
  // quiet period (no journal, wire, desire or new receipt) is authoritative even
  // when its version is lower than the cached one.
  private ackSeq: number = 0;
  private countsRetries: number = 0;
  // One automatic receipt check plus same-UUID resend after a transport failure.
  private autoRecover: InteractionJournal | undefined = undefined;
  private autoRetried: string = '';

  static forCard(context: common.Context, cardId: string): CardInteractionController {
    const owner: string = AccountRequestGuard.owner();
    if (owner.length === 0) throw new Error('请先登录。');
    const key: string = encodeURIComponent(owner) + ':' + encodeURIComponent(cardId);
    let controller: CardInteractionController | undefined = CardInteractionController.controllers.get(key);
    if (controller === undefined || !controller.current()) {
      controller = new CardInteractionController(context, owner, cardId, key);
      CardInteractionController.controllers.set(key, controller);
    }
    return controller;
  }
  private constructor(context: common.Context, owner: string, cardId: string, key: string) {
    this.owner = owner; this.cardId = cardId; this.key = key; this.session = AuthSessionStore.generation();
    this.store = preferences.getPreferencesSync(context, { name: JOURNAL_STORE });
    this.favoriteRevision = AppStorage.get<number>('favoritesMutationRevision') || 0;
    this.restoreJournal();
  }
  private current(): boolean { return this.owner === AccountRequestGuard.owner() && this.session === AuthSessionStore.generation(); }
  subscribe(listener: InteractionListener): () => void {
    const id: number = ++this.listenerId;
    this.listeners.set(id, listener); listener(this.view());
    return (): void => {
      this.listeners.delete(id);
      if (this.listeners.size === 0 && this.countsTimer !== -1) { clearTimeout(this.countsTimer); this.countsTimer = -1; }
    };
  }
  needsFavoriteRefresh(): boolean {
    return this.favoriteRevision !== (AppStorage.get<number>('favoritesMutationRevision') || 0);
  }
  private quiet(): boolean {
    return !this.wireBusy && !this.journalBusy && this.pending === undefined &&
      this.desiredReaction === undefined && this.desiredFavorite === undefined;
  }
  private emit(): void {
    if (!this.current()) return;
    const view: InteractionView = this.view();
    this.listeners.forEach((listener: InteractionListener): void => { listener(view); });
  }
  private view(): InteractionView {
    const state: InteractionState | undefined = this.confirmed;
    const job: InteractionWriteRequest | undefined = this.pending?.request;
    const jobReaction: InteractionReaction | undefined = job?.patch.reaction;
    const jobFavorite: boolean | undefined = job?.patch.favorited;
    // While this session automatically re-checks/resends its own unknown write, keep
    // showing the user's intent instead of flashing back to the old state.
    const retrying: boolean = job !== undefined && this.autoRetried === job.requestId &&
      (this.autoRecover !== undefined || this.recovering || this.wireBusy);
    const sending: boolean = this.wireBusy || this.journalBusy || retrying;
    // An old uncertain intent is retained for retry, but must not masquerade
    // as the server state just read after re-entering the page.
    const reaction: InteractionReaction = this.desiredReaction !== undefined && (jobReaction === undefined || sending)
      ? this.desiredReaction : sending && jobReaction !== undefined ? jobReaction : state?.myReaction || '';
    const favorited: boolean = this.desiredFavorite !== undefined && (jobFavorite === undefined || sending)
      ? this.desiredFavorite : sending && jobFavorite !== undefined ? jobFavorite : state?.viewerFavorited === true;
    const view: InteractionView = {
      known: state !== undefined, reaction, favorited,
      reactionsEnabled: state?.reactionsEnabled === true, reactionsReason: state?.reactionsReason || '',
      collectionEnabled: state?.collectionEnabled === true, collectionReady: state?.collectionReady === true,
      collectionReason: state?.collectionReason || '',
      reactionBusy: this.desiredReaction !== undefined || job?.patch.reaction !== undefined,
      favoriteBusy: this.desiredFavorite !== undefined || job?.patch.favorited !== undefined,
      recovering: this.recovering, canRetry: this.pending !== undefined && !this.wireBusy && !this.journalBusy && !this.recovering &&
        this.autoRecover === undefined,
      likeCount: this.counts?.likeCount || 0, dislikeCount: this.counts?.dislikeCount || 0,
      favoriteCount: this.counts?.favoriteCount || 0, countsKnown: this.counts !== undefined,
      message: this.message, countsMessage: this.countsMessage
    };
    return view;
  }
  private restoreJournal(): void {
    const raw: preferences.ValueType = this.store.getSync(this.key, '');
    if (typeof raw !== 'string' || raw.length === 0) return;
    try {
      const saved: InteractionJournal = JSON.parse(raw) as InteractionJournal;
      const request: InteractionWriteRequest = saved.request;
      if (saved.owner !== this.owner || request === undefined || request.cardId !== this.cardId ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(request.requestId) || !Number.isSafeInteger(saved.createdAt) || saved.createdAt < 0 ||
        saved.createdAt > Date.now() || Date.now() - saved.createdAt > JOURNAL_TTL || request.patch === undefined || request.expected === undefined ||
        !Number.isSafeInteger(request.expected.writeVersion) || request.expected.writeVersion < 0 ||
        (request.patch.reaction === undefined && request.patch.favorited === undefined) ||
        (request.patch.reaction !== undefined && (!validInteractionReaction(request.patch.reaction) || typeof request.expected.myReaction !== 'string' || !validInteractionReaction(request.expected.myReaction))) ||
        (request.patch.favorited !== undefined && (typeof request.patch.favorited !== 'boolean' || typeof request.expected.viewerFavorited !== 'boolean'))) {
        this.store.deleteSync(this.key); void this.queueFlush().catch((): void => {}); return;
      }
      this.pending = saved;
      this.message = '正在核对上次操作结果…';
    } catch (_error) { this.message = '本地操作记录不可读取，请刷新状态后重新选择。'; }
  }
  private queueFlush(): Promise<void> {
    const next: Promise<void> = CardInteractionController.flushTail.then((): Promise<void> => this.store.flush());
    CardInteractionController.flushTail = next.catch((): void => {});
    return next;
  }
  private async persist(job: InteractionJournal): Promise<void> {
    this.store.putSync(this.key, JSON.stringify(job)); await this.queueFlush();
  }
  private clearPending(): void {
    this.pending = undefined;
    try {
      this.store.deleteSync(this.key);
      void this.queueFlush().catch((): void => { console.warn('[CardInteraction] stage=journal_cleanup_failed'); });
    }
    catch (_error) { console.warn('[CardInteraction] stage=journal_cleanup_failed'); }
  }
  async refreshState(keepMessage: boolean = false): Promise<void> {
    if (!this.current()) return;
    const existing: Promise<void> | undefined = this.stateFlight;
    if (existing !== undefined) { if (this.needsFavoriteRefresh()) this.stateAgain = true; return existing; }
    const flight: Promise<void> = this.readState(keepMessage); this.stateFlight = flight;
    try { await flight; } finally {
      if (this.stateFlight === flight) this.stateFlight = undefined;
      if (this.stateAgain) { this.stateAgain = false; void this.refreshState(keepMessage); }
    }
  }
  private async readState(keepMessage: boolean): Promise<void> {
    const favoriteRevision: number = AppStorage.get<number>('favoritesMutationRevision') || 0;
    const ackSeq: number = this.ackSeq;
    const quietAtStart: boolean = this.quiet();
    try {
      const result: InteractionState = await this.repository.state(this.cardId);
      if (!this.current()) return;
      const authoritative: boolean = quietAtStart && ackSeq === this.ackSeq && this.quiet();
      const newer: boolean = this.confirmed === undefined || result.writeVersion >= this.confirmed.writeVersion;
      const applied: boolean = newer || authoritative;
      console.info('[CardInteraction] stage=state_received reaction=' + result.myReaction + ' favorited=' +
        result.viewerFavorited + ' version=' + result.writeVersion + ' applied=' + applied + ' authoritative=' + authoritative);
      if (applied) {
        // A lower authoritative version means the version line changed (for example a
        // server update); cached totals cannot be adjusted against it, so recount.
        if (newer) this.applyOwnCounts(result.myReaction, result.viewerFavorited, result.writeVersion);
        else this.counts = undefined;
        this.confirmed = result;
      }
      this.favoriteRevision = favoriteRevision;
      if (this.needsFavoriteRefresh()) this.stateAgain = true;
      if (!keepMessage && this.pending === undefined && !this.wireBusy) this.message = '';
      this.emit();
      if (this.pending !== undefined) void this.recover(false);
      else this.drain();
      this.scheduleCounts();
    } catch (error) {
      if (!this.current()) return;
      this.message = '状态读取失败：' + this.errorMessage(error as Object); this.emit();
    }
  }
  chooseReaction(reaction: CardReactionType): void {
    if (!this.current() || this.view().reactionBusy) return;
    if (this.confirmed === undefined) { void this.refreshState(); return; }
    if (!this.confirmed.reactionsEnabled) { this.message = this.confirmed.reactionsReason || '点赞与不推荐暂未开放。'; this.emit(); return; }
    const started: number = Date.now();
    this.desiredReaction = this.confirmed.myReaction === reaction ? '' : reaction;
    this.message = ''; this.emit();
    console.info('[CardInteraction] stage=local_feedback kind=REACTION elapsedMs=' + (Date.now() - started));
    this.drain();
  }
  chooseFavorite(): void {
    if (!this.current() || this.view().favoriteBusy) return;
    if (this.confirmed === undefined) { void this.refreshState(); return; }
    if (!this.confirmed.collectionEnabled || !this.confirmed.collectionReady) {
      this.message = this.confirmed.collectionReason || '请先整理旧收藏。'; this.emit(); return;
    }
    const started: number = Date.now();
    this.desiredFavorite = !this.confirmed.viewerFavorited;
    this.message = ''; this.emit();
    console.info('[CardInteraction] stage=local_feedback kind=FAVORITE elapsedMs=' + (Date.now() - started));
    this.drain();
  }
  private drain(): void {
    const state: InteractionState | undefined = this.confirmed;
    if (!this.current() || this.wireBusy || this.journalBusy || this.recovering || this.pending !== undefined || state === undefined) return;
    const patch: InteractionPatch = {};
    const expected: InteractionExpected = { writeVersion: state.writeVersion };
    if (this.desiredReaction !== undefined) { patch.reaction = this.desiredReaction; expected.myReaction = state.myReaction; }
    if (this.desiredFavorite !== undefined) { patch.favorited = this.desiredFavorite; expected.viewerFavorited = state.viewerFavorited; }
    if (patch.reaction === undefined && patch.favorited === undefined) return;
    const request: InteractionWriteRequest = { cardId: this.cardId, requestId: util.generateRandomUUID(true), patch, expected };
    const job: InteractionJournal = { owner: this.owner, createdAt: Date.now(), request };
    this.pending = job; this.journalBusy = true;
    void this.persistAndTransmit(job);
  }
  private async persistAndTransmit(job: InteractionJournal): Promise<void> {
    try {
      await this.persist(job); this.journalBusy = false;
      if (this.current() && this.pending === job) this.transmit(job);
    } catch (_error) {
      this.journalBusy = false;
      if (!this.current() || this.pending !== job) return;
      this.clearPending(); this.desiredReaction = undefined; this.desiredFavorite = undefined;
      this.message = '操作记录保存失败，请重试。'; this.emit();
    }
  }
  private transmit(job: InteractionJournal): void {
    if (!this.current() || this.wireBusy || this.pending !== job) return;
    this.wireBusy = true; this.message = ''; this.emit();
    this.deadline = setTimeout((): void => {
      this.deadline = -1;
      if (this.current() && this.pending === job) void this.recover(false);
    }, 8000);
    const previous: Promise<void> | undefined = CardInteractionController.wires.get(this.key);
    const flight: Promise<void> = this.sendAfter(previous, job);
    CardInteractionController.wires.set(this.key, flight);
    void flight.then((): void => {
      if (CardInteractionController.wires.get(this.key) === flight) CardInteractionController.wires.delete(this.key);
      this.wireBusy = false;
      if (this.deadline !== -1) { clearTimeout(this.deadline); this.deadline = -1; }
      this.emit();
      if (!this.startAutoRecover()) this.drain();
    });
  }
  private startAutoRecover(): boolean {
    const job: InteractionJournal | undefined = this.autoRecover;
    if (job === undefined || !this.current() || this.pending !== job || this.wireBusy || this.journalBusy) return false;
    if (this.recovering) return true; // retried from recover()'s finally block
    this.autoRecover = undefined;
    console.info('[CardInteraction] requestId=' + job.request.requestId + ' stage=auto_recover');
    void this.recover(true);
    return true;
  }
  private async sendAfter(previous: Promise<void> | undefined, job: InteractionJournal): Promise<void> {
    if (previous !== undefined) await previous;
    if (!this.current() || this.pending !== job) return;
    const started: number = Date.now();
    console.info('[CardInteraction] requestId=' + job.request.requestId + ' stage=write_start');
    try {
      const result: InteractionCommit = await this.repository.write(job.request);
      const accepted: boolean = this.current() && this.pending === job;
      const applied: boolean = accepted && (this.confirmed === undefined || result.writeVersion >= this.confirmed.writeVersion);
      if (accepted) this.complete(job, result);
      console.info('[CardInteraction] requestId=' + job.request.requestId + ' stage=write_ack elapsedMs=' + (Date.now() - started) +
        ' status=' + result.status + ' reaction=' + result.myReaction + ' favorited=' + result.viewerFavorited +
        ' version=' + result.writeVersion + ' accepted=' + accepted + ' applied=' + applied);
    } catch (error) {
      if (!this.current() || this.pending !== job) return;
      const failure: Object = error as Object;
      const code: string = failure instanceof CloudBusinessError ? failure.code : 'TRANSPORT_UNKNOWN';
      console.warn('[CardInteraction] requestId=' + job.request.requestId + ' stage=write_error code=' + code + ' elapsedMs=' + (Date.now() - started));
      if (this.definitive(failure)) {
        this.clearPending(); this.desiredReaction = undefined; this.desiredFavorite = undefined;
        this.message = '操作未保存：' + this.errorMessage(failure); this.emit();
        void this.refreshState(true);
      } else {
        // Unknown result (timeout or dropped connection). Check the receipt and, if
        // absent, resend the same UUID once automatically; the server deduplicates it.
        if (this.autoRetried !== job.request.requestId) {
          this.autoRetried = job.request.requestId; this.autoRecover = job;
          this.message = '连接不稳定，正在核对并重试原操作…';
        } else this.message = '连接中断，请核对原操作结果。';
        this.emit();
      }
    }
  }
  private complete(job: InteractionJournal, result: InteractionCommit): void {
    const state: InteractionState | undefined = this.confirmed;
    if (state === undefined) {
      const restored: InteractionState = { protocolVersion: 3, cardId: this.cardId, myReaction: result.myReaction,
        viewerFavorited: result.viewerFavorited, writeVersion: result.writeVersion, reactionsEnabled: false,
        reactionsReason: '请刷新点赞状态。', collectionEnabled: false, collectionReady: false, collectionReason: '请刷新收藏状态。' };
      this.confirmed = restored;
    }
    if (state !== undefined && result.writeVersion >= state.writeVersion) {
      this.applyOwnCounts(result.myReaction, result.viewerFavorited, result.writeVersion);
      state.myReaction = result.myReaction; state.viewerFavorited = result.viewerFavorited; state.writeVersion = result.writeVersion;
    }
    if (job.request.patch.reaction !== undefined) this.desiredReaction = undefined;
    if (job.request.patch.favorited !== undefined) this.desiredFavorite = undefined;
    this.ackSeq++; this.countsRetries = 0;
    if (this.autoRecover === job) this.autoRecover = undefined;
    this.clearPending(); this.message = ''; this.emit();
    if (job.request.patch.favorited !== undefined) {
      this.favoriteRevision = (AppStorage.get<number>('favoritesMutationRevision') || 0) + 1;
      AppStorage.setOrCreate('favoritesMutationRevision', this.favoriteRevision);
    }
    this.scheduleCounts();
  }
  private applyOwnCounts(reaction: InteractionReaction, favorited: boolean, version: number): void {
    const counts: InteractionCounts | undefined = this.counts;
    if (counts === undefined || version < counts.writeVersion) return;
    counts.likeCount = Math.max(0, counts.likeCount + (reaction === 'LIKE' ? 1 : 0) - (counts.myReaction === 'LIKE' ? 1 : 0));
    counts.dislikeCount = Math.max(0, counts.dislikeCount + (reaction === 'DISLIKE' ? 1 : 0) - (counts.myReaction === 'DISLIKE' ? 1 : 0));
    counts.favoriteCount = Math.max(0, counts.favoriteCount + (favorited ? 1 : 0) - (counts.viewerFavorited ? 1 : 0));
    counts.myReaction = reaction; counts.viewerFavorited = favorited; counts.writeVersion = version;
  }
  async recover(retry: boolean): Promise<void> {
    const job: InteractionJournal | undefined = this.pending;
    if (!this.current() || job === undefined || this.recovering || this.journalBusy) return;
    if (Date.now() - job.createdAt > JOURNAL_TTL && !this.wireBusy) {
      this.clearPending(); this.desiredReaction = undefined; this.desiredFavorite = undefined;
      this.confirmed = undefined; this.message = '上次操作记录已过期，请刷新状态后重新选择。'; this.emit();
      await this.refreshState(true); return;
    }
    this.recovering = true; this.message = '正在核对结果…'; this.emit();
    try {
      const result: InteractionReceipt = await this.repository.receipt(this.cardId, job.request.requestId);
      if (!this.current() || this.pending !== job) return;
      console.info('[CardInteraction] requestId=' + job.request.requestId + ' stage=receipt found=' + result.found);
      if (result.found && result.receipt !== null) {
        this.complete(job, result.receipt);
        // A receipt is a past commit. Read current state before releasing a queued new choice.
        await this.refreshState();
      } else if (this.wireBusy) this.message = '正在核对结果…';
      else if (retry) this.transmit(job);
      else this.message = '尚未取得保存回执，可点“核对并重试”。';
    } catch (error) {
      if (this.current() && this.pending === job) this.message = '核对失败：' + this.errorMessage(error as Object);
    } finally {
      this.recovering = false; this.emit();
      if (!this.startAutoRecover()) this.drain();
    }
  }
  private async refreshCounts(): Promise<void> {
    if (!this.current() || this.listeners.size === 0) return;
    if (this.countsBusy) { this.countsAgain = true; return; }
    this.countsBusy = true;
    const version: number = this.confirmed?.writeVersion || 0;
    const ackSeq: number = this.ackSeq;
    const quietAtStart: boolean = this.quiet();
    try {
      const options: ReadRequestOptions = { mayContinue: async (): Promise<boolean> =>
        this.current() && this.listeners.size > 0 && AppStorage.get<boolean>('stage47AppActive') !== false };
      const result: InteractionCounts = await this.repository.counts(this.cardId, options);
      if (!this.current()) return;
      const own: InteractionState | undefined = this.confirmed;
      const sameVersion: boolean = version === (own?.writeVersion || 0) && result.writeVersion === version;
      const authoritative: boolean = quietAtStart && ackSeq === this.ackSeq;
      if (this.quiet() && (sameVersion || authoritative)) {
        this.counts = result; this.countsMessage = '';
        // Totals are current; realign the personal state (bounded) if it differs.
        const realign: boolean = !sameVersion || own === undefined || own.myReaction !== result.myReaction ||
          own.viewerFavorited !== result.viewerFavorited;
        if (!realign) this.countsRetries = 0;
        else if (this.countsRetries < COUNTS_MAX_RETRIES) { this.countsRetries++; void this.refreshState(true); }
      } else if (this.pending === undefined) {
        if (this.countsRetries < COUNTS_MAX_RETRIES) {
          this.countsRetries++; this.countsAgain = true;
          if (result.writeVersion > (own?.writeVersion || 0)) void this.refreshState();
        } else this.countsMessage = '总数暂未刷新，稍后可重新读取。';
      }
    } catch (error) {
      if (this.current() && error instanceof CloudBusinessError && error.code === 'STALE_VERSION' &&
        this.countsRetries < COUNTS_MAX_RETRIES) { this.countsRetries++; void this.refreshState(); }
      else if (this.current() && !(error instanceof ReadCancelledError)) this.countsMessage = '总数暂未刷新，稍后可重新读取。';
    }
    finally {
      this.countsBusy = false; this.emit();
      if (this.countsAgain) { this.countsAgain = false; this.scheduleCounts(); }
    }
  }
  private scheduleCounts(): void {
    if (!this.current() || this.listeners.size === 0) return;
    if (this.countsTimer !== -1) clearTimeout(this.countsTimer);
    this.countsTimer = setTimeout((): void => { this.countsTimer = -1; void this.refreshCounts(); }, 400);
  }
  private definitive(error: Object): boolean {
    return error instanceof CloudBusinessError && ['STALE_VERSION', 'VALIDATION_ERROR', 'CONFLICT', 'FEATURE_NOT_READY',
      'COLLECTION_MIGRATING', 'MIGRATION_REQUIRED', 'AUTH_REQUIRED', 'ACCOUNT_INACTIVE', 'ACCOUNT_DELETED',
      'CONTENT_ACCESS_DENIED', 'CONTENT_UNAVAILABLE', 'NOT_FOUND'].includes(error.code);
  }
  private errorMessage(error: Object): string { return error instanceof Error ? error.message : '请稍后重试。'; }
}
