export class PagedDataSource<T> implements IDataSource {
  private values: Array<T> = [];
  private listeners: Array<DataChangeListener> = [];
  totalCount(): number { return this.values.length; }
  getData(index: number): T { return this.values[index]; }
  rows(): Array<T> { return this.values; }
  merge(values: Array<T>, key: (value: T) => string, more: boolean): void {
    const rows: Map<string, T> = new Map<string, T>();
    if (more) for (const value of this.values) rows.set(key(value), value);
    for (const value of values) rows.set(key(value), value);
    this.replace(Array.from(rows.values()));
  }
  replace(values: Array<T>): void { this.values = values; for (const listener of this.listeners) listener.onDataReloaded(); }
  registerDataChangeListener(listener: DataChangeListener): void { if (!this.listeners.includes(listener)) this.listeners.push(listener); }
  unregisterDataChangeListener(listener: DataChangeListener): void { this.listeners = this.listeners.filter((value: DataChangeListener): boolean => value !== listener); }
}

/**
 * Pack 4.3 (2026-10-15): LazyForEach source for chat-style lists. `update` turns a new array into the smallest
 * notification: older rows prepended -> ADD at 0 (+ CHANGE of the previous first row, whose separator may
 * change), newer rows appended -> ADD at the end, same rows -> CHANGE of rows whose render key changed,
 * anything else -> full reload. Prepends keep List.maintainVisibleContentPosition working.
 */
export class DiffDataSource<T> implements IDataSource {
  private values: Array<T> = [];
  private listeners: Array<DataChangeListener> = [];
  private readonly identity: (value: T) => string;
  private readonly renderKey: (value: T, index: number, values: Array<T>) => string;

  constructor(identity: (value: T) => string, renderKey: (value: T, index: number, values: Array<T>) => string) {
    this.identity = identity;
    this.renderKey = renderKey;
  }

  totalCount(): number { return this.values.length; }
  getData(index: number): T { return this.values[index]; }
  keyAt(index: number): string { return this.renderKey(this.values[index], index, this.values); }

  update(next: Array<T>): void {
    const previous: Array<T> = this.values;
    const oldKeys: Array<string> = previous.map((value: T, index: number): string => this.renderKey(value, index, previous));
    this.values = next.slice();
    if (previous.length === 0 || next.length === 0) { this.reload(); return; }
    if (next.length > previous.length && this.sameIds(previous, next, next.length - previous.length)) {
      const added: number = next.length - previous.length;
      this.notify([{ type: DataOperationType.ADD, index: 0, count: added }]);
      for (const listener of this.listeners) listener.onDataChange(added);
      return;
    }
    if (next.length > previous.length && this.sameIds(previous, next, 0)) {
      this.notify([{ type: DataOperationType.ADD, index: previous.length, count: next.length - previous.length }]);
      return;
    }
    if (next.length === previous.length && this.sameIds(previous, next, 0)) {
      for (let index = 0; index < next.length; index++) {
        if (this.renderKey(next[index], index, next) !== oldKeys[index]) {
          for (const listener of this.listeners) listener.onDataChange(index);
        }
      }
      return;
    }
    this.reload();
  }

  registerDataChangeListener(listener: DataChangeListener): void { if (!this.listeners.includes(listener)) this.listeners.push(listener); }
  unregisterDataChangeListener(listener: DataChangeListener): void { this.listeners = this.listeners.filter((value: DataChangeListener): boolean => value !== listener); }

  private sameIds(previous: Array<T>, next: Array<T>, offset: number): boolean {
    for (let index = 0; index < previous.length; index++) {
      if (this.identity(previous[index]) !== this.identity(next[index + offset])) return false;
    }
    return true;
  }
  private notify(operations: Array<DataOperation>): void { for (const listener of this.listeners) listener.onDatasetChange(operations); }
  private reload(): void { for (const listener of this.listeners) listener.onDataReloaded(); }
}
