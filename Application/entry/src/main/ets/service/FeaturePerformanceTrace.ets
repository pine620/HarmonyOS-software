/**
 * 【文件职责】功能级性能打点（HiTrace）。在 DevEco Studio 的性能分析工具里能看到这些区间的耗时。
 * 只记录名称与耗时，不记录任何用户或内容数据。CloudGateway.dispatch 会自动为下列操作的首页请求打点。
 */
import { hiTraceMeter } from '@kit.PerformanceAnalysisKit';
// 可打点的功能名称（发布前检查脚本会核对这些名称是否存在）。
export type FeatureTraceName = 'map_first_render' | 'map_marker_query' | 'search_first_result' | 'random_food_pool' |
  'random_food_cards' | 'food_choice_history' | 'meal_poll_candidates' |
  'food_list_first_page' | 'draft_restore' | 'poll_refresh' | 'deleted_cards_page';
interface TracePageRequest { cursor?: string; pageToken?: string; }
// 功能性能打点（静态类）。
export class FeaturePerformanceTrace {
  private static nextId: number = 1000000;
  // 根据操作名决定使用哪个打点名称；分页请求只给第一页打点。
  static traceNameForOperation(operation: string, payload: object): FeatureTraceName | undefined {
    const page: TracePageRequest = payload as TracePageRequest;
    const first: boolean = (page.cursor || page.pageToken || '').length === 0;
    switch (operation) {
      case 'list-map-merchants': return 'map_marker_query';
      case 'search-public-cards': return first ? 'search_first_result' : undefined;
      case 'get-random-food-pool': return 'random_food_pool';
      case 'get-random-food-cards': return 'random_food_cards';
      case 'list-food-choices': return first ? 'food_choice_history' : undefined;
      case 'get-meal-candidates': return 'meal_poll_candidates';
      case 'list-personal-collection': return first ? 'food_list_first_page' : undefined;
      case 'get-meal-poll': return 'poll_refresh';
      case 'list-deleted-cards': return 'deleted_cards_page';
      default: return undefined;
    }
  }
  // 开始一个打点区间，返回区间 id（-1 表示打点失败，不影响业务）。
  static start(name: FeatureTraceName): number {
    const traceId: number = FeaturePerformanceTrace.nextId;
    FeaturePerformanceTrace.nextId = traceId >= 2147483000 ? 1000000 : traceId + 1;
    try { hiTraceMeter.startTrace(name, traceId); return traceId; } catch (_error) { return -1; }
  }
  // 结束打点区间。
  static finish(name: FeatureTraceName, traceId: number): void {
    if (traceId < 0) return;
    try { hiTraceMeter.finishTrace(name, traceId); } catch (_error) { }
  }
  // 包裹一个异步操作：开始打点 → 执行 → 无论成功失败都结束打点。
  static async measure<T>(name: FeatureTraceName, action: () => Promise<T>): Promise<T> {
    const traceId: number = FeaturePerformanceTrace.start(name);
    try { return await action(); } finally { FeaturePerformanceTrace.finish(name, traceId); }
  }
}
