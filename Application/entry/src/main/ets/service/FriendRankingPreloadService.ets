import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { CardRepository } from '../repository/CardRepository';

const FRIEND_RANKING_TTL_MS: number = 60 * 1000;

interface FriendRankingSnapshot {
  key: string;
  cards: Array<FoodCard>;
  fetchedAt: number;
}

/** Account-scoped, memory-only metadata shared by startup and the ranking tab. */
export class FriendRankingPreloadService {
  private static repository: CardRepository = new CardRepository();
  private static snapshot: FriendRankingSnapshot | undefined = undefined;
  private static request: Promise<Array<FoodCard>> | undefined = undefined;
  private static requestKey: string = '';
  private static generation: number = 0;

  static invalidate(): void {
    FriendRankingPreloadService.generation += 1;
    FriendRankingPreloadService.snapshot = undefined;
    FriendRankingPreloadService.request = undefined;
    FriendRankingPreloadService.requestKey = '';
  }

  static cached(uid: string, relationshipRevision: number): Array<FoodCard> | undefined {
    const snapshot: FriendRankingSnapshot | undefined = FriendRankingPreloadService.snapshot;
    const key: string = `${uid}:${relationshipRevision}`;
    return snapshot !== undefined && snapshot.key === key &&
      snapshot.fetchedAt + FRIEND_RANKING_TTL_MS > Date.now() ? snapshot.cards : undefined;
  }

  static async load(context: common.Context, uid: string, relationshipRevision: number,
    forceRefresh: boolean = false): Promise<Array<FoodCard>> {
    const key: string = `${uid}:${relationshipRevision}`;
    const cached: Array<FoodCard> | undefined = FriendRankingPreloadService.cached(uid, relationshipRevision);
    if (!forceRefresh && cached !== undefined) return cached;
    const inFlight: Promise<Array<FoodCard>> | undefined = FriendRankingPreloadService.request;
    if (!forceRefresh && inFlight !== undefined && FriendRankingPreloadService.requestKey === key) return inFlight;
    const generation: number = FriendRankingPreloadService.generation;
    const request: Promise<Array<FoodCard>> = FriendRankingPreloadService.repository.listFriendRankingsMetadata(context);
    FriendRankingPreloadService.request = request;
    FriendRankingPreloadService.requestKey = key;
    try {
      const cards: Array<FoodCard> = await request;
      if (generation === FriendRankingPreloadService.generation && FriendRankingPreloadService.request === request) {
        FriendRankingPreloadService.snapshot = { key, cards, fetchedAt: Date.now() };
      }
      return cards;
    } finally {
      if (FriendRankingPreloadService.request === request) {
        FriendRankingPreloadService.request = undefined;
        FriendRankingPreloadService.requestKey = '';
      }
    }
  }

  static warm(context: common.Context, uid: string, relationshipRevision: number): void {
    void FriendRankingPreloadService.load(context, uid, relationshipRevision).catch((): void => {});
  }
}
