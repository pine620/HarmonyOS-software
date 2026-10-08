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
