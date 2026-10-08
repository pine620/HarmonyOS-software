import { FeaturePerformanceTrace } from './FeaturePerformanceTrace';
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { DraftForm, DraftMedia, DraftRestore, LocalDraft } from '../model/DraftModels';
import { PreparedPhoto } from './ImagePreparationService';
const DAY: number = 86400000;
/** One serialized connection protects the NEW+EDIT cap and media/payload transaction. */
export class DraftStore {
  private static opening: Promise<relationalStore.RdbStore> | undefined = undefined;
  private static activeOwnerUid: string = '';
  static activateOwner(uid: string): void { if (DraftStore.activeOwnerUid !== uid) { DraftStore.activeOwnerUid = uid; AppStorage.setOrCreate('accountContentRevision', (AppStorage.get<number>('accountContentRevision') || 0) + 1); } }
  private static queue: Promise<void> = Promise.resolve();
  static flushHandler: (() => Promise<void>) | undefined = undefined;
  static async flushActive(): Promise<void> { const handler: (() => Promise<void>) | undefined = DraftStore.flushHandler; if (handler !== undefined) await handler(); await DraftStore.queue; }
  private static serialize<T>(operation: () => Promise<T>): Promise<T> {
    const result: Promise<T> = DraftStore.queue.then(operation); DraftStore.queue = result.then((): void => {}, (_error: Object): void => {}); return result;
  }
  private static async open(context: common.Context): Promise<relationalStore.RdbStore> {
    const config: relationalStore.StoreConfig = { name: 'shike_drafts.db', securityLevel: relationalStore.SecurityLevel.S1 };
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
    await store.executeSql('CREATE TABLE IF NOT EXISTS drafts (draft_id TEXT PRIMARY KEY, owner_uid TEXT NOT NULL, draft_type TEXT NOT NULL, target_card_id TEXT NOT NULL, payload_json TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, reminder_sent INTEGER NOT NULL DEFAULT 0)');
    await store.executeSql('CREATE INDEX IF NOT EXISTS draft_owner_updated ON drafts(owner_uid, updated_at DESC)');
    await store.executeSql('CREATE TABLE IF NOT EXISTS draft_media (media_id TEXT PRIMARY KEY, draft_id TEXT NOT NULL, local_managed_path TEXT NOT NULL, sort_order INTEGER NOT NULL, sha256 TEXT NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL, byte_size INTEGER NOT NULL, mime_type TEXT NOT NULL)');
    return store;
  }
  private static store(context: common.Context): Promise<relationalStore.RdbStore> { if (DraftStore.opening === undefined) DraftStore.opening = DraftStore.open(context).catch((error: Object): Promise<relationalStore.RdbStore> => { DraftStore.opening = undefined; return Promise.reject(error); }); return DraftStore.opening; }
  private static assertOwner(uid: string): void { if (DraftStore.activeOwnerUid !== uid || uid.length === 0) throw new Error('账号已变化，草稿操作已取消。'); }
  private static folder(context: common.Context, uid: string, draftId: string): string { if (!/^[A-Za-z0-9_-]{1,128}$/.test(draftId)) throw new Error('草稿标识无效。'); return context.filesDir + '/drafts/' + encodeURIComponent(uid) + '/' + draftId; }
  private static decode(rows: relationalStore.ResultSet): Array<LocalDraft> {
    const result: Array<LocalDraft> = [];
    try { while (rows.goToNextRow()) {
      const form: DraftForm = JSON.parse(rows.getString(rows.getColumnIndex('payload_json'))) as DraftForm;
      const type: string = rows.getString(rows.getColumnIndex('draft_type'));
      const item: LocalDraft = { draftId: rows.getString(rows.getColumnIndex('draft_id')), ownerUid: rows.getString(rows.getColumnIndex('owner_uid')), draftType: type === 'EDIT' ? 'EDIT' : 'NEW', targetCardId: rows.getString(rows.getColumnIndex('target_card_id')), form, createdAt: rows.getLong(rows.getColumnIndex('created_at')), updatedAt: rows.getLong(rows.getColumnIndex('updated_at')), reminderSent: rows.getLong(rows.getColumnIndex('reminder_sent')) === 1 }; result.push(item);
    } } finally { rows.close(); } return result;
  }
  private static mediaRows(rows: relationalStore.ResultSet): Array<DraftMedia> { const result: Array<DraftMedia> = []; try { while (rows.goToNextRow()) { const media: DraftMedia = { path: rows.getString(rows.getColumnIndex('local_managed_path')), sha256: rows.getString(rows.getColumnIndex('sha256')), width: rows.getLong(rows.getColumnIndex('width')), height: rows.getLong(rows.getColumnIndex('height')), byteSize: rows.getLong(rows.getColumnIndex('byte_size')), mimeType: rows.getString(rows.getColumnIndex('mime_type')) }; result.push(media); } } finally { rows.close(); } return result; }
  private static removeFolder(path: string): void { if (!fileIo.accessSync(path)) return; for (const name of fileIo.listFileSync(path)) { const child: string = path + '/' + name; const stat: fileIo.Stat = fileIo.lstatSync(child); if (stat.isDirectory()) DraftStore.removeFolder(child); else fileIo.unlinkSync(child); } fileIo.rmdirSync(path); }
  private static cleanOrphans(context: common.Context, uid: string, drafts: Array<LocalDraft>): void { const root: string = context.filesDir + '/drafts/' + encodeURIComponent(uid); if (!fileIo.accessSync(root)) return; for (const name of fileIo.listFileSync(root)) { if (/^[A-Za-z0-9_-]{1,128}$/.test(name) && !drafts.some((draft: LocalDraft): boolean => draft.draftId === name && Date.now() - draft.updatedAt < 30 * DAY)) DraftStore.removeFolder(root + '/' + name); } }
  private static async removeRow(context: common.Context, store: relationalStore.RdbStore, uid: string, draftId: string): Promise<void> {
    const found: Array<LocalDraft> = DraftStore.decode(await store.querySql('SELECT * FROM drafts WHERE owner_uid = ? AND draft_id = ?', [uid, draftId])); if (found.length === 0) return;
    store.beginTransaction();
    try { await store.executeSql('DELETE FROM draft_media WHERE draft_id = ?', [draftId]); await store.executeSql('DELETE FROM drafts WHERE owner_uid = ? AND draft_id = ?', [uid, draftId]); store.commit(); }
    catch (error) { store.rollBack(); throw error instanceof Error ? error : new Error('删除草稿失败。'); }
    const path: string = DraftStore.folder(context, uid, draftId); try { DraftStore.removeFolder(path); } catch (_error) { /* Deleted DB ownership prevents restore; managed files are also cleared at account deletion. */ }
  }
  static list(context: common.Context, uid: string): Promise<Array<LocalDraft>> { return DraftStore.serialize<Array<LocalDraft>>(async (): Promise<Array<LocalDraft>> => {
    DraftStore.assertOwner(uid); const store: relationalStore.RdbStore = await DraftStore.store(context);
    const all: Array<LocalDraft> = DraftStore.decode(await store.querySql('SELECT * FROM drafts WHERE owner_uid = ? ORDER BY updated_at DESC', [uid]));
    for (const draft of all) if (Date.now() - draft.updatedAt >= 30 * DAY) await DraftStore.removeRow(context, store, uid, draft.draftId);
    DraftStore.cleanOrphans(context, uid, all); DraftStore.assertOwner(uid); return all.filter((draft: LocalDraft): boolean => Date.now() - draft.updatedAt < 30 * DAY);
  }); }
  static save(context: common.Context, uid: string, draftId: string, target: string, form: DraftForm, photos: Array<PreparedPhoto>): Promise<void> { return DraftStore.serialize<void>(async (): Promise<void> => {
    DraftStore.assertOwner(uid); if (photos.length > 6) throw new Error('草稿最多保存 6 张图片。'); const store: relationalStore.RdbStore = await DraftStore.store(context); const now: number = Date.now();
    const all: Array<LocalDraft> = DraftStore.decode(await store.querySql('SELECT * FROM drafts WHERE owner_uid = ?', [uid]));
    for (const draft of all) if (now - draft.updatedAt >= 30 * DAY) await DraftStore.removeRow(context, store, uid, draft.draftId);
    const current: LocalDraft | undefined = all.find((draft: LocalDraft): boolean => draft.draftId === draftId && now - draft.updatedAt < 30 * DAY);
    if (current === undefined && all.filter((draft: LocalDraft): boolean => now - draft.updatedAt < 30 * DAY).length >= 10) throw new Error('新建与编辑草稿合计已达 10 个，请先清理草稿箱。');
    DraftStore.cleanOrphans(context, uid, all);
    const folder: string = DraftStore.folder(context, uid, draftId); if (!fileIo.accessSync(folder)) fileIo.mkdirSync(folder, true);
    const media: Array<DraftMedia> = [];
    for (const photo of photos) { if (!/^[0-9a-f]{64}$/.test(photo.sha256) || photo.data.byteLength > 2097152) throw new Error('草稿图片无效。'); const path: string = folder + '/' + photo.sha256 + '.jpg';
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC); try { fileIo.writeSync(file.fd, photo.data); } finally { fileIo.closeSync(file); }
      const entry: DraftMedia = { path, sha256: photo.sha256, width: photo.width, height: photo.height, byteSize: photo.byteSize, mimeType: photo.mimeType }; media.push(entry);
    }
    const oldMedia: Array<DraftMedia> = DraftStore.mediaRows(await store.querySql('SELECT * FROM draft_media WHERE draft_id = ? ORDER BY sort_order', [draftId]));
    DraftStore.assertOwner(uid); store.beginTransaction(); try {
      const row: relationalStore.ValuesBucket = { draft_id: draftId, owner_uid: uid, draft_type: target.length > 0 ? 'EDIT' : 'NEW', target_card_id: target, payload_json: JSON.stringify(form), created_at: current === undefined ? now : current.createdAt, updated_at: now, reminder_sent: 0 };
      await store.insert('drafts', row, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE); await store.executeSql('DELETE FROM draft_media WHERE draft_id = ?', [draftId]);
      for (let index: number = 0; index < media.length; index++) { const item: DraftMedia = media[index]; const bucket: relationalStore.ValuesBucket = { media_id: draftId + ':' + index.toString(), draft_id: draftId, local_managed_path: item.path, sort_order: index, sha256: item.sha256, width: item.width, height: item.height, byte_size: item.byteSize, mime_type: item.mimeType }; await store.insert('draft_media', bucket); }
      DraftStore.assertOwner(uid); store.commit();
    } catch (error) { store.rollBack(); throw error instanceof Error ? error : new Error('草稿保存失败。'); }
    for (const item of oldMedia) if (!media.some((value: DraftMedia): boolean => value.path === item.path)) { try { if (fileIo.accessSync(item.path)) fileIo.unlinkSync(item.path); } catch (_error) {} }
  }); }
  static restore(context: common.Context, uid: string, draftId: string): Promise<DraftRestore> { return FeaturePerformanceTrace.measure<DraftRestore>('draft_restore', (): Promise<DraftRestore> => DraftStore.serialize<DraftRestore>(async (): Promise<DraftRestore> => {
    DraftStore.assertOwner(uid); const store: relationalStore.RdbStore = await DraftStore.store(context); const rows: Array<LocalDraft> = DraftStore.decode(await store.querySql('SELECT * FROM drafts WHERE owner_uid = ? AND draft_id = ?', [uid, draftId]));
    if (rows.length === 0 || Date.now() - rows[0].updatedAt >= 30 * DAY) throw new Error('草稿已过期或不存在。');
    const media: Array<DraftMedia> = DraftStore.mediaRows(await store.querySql('SELECT * FROM draft_media WHERE draft_id = ? ORDER BY sort_order', [draftId])); const folder: string = DraftStore.folder(context, uid, draftId);
    const available: Array<DraftMedia> = media.filter((item: DraftMedia): boolean => item.path.startsWith(folder + '/') && fileIo.accessSync(item.path)); DraftStore.assertOwner(uid); return { draft: rows[0], media: available, missingMediaCount: media.length - available.length };
  })); }
  static photo(media: DraftMedia): PreparedPhoto { const file: fileIo.File = fileIo.openSync(media.path, fileIo.OpenMode.READ_ONLY); try { const size: number = fileIo.statSync(file.fd).size; if (size !== media.byteSize || size < 1 || size > 2097152) throw new Error('草稿图片已损坏，请重新选择。'); const data: ArrayBuffer = new ArrayBuffer(size); if (fileIo.readSync(file.fd, data) !== size) throw new Error('图片读取不完整。'); return { data, sha256: media.sha256, width: media.width, height: media.height, byteSize: size, mimeType: media.mimeType }; } finally { fileIo.closeSync(file); } }
  static remove(context: common.Context, uid: string, draftId: string): Promise<void> { return DraftStore.serialize<void>(async (): Promise<void> => { DraftStore.assertOwner(uid); await DraftStore.removeRow(context, await DraftStore.store(context), uid, draftId); }); }
  static clearAccount(context: common.Context, uid: string): Promise<void> { return DraftStore.serialize<void>(async (): Promise<void> => { const store: relationalStore.RdbStore = await DraftStore.store(context); const all: Array<LocalDraft> = DraftStore.decode(await store.querySql('SELECT * FROM drafts WHERE owner_uid = ?', [uid])); for (const draft of all) await DraftStore.removeRow(context, store, uid, draft.draftId); const root: string = context.filesDir + '/drafts/' + encodeURIComponent(uid); DraftStore.removeFolder(root); }); }
  static reminders(context: common.Context, uid: string): Promise<number> { return DraftStore.serialize<number>(async (): Promise<number> => { DraftStore.assertOwner(uid); const store: relationalStore.RdbStore = await DraftStore.store(context); const rows: Array<LocalDraft> = DraftStore.decode(await store.querySql('SELECT * FROM drafts WHERE owner_uid = ? AND reminder_sent = 0 AND updated_at <= ? AND updated_at > ?', [uid, Date.now() - 27 * DAY, Date.now() - 30 * DAY])); if (rows.length > 0) await store.executeSql('UPDATE drafts SET reminder_sent = 1 WHERE owner_uid = ? AND updated_at <= ? AND updated_at > ?', [uid, Date.now() - 27 * DAY, Date.now() - 30 * DAY]); return rows.length; }); }
}
