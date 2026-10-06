import url from '@ohos.url';

export function isSafeHttpsSourceLink(value: string): boolean {
  const input: string = value.trim();
  if (input.length === 0 || input.length > 2048) return false;
  try {
    const parsed: url.URL = new url.URL(input);
    return parsed.protocol === 'https:' && parsed.hostname.length > 0 && parsed.username.length === 0 && parsed.password.length === 0;
  } catch (_error) { return false; }
}
