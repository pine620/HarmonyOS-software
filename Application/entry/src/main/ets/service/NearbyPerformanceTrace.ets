import { hiTraceMeter } from '@kit.PerformanceAnalysisKit';

// HiTrace 区间 id 的上限，超过后从 1 重新开始。
const LAST_TRACE_TASK_ID: number = 2147483000;
// 只在本地测量构建中改为 true，验收后恢复 false。日志中不包含用户、位置或内容字段。
const PRELOAD_METRICS_ENABLED: boolean = false;

// 推荐/详情页的打点名称。
type TraceName = 'shike.nearby.cloud_list' | 'shike.nearby.snapshot_load' |
  'shike.nearby.primary_media' | 'shike.nearby.next_page_prefetch' | 'shike.nearby.location.rounded' |
  'shike.detail.metadata';
// 预加载指标事件类型（只在测量构建中输出到日志）。
export type PreloadMetricEvent = 'snapshot' | 'next_page' | 'nearby_metadata' | 'nearby_first_cover' |
  'detail_primary_image' | 'media_cache' | 'media_queue' | 'media_download';
// 指标事件的结果状态。
export type PreloadMetricState = 'hit' | 'miss' | 'joined' | 'stale' | 'success' | 'error' |
  'cancelled' | 'empty' | 'decoded' | 'open' | 'refresh';

/**
 * 【文件职责】推荐页与详情页的性能打点：在 DevEco Studio 性能工具里可见，
 * 不记录位置、账号标识或卡片内容。PRELOAD_METRICS_ENABLED=true 时额外输出 preload.* 日志，
 * 导出后用 Application/scripts/summarize_preload_metrics.py 汇总 P50/P95。
 */
export class NearbyPerformanceTrace {
  private static nextTaskId: number = 1;
  private static startedAt: Map<number, number> = new Map<number, number>();

  // 开始一个打点区间。
  static start(name: TraceName): number {
    const taskId: number = NearbyPerformanceTrace.nextTaskId;
    NearbyPerformanceTrace.nextTaskId = taskId >= LAST_TRACE_TASK_ID ? 1 : taskId + 1;
    hiTraceMeter.startTrace(name, taskId);
    if (PRELOAD_METRICS_ENABLED) NearbyPerformanceTrace.startedAt.set(taskId, Date.now());
    return taskId;
  }

  // 结束打点区间；测量开关打开时额外输出耗时日志。
  static finish(name: TraceName, taskId: number): void {
    hiTraceMeter.finishTrace(name, taskId);
    const started: number | undefined = NearbyPerformanceTrace.startedAt.get(taskId);
    NearbyPerformanceTrace.startedAt.delete(taskId);
    if (PRELOAD_METRICS_ENABLED && started !== undefined) {
      console.info(`preload.trace name=${name} durationMs=${Math.max(0, Date.now() - started)}`);
    }
  }

  // 记录一条预加载指标（命中/未命中/耗时/数量），供 summarize_preload_metrics.py 离线统计。
  static record(event: PreloadMetricEvent, state: PreloadMetricState,
    started: number = Date.now(), count: number = 0): void {
    if (!PRELOAD_METRICS_ENABLED) return;
    console.info(`preload.metric event=${event} state=${state} ` +
      `durationMs=${Math.max(0, Date.now() - started)} count=${Math.max(0, count)}`);
  }
}
