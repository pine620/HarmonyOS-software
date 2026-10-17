/**
 * 【文件职责】ArkUI LazyForEach 使用的数据源（只渲染可见行，长列表不卡顿）。
 * PagedDataSource：普通分页列表，合并新一页时按 key 去重；DiffDataSource：聊天类列表，计算最小的增删改通知。
 */
export class PagedDataSource<T> implements IDataSource {
  private values: Array<T> = [];
  private listeners: Array<DataChangeListener> = [];
  // 总行数 / 取第 index 行 / 全部行。
  totalCount(): number { return this.values.length; }
  getData(index: number): T { return this.values[index]; }
  rows(): Array<T> { return this.values; }
  // 合并新的一页：按 key 去重并通知列表刷新；more 表示是否还有下一页。
  merge(values: Array<T>, key: (value: T) => string, more: boolean): void {
    const rows: Map<string, T> = new Map<string, T>();
    if (more) for (const value of this.values) rows.set(key(value), value);
    for (const value of values) rows.set(key(value), value);
    this.replace(Array.from(rows.values()));
  }
  // 整体替换数据并通知重新加载。
  replace(values: Array<T>): void { this.values = values; for (const listener of this.listeners) listener.onDataReloaded(); }
  // LazyForEach 注册 / 注销监听。
  registerDataChangeListener(listener: DataChangeListener): void { if (!this.listeners.includes(listener)) this.listeners.push(listener); }
  unregisterDataChangeListener(listener: DataChangeListener): void { this.listeners = this.listeners.filter((value: DataChangeListener): boolean => value !== listener); }
}

/**
 * 聊天类列表的 LazyForEach 数据源。update() 把新数组转换成最小的变化通知：
 * 在前面插入了更早的消息 → 在 0 位置 ADD（并 CHANGE 原第一行，因为它的时间分隔线可能变化）；
 * 在末尾追加了新消息 → 在末尾 ADD；行没变 → 只 CHANGE 渲染键变化的行；其他情况 → 整体重新加载。
 * 前插方式能让 List.maintainVisibleContentPosition 保持当前阅读位置不跳动。
 */
export class DiffDataSource<T> implements IDataSource {
  private values: Array<T> = [];
  private listeners: Array<DataChangeListener> = [];
  private readonly identity: (value: T) => string;
  private readonly renderKey: (value: T, index: number, values: Array<T>) => string;

  // identity：消息的唯一 id；renderKey：决定某一行是否需要重新渲染的键。
  constructor(identity: (value: T) => string, renderKey: (value: T, index: number, values: Array<T>) => string) {
    this.identity = identity;
    this.renderKey = renderKey;
  }

  // 总行数 / 取第 index 行 / 某行的渲染键。
  totalCount(): number { return this.values.length; }
  getData(index: number): T { return this.values[index]; }
  keyAt(index: number): string { return this.renderKey(this.values[index], index, this.values); }

  // 用新数组更新数据源，并发出尽量小的变化通知。
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

  // LazyForEach 注册 / 注销监听。
  registerDataChangeListener(listener: DataChangeListener): void { if (!this.listeners.includes(listener)) this.listeners.push(listener); }
  unregisterDataChangeListener(listener: DataChangeListener): void { this.listeners = this.listeners.filter((value: DataChangeListener): boolean => value !== listener); }

  // 判断 previous 是否与 next 中从 offset 开始的同长度片段 id 完全一致。
  private sameIds(previous: Array<T>, next: Array<T>, offset: number): boolean {
    for (let index = 0; index < previous.length; index++) {
      if (this.identity(previous[index]) !== this.identity(next[index + offset])) return false;
    }
    return true;
  }
  // 发送批量变化通知 / 整体重新加载。
  private notify(operations: Array<DataOperation>): void { for (const listener of this.listeners) listener.onDatasetChange(operations); }
  private reload(): void { for (const listener of this.listeners) listener.onDataReloaded(); }
}
