/**
 * 【文件职责】“删除记录”等页面共用：把时间戳格式化为本地日期时间，无效时显示“—”。
 */
export function contentDate(value: number): string { return value > 0 ? new Date(value).toLocaleString() : '—'; }
