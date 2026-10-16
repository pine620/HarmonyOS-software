export function contentDate(value: number): string { return value > 0 ? new Date(value).toLocaleString() : '—'; }
