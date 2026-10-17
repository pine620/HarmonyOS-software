/**
 * 【文件职责】校验卡片“来源链接”：只允许 HTTPS、长度受限、不含用户名密码等危险成分的网址，防止钓鱼或脚本链接。
 */
import url from '@ohos.url';

// 是否为安全的 HTTPS 来源链接。
export function isSafeHttpsSourceLink(value: string): boolean {
  const input: string = value.trim();
  if (input.length === 0 || input.length > 2048) return false;
  try {
    const parsed: url.URL = new url.URL(input);
    return parsed.protocol === 'https:' && parsed.hostname.length > 0 && parsed.username.length === 0 && parsed.password.length === 0;
  } catch (_error) { return false; }
}
