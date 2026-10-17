/**
 * 【文件职责】前台轮询的退避调度（私信、群聊、投票页面使用）：没有新内容时间隔依次为 12 秒、30 秒、60 秒；
 * 有新内容、发送消息或页面重新可见时回到 12 秒。页面停止后绝不再安排下一次。收到 IM 推送时页面会立即刷新，轮询只是兜底。
 */
export const POLL_BACKOFF_STEPS_MS: Array<number> = [12000, 30000, 60000];

// 退避轮询器：每个页面 new 一个，start / reset / stop 控制。
export class PollBackoff {
  // 当前退避档位、是否运行中、会话标识（防止旧定时器继续执行）与定时器 id。
  private step: number = 0;
  private timer: number | undefined = undefined;
  private active: boolean = false;
  private session: number = 0;
  private poll: () => Promise<boolean>;

  // poll 返回 true 表示看到了新内容。
  constructor(poll: () => Promise<boolean>) {
    this.poll = poll;
  }

  // 开始轮询（会先停止旧的轮询）。
  start(): void {
    this.stop();
    this.active = true;
    this.session++;
    this.step = 0;
    this.schedule(this.session);
  }

  // 回到最快的间隔，但不立即请求（发送消息或收到新消息之后调用）。
  reset(): void {
    if (!this.active) return;
    this.start();
  }

  // 停止轮询并清除定时器。
  stop(): void {
    this.active = false;
    if (this.timer !== undefined) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }
  }

  // 安排下一次轮询。
  private schedule(session: number): void {
    if (!this.active || session !== this.session) return;
    const delay: number = POLL_BACKOFF_STEPS_MS[Math.min(this.step, POLL_BACKOFF_STEPS_MS.length - 1)];
    this.timer = setTimeout((): void => {
      this.timer = undefined;
      void this.run(session);
    }, delay);
  }

  // 执行一次轮询，根据是否有新内容调整下一次间隔。
  private async run(session: number): Promise<void> {
    let changed: boolean = false;
    try {
      changed = await this.poll();
    } catch (_error) {
      changed = false;
    }
    if (!this.active || session !== this.session) return;
    this.step = changed ? 0 : Math.min(this.step + 1, POLL_BACKOFF_STEPS_MS.length - 1);
    this.schedule(session);
  }
}
