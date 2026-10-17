/**
 * 【文件职责】桌面卡片内“刷新”按钮的消息约定：卡片页面用 postCardAction 发送消息，
 * ServiceCardFormAbility.onFormEvent 收到后用这里的函数识别。
 */
export const SERVICE_CARD_REFRESH_MESSAGE: string = 'refresh-service-card';

// 卡片事件参数的结构。
interface ServiceCardEventParams {
  message: string;
}

// 判断收到的消息是否为“刷新推荐”（兼容直接字符串与 JSON 两种形式）。
export function isServiceCardRefreshMessage(message: string): boolean {
  if (message === SERVICE_CARD_REFRESH_MESSAGE) return true;
  try {
    // postCardAction 的 params 在到达 onFormEvent 之前会被序列化成 JSON 字符串，这里需要解析。
    const params: ServiceCardEventParams = JSON.parse(message) as ServiceCardEventParams;
    return params !== null && typeof params === 'object' &&
      typeof params.message === 'string' && params.message === SERVICE_CARD_REFRESH_MESSAGE;
  } catch (_error) {
    return false;
  }
}
