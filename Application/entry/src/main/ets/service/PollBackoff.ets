// Foreground polling with back-off: 12 s, then 30 s, then 60 s while nothing changes.
// A change, a send or the page becoming visible again restarts at 12 s. Stopped pages never reschedule.
export const POLL_BACKOFF_STEPS_MS: Array<number> = [12000, 30000, 60000];

export class PollBackoff {
  private step: number = 0;
  private timer: number | undefined = undefined;
  private active: boolean = false;
  private session: number = 0;
  private poll: () => Promise<boolean>;

  // `poll` returns true when it saw new content.
  constructor(poll: () => Promise<boolean>) {
    this.poll = poll;
  }

  start(): void {
    this.stop();
    this.active = true;
    this.session++;
    this.step = 0;
    this.schedule(this.session);
  }

  // Restart the fastest interval without an immediate request (after a send or a new message).
  reset(): void {
    if (!this.active) return;
    this.start();
  }

  stop(): void {
    this.active = false;
    if (this.timer !== undefined) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }
  }

  private schedule(session: number): void {
    if (!this.active || session !== this.session) return;
    const delay: number = POLL_BACKOFF_STEPS_MS[Math.min(this.step, POLL_BACKOFF_STEPS_MS.length - 1)];
    this.timer = setTimeout((): void => {
      this.timer = undefined;
      void this.run(session);
    }, delay);
  }

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
