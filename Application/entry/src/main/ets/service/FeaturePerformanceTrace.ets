import { hiTraceMeter } from '@kit.PerformanceAnalysisKit';
export type FeatureTraceName = 'map_first_render' | 'map_marker_query' | 'search_first_result' | 'today_eat_candidates' |
  'food_list_first_page' | 'draft_restore' | 'poll_refresh' | 'moderation_queue' | 'deleted_cards_page';
interface TracePageRequest { cursor?: string; pageToken?: string; }
export class FeaturePerformanceTrace {
  private static nextId: number = 1000000;
  static traceNameForOperation(operation: string, payload: object): FeatureTraceName | undefined {
    const page: TracePageRequest = payload as TracePageRequest;
    const first: boolean = (page.cursor || page.pageToken || '').length === 0;
    switch (operation) {
      case 'list-map-merchants': return 'map_marker_query';
      case 'search-public-cards': return first ? 'search_first_result' : undefined;
      case 'get-meal-candidates': return 'today_eat_candidates';
      case 'list-personal-collection': case 'list-food-list-items': return first ? 'food_list_first_page' : undefined;
      case 'get-meal-poll': return 'poll_refresh';
      case 'list-moderation-queue': return 'moderation_queue';
      case 'list-deleted-cards': return 'deleted_cards_page';
      default: return undefined;
    }
  }
  static start(name: FeatureTraceName): number {
    const traceId: number = FeaturePerformanceTrace.nextId;
    FeaturePerformanceTrace.nextId = traceId >= 2147483000 ? 1000000 : traceId + 1;
    try { hiTraceMeter.startTrace(name, traceId); return traceId; } catch (_error) { return -1; }
  }
  static finish(name: FeatureTraceName, traceId: number): void {
    if (traceId < 0) return;
    try { hiTraceMeter.finishTrace(name, traceId); } catch (_error) { }
  }
  static async measure<T>(name: FeatureTraceName, action: () => Promise<T>): Promise<T> {
    const traceId: number = FeaturePerformanceTrace.start(name);
    try { return await action(); } finally { FeaturePerformanceTrace.finish(name, traceId); }
  }
}
