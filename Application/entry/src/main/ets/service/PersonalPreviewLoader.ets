import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { CardPreviewItem, CardPreviewsResponse } from '../model/PersonalCollectionModels';
import { PersonalCollectionRepository } from '../repository/PersonalCollectionRepository';
import { ImageRepository } from './ImageRepository';
import { CloudBusinessError, ReadCancelledError } from './CloudReadErrors';
import { AuthService } from './AuthService';
import { AuthSessionStore } from './AuthSessionStore';
import { ReadRequestOptions } from './ReadScheduler';

export type PersonalPreviewState = 'PENDING' | 'MEDIA' | 'READY' | 'NO_IMAGE' | 'ERROR' | 'UNAVAILABLE';

@Observed
export class PersonalPreviewRow {
  cardId: string;
  visitedAt: number;
  card: FoodCard | undefined = undefined;
  state: PersonalPreviewState = 'PENDING';
  constructor(cardId: string, visitedAt: number = 0) { this.cardId = cardId; this.visitedAt = visitedAt; }
}

export class PersonalPreviewSource implements IDataSource {
  private data: Array<PersonalPreviewRow> = [];
  private listeners: Array<DataChangeListener> = [];
  totalCount(): number { return this.data.length; }
  getData(index: number): PersonalPreviewRow { return this.data[index]; }
  rows(): Array<PersonalPreviewRow> { return this.data; }
  setRows(rows: Array<PersonalPreviewRow>): void {
    this.data = rows;
    for (const listener of this.listeners) listener.onDataReloaded();
  }
  changed(index: number): void { for (const listener of this.listeners) listener.onDataChange(index); }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) this.listeners.push(listener);
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((item: DataChangeListener): boolean => item !== listener);
  }
}

// Pages own this loader. Metadata precedes every use of the local media cache.
// Both queues delegate their real RPC slots and busy retry to ReadScheduler.
export class PersonalPreviewLoader {
  private generation: number = 0;
  private owner: string = '';
  private session: number = 0;
  private contentRevision: number = 0;
  private active: boolean = false;
  private first: number = 0;
  private last: number = 9;
  private pending: Set<string> = new Set<string>();
  private repo: PersonalCollectionRepository = new PersonalCollectionRepository();
  private source: PersonalPreviewSource;
  private allowGuest: boolean;
  constructor(source: PersonalPreviewSource, allowGuest: boolean = false) {
    this.source = source; this.allowGuest = allowGuest;
  }
  reset(active: boolean): void {
    this.generation++; this.pending.clear(); this.active = active;
    this.owner = AuthService.profile()?.uid || '';
    this.session = AuthSessionStore.generation();
    this.contentRevision = AppStorage.get<number>('accountContentRevision') || 0;
    this.first = 0; this.last = 9;
  }
  private valid(generation: number): boolean {
    return this.active && generation === this.generation && (this.owner.length > 0 || this.allowGuest) &&
      this.owner === (AuthService.profile()?.uid || '') && this.session === AuthSessionStore.generation() &&
      this.contentRevision === (AppStorage.get<number>('accountContentRevision') || 0) &&
      AppStorage.get<boolean>('stage47AppActive') !== false;
  }
  private wanted(index: number): boolean { return index >= this.first && index <= this.last + 2; }
  window(context: common.Context, first: number, last: number, fetchMetadata: boolean): void {
    this.first = Math.max(0, first); this.last = Math.min(this.first + 9, Math.max(this.first, last));
    if (!this.valid(this.generation)) return;
    if (fetchMetadata) {
      const candidates: Array<PersonalPreviewRow> = this.source.rows().slice(this.first, this.last + 3)
        .filter((row: PersonalPreviewRow): boolean => row.state === 'PENDING' && !this.pending.has(row.cardId));
      for (let start: number = 0; start < candidates.length; start += 10) {
        const batch: Array<PersonalPreviewRow> = candidates.slice(start, start + 10);
        for (const row of batch) this.pending.add(row.cardId);
        void this.metadata(context, batch, this.generation);
      }
    }
    for (let index: number = this.first; index <= this.last + 2 && index < this.source.totalCount(); index++) {
      const row: PersonalPreviewRow = this.source.getData(index);
      if (row.state === 'MEDIA' && !this.pending.has(row.cardId)) {
        this.pending.add(row.cardId); void this.media(context, row, index, this.generation);
      }
    }
  }
  private async metadata(context: common.Context, rows: Array<PersonalPreviewRow>, generation: number): Promise<void> {
    const options: ReadRequestOptions = { priority: rows.every((row: PersonalPreviewRow): boolean => this.source.rows().indexOf(row) > this.last) ? 'prefetch' : 'metadata', mayContinue: async (): Promise<boolean> =>
      this.valid(generation) && rows.some((row: PersonalPreviewRow): boolean => this.wanted(this.source.rows().indexOf(row))) };
    try {
      const result: CardPreviewsResponse = await this.repo.previews(rows.map((row: PersonalPreviewRow): string => row.cardId), options);
      if (!this.valid(generation)) return;
      for (const row of rows) {
        const item: CardPreviewItem | undefined = result.items.find((value: CardPreviewItem): boolean => value.cardId === row.cardId);
        if (item === undefined) { row.state = 'ERROR'; row.card = undefined; }
        else { row.card = item.accessible && item.card !== null ? item.card : undefined;
          row.state = row.card === undefined ? 'UNAVAILABLE' : row.card.photoPath.length === 0 ? 'NO_IMAGE' : 'MEDIA'; }
        this.source.changed(this.source.rows().indexOf(row));
      }
    } catch (error) {
      if (this.valid(generation)) for (const row of rows) {
        row.card = undefined; row.state = error instanceof ReadCancelledError ? 'PENDING' : 'ERROR'; this.source.changed(this.source.rows().indexOf(row));
      }
    } finally {
      if (this.valid(generation)) {
        for (const row of rows) this.pending.delete(row.cardId);
        this.window(context, this.first, this.last, true);
      }
    }
  }
  private async media(context: common.Context, row: PersonalPreviewRow, index: number, generation: number): Promise<void> {
    const card: FoodCard | undefined = row.card;
    if (card === undefined) return;
    try {
      const url: string = await ImageRepository.getDownloadUrl(context, card.photoBucket, card.photoPath,
        index > this.last ? 'low' : 'high', async (): Promise<boolean> => this.valid(generation) && this.wanted(index), card.photos?.[0], true);
      if (!this.valid(generation) || !this.wanted(index)) return;
      card.photoUrl = url; row.card = card; row.state = url.length > 0 ? 'READY' : 'ERROR'; this.source.changed(index);
    } catch (error) {
      if (this.valid(generation)) {
        if (error instanceof CloudBusinessError && ['CONTENT_ACCESS_DENIED', 'CONTENT_UNAVAILABLE', 'ACCOUNT_INACTIVE'].includes(error.code)) { row.card = undefined; row.state = 'UNAVAILABLE'; }
        else row.state = error instanceof ReadCancelledError ? 'MEDIA' : 'ERROR';
        this.source.changed(index);
      }
    } finally { if (this.valid(generation)) this.pending.delete(row.cardId); }
  }
}
