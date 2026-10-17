/**
 * 【文件职责】个人收藏相关调用：卡片预览、收藏列表、旧收藏数据迁移、设置收藏。
 * 【链路位置】FavoriteCardsPage、PersonalPreviewLoader、聊天页“选择卡片”、详情页 → 本文件 → shike-content（personal-collections.js）。
 */
import { EmptyRequest } from '../model/CloudContracts';
import { CardPreviewsRequest, CardPreviewsResponse, CollectionMigrationRequest, PersonalCollectionAction,
  PersonalCollectionKind, PersonalCollectionMigration, PersonalCollectionPage, PersonalCollectionRequest,
  SetPersonalCollectionRequest } from '../model/PersonalCollectionModels';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { ReadRequestOptions } from '../service/ReadScheduler';

// 收藏仓库（无状态）。
export class PersonalCollectionRepository {
  // 批量读取卡片的轻量预览（标题、价格、封面描述符），用于收藏、浏览记录、聊天中的卡片消息。
  async previews(cardIds: Array<string>, options: ReadRequestOptions = {}): Promise<CardPreviewsResponse> {
    const request: CardPreviewsRequest = { cardIds };
    return AccountRequestGuard.authenticated<CardPreviewsResponse>('get-card-previews', request, options);
  }
  // 分页读取收藏列表（每页 12 条）。
  async list(kind: PersonalCollectionKind, cursor: string = '', options: ReadRequestOptions = {}): Promise<PersonalCollectionPage> {
    const request: PersonalCollectionRequest = { kind, cursor, pageSize: 12 };
    return AccountRequestGuard.authenticated<PersonalCollectionPage>('list-personal-collection', request, options);
  }
  // 查询旧收藏数据向新结构迁移的进度。
  async migration(options: ReadRequestOptions = {}): Promise<PersonalCollectionMigration> {
    const request: EmptyRequest = {};
    return AccountRequestGuard.authenticated<PersonalCollectionMigration>('get-personal-collection-migration', request, options);
  }
  // 开始迁移旧收藏数据。
  async start(): Promise<PersonalCollectionMigration> {
    const request: EmptyRequest = {};
    return AccountRequestGuard.authenticated<PersonalCollectionMigration>('start-personal-collection-migration', request);
  }
  // 继续未完成的迁移（requestId 用于幂等，重复调用不会重复迁移）。
  async resume(requestId: string): Promise<PersonalCollectionMigration> {
    const request: CollectionMigrationRequest = { requestId };
    return AccountRequestGuard.authenticated<PersonalCollectionMigration>('resume-personal-collection-migration', request);
  }
  // 设置/取消收藏；responseMode=ACK 表示只需要确认结果，不需要返回完整卡片。
  async set(kind: PersonalCollectionKind, request: SetPersonalCollectionRequest): Promise<PersonalCollectionAction> {
    const mutation: SetPersonalCollectionRequest = { cardId: request.cardId, active: request.active,
      requestId: request.requestId, responseMode: 'ACK' };
    return AccountRequestGuard.authenticated<PersonalCollectionAction>('set-card-favorite', mutation);
  }
}
