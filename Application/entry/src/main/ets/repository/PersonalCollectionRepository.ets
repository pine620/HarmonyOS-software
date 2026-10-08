import { EmptyRequest } from '../model/CloudContracts';
import { CardPreviewsRequest, CardPreviewsResponse, CollectionMigrationRequest, PersonalCollectionAction,
  PersonalCollectionKind, PersonalCollectionMigration, PersonalCollectionPage, PersonalCollectionRequest,
  SetPersonalCollectionRequest } from '../model/PersonalCollectionModels';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { ReadRequestOptions } from '../service/ReadScheduler';

export class PersonalCollectionRepository {
  async previews(cardIds: Array<string>, options: ReadRequestOptions = {}): Promise<CardPreviewsResponse> {
    const request: CardPreviewsRequest = { cardIds };
    return AccountRequestGuard.authenticated<CardPreviewsResponse>('get-card-previews', request, options);
  }
  async list(kind: PersonalCollectionKind, cursor: string = '', options: ReadRequestOptions = {}): Promise<PersonalCollectionPage> {
    const request: PersonalCollectionRequest = { kind, cursor, pageSize: 12 };
    return AccountRequestGuard.authenticated<PersonalCollectionPage>('list-personal-collection', request, options);
  }
  async migration(options: ReadRequestOptions = {}): Promise<PersonalCollectionMigration> {
    const request: EmptyRequest = {};
    return AccountRequestGuard.authenticated<PersonalCollectionMigration>('get-personal-collection-migration', request, options);
  }
  async start(): Promise<PersonalCollectionMigration> {
    const request: EmptyRequest = {};
    return AccountRequestGuard.authenticated<PersonalCollectionMigration>('start-personal-collection-migration', request);
  }
  async resume(requestId: string): Promise<PersonalCollectionMigration> {
    const request: CollectionMigrationRequest = { requestId };
    return AccountRequestGuard.authenticated<PersonalCollectionMigration>('resume-personal-collection-migration', request);
  }
  async set(kind: PersonalCollectionKind, request: SetPersonalCollectionRequest): Promise<PersonalCollectionAction> {
    return AccountRequestGuard.authenticated<PersonalCollectionAction>(
      kind === 'FAVORITE' ? 'set-card-favorite' : 'set-card-wanted', request);
  }
}
