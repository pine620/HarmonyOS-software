import { AppDestinationStyle } from '../common/AppPageUi';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { FoodCard } from '../model/CloudContracts';
import { PersonalCollectionMigration, PersonalCollectionPage,
  SetPersonalCollectionRequest } from '../model/PersonalCollectionModels';
import { PersonalCollectionRepository } from '../repository/PersonalCollectionRepository';
import { CardRepository } from '../repository/CardRepository';
import { AuthService } from '../service/AuthService';
import { AuthSessionStore } from '../service/AuthSessionStore';
import { PersonalPreviewLoader, PersonalPreviewRow, PersonalPreviewSource } from '../service/PersonalPreviewLoader';
import { PersonalPreviewTile } from '../components/PersonalPreviewTile';
import { ErrorDetail, errorText } from '../common/ErrorKit';
import { ReadRequestOptions } from '../service/ReadScheduler';

@Component
export struct FavoriteCardsPage {
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @StorageLink('stage47AppActive') @Watch('onEnvironmentChanged') appActive: boolean = true;
  @StorageLink('accountContentRevision') @Watch('onEnvironmentChanged') accountContentRevision: number = 0;
  @StorageLink('favoritesMutationRevision') @Watch('onCollectionMutation') favoritesMutationRevision: number = 0;
  private refreshAgain: boolean = false;
  private onCollectionMutation(): void {
    if (!this.visible || !this.active || !this.appActive) return;
    this.refreshAgain = true;
    if (!this.busy) { this.refreshAgain = false; void this.load(); }
  }
  @State count: number = 0;
  @State cursor: string = '';
  @State busy: boolean = false;
  @State loaded: boolean = false;
  @State message: string = '';
  @State migration: PersonalCollectionMigration | undefined = undefined;
  private source: PersonalPreviewSource = new PersonalPreviewSource();
  private previews: PersonalPreviewLoader = new PersonalPreviewLoader(this.source);
  private repo: PersonalCollectionRepository = new PersonalCollectionRepository();
  private cards: CardRepository = new CardRepository();
  private active: boolean = false;
  private visible: boolean = false;
  private generation: number = 0;
  private owner: string = '';
  private session: number = 0;
  @State pendingRemove: SetPersonalCollectionRequest | undefined = undefined;
  private migrationRequestId: string = '';
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private valid(generation: number): boolean { return this.active && this.appActive && generation === this.generation &&
    this.owner === (AuthService.profile()?.uid || '') && this.session === AuthSessionStore.generation(); }
  private activate(): void {
    if (this.active || !this.appActive) return;
    this.active = true; this.owner = AuthService.profile()?.uid || ''; this.session = AuthSessionStore.generation();
    this.generation++; this.previews.reset(true); void this.load();
  }
  private deactivate(): void {
    this.refreshAgain = false; this.active = false; this.generation++; this.previews.reset(false); this.source.setRows([]);
    this.count = 0; this.cursor = ''; this.loaded = false; this.busy = false; this.migration = undefined;
  }
  private onEnvironmentChanged(): void {
    const sameOwner: boolean = this.owner === (AuthService.profile()?.uid || '');
    this.deactivate();
    if (!sameOwner) { this.pendingRemove = undefined; this.migrationRequestId = ''; }
    if (this.visible && this.appActive) this.activate();
  }
  aboutToDisappear(): void { this.visible = false; this.deactivate(); }
  private window(first: number, last: number): void { if (this.active) this.previews.window(this.context(), first, last, false); }
  private async load(more: boolean = false): Promise<void> {
    if (this.busy || !this.active || this.owner.length === 0) return;
    const generation: number = this.generation; const mutation: number = this.favoritesMutationRevision;
    this.busy = true; this.message = '';
    if (!more) { this.source.setRows([]); this.count = 0; this.cursor = ''; this.loaded = false; this.previews.reset(true); }
    const options: ReadRequestOptions = { mayContinue: async (): Promise<boolean> => this.valid(generation) };
    try {
      const page: PersonalCollectionPage = await this.repo.list('FAVORITE', more ? this.cursor : '', options);
      if (!this.valid(generation)) return;
      if (mutation !== this.favoritesMutationRevision) { this.refreshAgain = true; return; }
      if (page.migration === undefined || typeof page.migration.schemaReady !== 'boolean' ||
          typeof page.migration.collectionReady !== 'boolean') throw new Error('收藏服务尚未更新，请稍后重试。');
      this.migration = page.migration;
      if (!page.migration.collectionReady) {
        this.message = !page.migration.schemaReady ? '收藏服务尚未就绪，请稍后再试。' : '旧清单将合并到收藏；私人备注和吃过记录仅保留历史数据，编辑入口已下线。';
        return;
      }
      const rows: Array<PersonalPreviewRow> = more ? this.source.rows().slice() : [];
      for (const item of page.items) {
        if (rows.some((row: PersonalPreviewRow): boolean => row.cardId === item.cardId)) continue;
        const row: PersonalPreviewRow = new PersonalPreviewRow(item.cardId);
        row.card = item.accessible && item.card !== null ? item.card : undefined;
        row.state = row.card === undefined ? 'UNAVAILABLE' : row.card.photoPath.length === 0 ? 'NO_IMAGE' : 'MEDIA'; rows.push(row);
      }
      this.source.setRows(rows); this.count = rows.length; this.cursor = page.nextCursor;
      this.window(more ? Math.max(0, this.count - page.items.length) : 0, more ? this.count - 1 : 5);
    } catch (error) {
      if (this.valid(generation)) {
        // Never retain earlier protected titles/images after a failed permission refresh.
        this.source.setRows([]); this.count = 0; this.cursor = '';
        this.message = `收藏读取失败：${errorText(error as ErrorDetail)}`;
      }
    } finally { if (this.valid(generation)) {
      this.busy = false; this.loaded = true;
      if (this.refreshAgain) { this.refreshAgain = false; void this.load(); }
    } }
  }
  private async organize(): Promise<void> {
    if (this.busy || !this.active) return;
    const generation: number = this.generation; this.busy = true;
    try {
      if (this.migration?.status === 'NOT_STARTED') {
        const result: PersonalCollectionMigration = await this.repo.start();
        if (!this.valid(generation)) return;
        this.migration = result;
      }
      for (let batch: number = 0; batch < 5 && this.valid(generation) && this.migration?.collectionReady !== true; batch++) {
        if (this.migrationRequestId.length === 0) this.migrationRequestId = util.generateRandomUUID(true);
        const result: PersonalCollectionMigration = await this.repo.resume(this.migrationRequestId);
        if (!this.valid(generation)) return;
        this.migrationRequestId = ''; this.migration = result;
        this.message = `已整理 ${result.processed} 条旧记录`;
      }
      if (this.valid(generation) && this.migration?.collectionReady === true) {
        this.busy = false; await this.load();
      }
    } catch (error) { if (this.valid(generation)) this.message = `整理暂未完成，可继续：${errorText(error as ErrorDetail)}`; }
    finally { if (this.valid(generation)) this.busy = false; }
  }
  private async remove(cardId: string): Promise<void> {
    if (this.busy || !this.active) return;
    if (this.pendingRemove !== undefined && this.pendingRemove.cardId !== cardId) {
      this.message = '上一条移除结果尚未确认，请先重试原条目。'; return;
    }
    const request: SetPersonalCollectionRequest = this.pendingRemove === undefined ?
      { cardId, active: false, requestId: util.generateRandomUUID(true) } : this.pendingRemove;
    this.pendingRemove = request;
    const generation: number = this.generation; this.busy = true;
    try {
      await this.repo.set('FAVORITE', request);
      if (!this.valid(generation)) return;
      this.pendingRemove = undefined; this.refreshAgain = false; this.busy = false; await this.load();
    } catch (error) { if (this.valid(generation)) this.message = `移除结果未确认，点击同一条目重试：${errorText(error as ErrorDetail)}`; }
    finally { if (this.valid(generation)) this.busy = false; }
  }
  private async open(cardId: string): Promise<void> {
    if (this.busy || !this.active) return;
    const generation: number = this.generation; this.busy = true;
    try {
      const options: ReadRequestOptions = { mayContinue: async (): Promise<boolean> => this.valid(generation) };
      const card: FoodCard = await this.cards.detail(this.context(), cardId, options);
      if (this.valid(generation)) this.onOpenCard(card);
    } catch (error) { if (this.valid(generation)) { this.message = errorText(error as ErrorDetail); this.busy = false; void this.load(); } }
    finally { if (this.valid(generation)) this.busy = false; }
  }
  build() {
    NavDestination() {
      Column({ space: 12 }) {
        Row() {
          Text(`已加载 ${this.count} 条`).fontSize(12).fontColor($r('app.color.personal_muted'));
          Blank(); Button(this.busy ? '处理中' : '刷新').constraintSize({ minHeight: 48 }).fontSize(13).enabled(!this.busy)
            .fontColor($r('app.color.personal_action')).backgroundColor(Color.Transparent).onClick((): void => { void this.load(); });
        }.width('100%');
        if (this.pendingRemove !== undefined) { Button('重试上次移除').constraintSize({ minHeight: 48 }).enabled(!this.busy)
          .backgroundColor($r('app.color.personal_soft')).fontColor($r('app.color.personal_action'))
          .onClick((): void => { if (this.pendingRemove !== undefined) { void this.remove(this.pendingRemove.cardId); } }); }
        if (this.message.length > 0) { Text(this.message).fontSize(13).fontColor($r('app.color.personal_muted')).width('100%'); }
        if (this.migration !== undefined && !this.migration.collectionReady && this.migration.schemaReady) {
          Column({ space: 10 }) {
            Text(`收藏待整理 · 已处理 ${this.migration.processed} 条`).fontSize(16).fontColor($r('app.color.personal_ink'));
            Button(this.busy ? '正在整理…' : this.migration.status === 'NOT_STARTED' ? '整理收藏' : '继续整理')
              .constraintSize({ minHeight: 48 }).enabled(!this.busy).backgroundColor($r('app.color.personal_action'))
              .fontColor($r('app.color.personal_surface')).onClick((): void => { void this.organize(); });
          }.width('100%').padding(16).backgroundColor($r('app.color.personal_surface')).borderRadius(16);
        }
        if (this.busy && this.count === 0) { LoadingProgress().width(36).height(36).color($r('app.color.personal_action')); }
        if (this.loaded && !this.busy && this.count === 0 && this.migration?.collectionReady === true) {
          Text('还没有收藏，在详情页点亮 ❤️ 即可。')
            .fontSize(14).fontColor($r('app.color.personal_muted')).width('100%').padding(20);
        }
        List({ space: 10 }) {
          LazyForEach(this.source, (row: PersonalPreviewRow): void => {
            ListItem() { PersonalPreviewTile({ row, removable: true, busy: this.busy,
              onOpen: (cardId: string): void => { void this.open(cardId); },
              onRemove: (cardId: string): void => { void this.remove(cardId); } }); }
          }, (row: PersonalPreviewRow): string => row.cardId);
          if (this.cursor.length > 0) { ListItem() { Button('加载更多').width('100%').constraintSize({ minHeight: 48 })
            .enabled(!this.busy).fontColor($r('app.color.personal_action')).backgroundColor($r('app.color.personal_surface'))
            .onClick((): void => { void this.load(true); }); } }
        }.width('100%').layoutWeight(1).cachedCount(2).onScrollIndex((first: number, last: number): void => this.window(first, last));
      }.width('100%').height('100%').padding({ left: 16, right: 16, top: 8, bottom: 12 })
        .backgroundColor($r('app.color.personal_canvas')).alignItems(HorizontalAlign.Start);
    }.attributeModifier(new AppDestinationStyle('我的收藏', $r('app.color.personal_canvas'), $r('app.color.personal_header'), 'PERSONAL')).onShown((): void => { this.visible = true; this.activate(); })
      .onHidden((): void => { this.visible = false; this.deactivate(); });
  }
}
