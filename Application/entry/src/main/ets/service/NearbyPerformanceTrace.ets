import { hiTraceMeter } from '@kit.PerformanceAnalysisKit';

const LAST_TRACE_TASK_ID: number = 2147483000;
// Enable only in a local measurement build. No user/location/content fields are logged.
const PRELOAD_METRICS_ENABLED: boolean = false;

type TraceName = 'shike.nearby.cloud_list' | 'shike.nearby.snapshot_load' |
  'shike.nearby.primary_media' | 'shike.nearby.next_page_prefetch' | 'shike.nearby.location.rounded' |
  'shike.detail.metadata';
export type PreloadMetricEvent = 'snapshot' | 'next_page' | 'nearby_metadata' | 'nearby_first_cover' |
  'detail_primary_image' | 'media_cache' | 'media_queue' | 'media_download';
export type PreloadMetricState = 'hit' | 'miss' | 'joined' | 'stale' | 'success' | 'error' |
  'cancelled' | 'empty' | 'decoded' | 'open' | 'refresh';

/**
 * Keeps nearby-page timing visible in DevEco Studio's performance tooling
 * without recording locations, account identifiers, or card content.
 */
export class NearbyPerformanceTrace {
  private static nextTaskId: number = 1;
  private static startedAt: Map<number, number> = new Map<number, number>();

  static start(name: TraceName): number {
    const taskId: number = NearbyPerformanceTrace.nextTaskId;
    NearbyPerformanceTrace.nextTaskId = taskId >= LAST_TRACE_TASK_ID ? 1 : taskId + 1;
    hiTraceMeter.startTrace(name, taskId);
    if (PRELOAD_METRICS_ENABLED) NearbyPerformanceTrace.startedAt.set(taskId, Date.now());
    return taskId;
  }

  static finish(name: TraceName, taskId: number): void {
    hiTraceMeter.finishTrace(name, taskId);
    const started: number | undefined = NearbyPerformanceTrace.startedAt.get(taskId);
    NearbyPerformanceTrace.startedAt.delete(taskId);
    if (PRELOAD_METRICS_ENABLED && started !== undefined) {
      console.info(`preload.trace name=${name} durationMs=${Math.max(0, Date.now() - started)}`);
    }
  }

  static record(event: PreloadMetricEvent, state: PreloadMetricState,
    started: number = Date.now(), count: number = 0): void {
    if (!PRELOAD_METRICS_ENABLED) return;
    console.info(`preload.metric event=${event} state=${state} ` +
      `durationMs=${Math.max(0, Date.now() - started)} count=${Math.max(0, count)}`);
  }
}
