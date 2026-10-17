/**
 * 【文件职责】桌面卡片的展示与动作格式：点击打开 App 的路由参数、刷新消息、短评分与价格文本（两个卡片页面共用）。
 */
import { SERVICE_CARD_REFRESH_MESSAGE } from '../service/ServiceCardInteraction';

// 点击卡片打开 App 时携带的参数。
interface ServiceCardRouteParams {
  shikeRoute: string;
  shikeCardId: string;
  shikeTab: string;
}

// router 动作。
interface ServiceCardRouteAction {
  action: string;
  bundleName: string;
  abilityName: string;
  params: ServiceCardRouteParams;
}

// message 动作参数。
interface ServiceCardMessageParams {
  message: string;
}

// message 动作。
interface ServiceCardMessageAction {
  action: string;
  params: ServiceCardMessageParams;
}

// 生成“打开某张卡片”的动作。
export function serviceCardOpenAction(cardId: string): ServiceCardRouteAction {
  const id: string = cardId.trim();
  const params: ServiceCardRouteParams = {
    shikeRoute: id.length > 0 ? 'card' : 'tab', shikeCardId: id, shikeTab: '0'
  };
  const action: ServiceCardRouteAction = {
    action: 'router', bundleName: 'com.wyq.shike', abilityName: 'EntryAbility', params
  };
  return action;
}

// 生成“刷新推荐”的动作。
export function serviceCardRefreshAction(): ServiceCardMessageAction {
  const params: ServiceCardMessageParams = { message: SERVICE_CARD_REFRESH_MESSAGE };
  const action: ServiceCardMessageAction = { action: 'message', params };
  return action;
}

// 卡片上显示的短评分。
export function serviceCardShortScore(scoreText: string): string {
  const match: RegExpMatchArray | null = scoreText.trim().match(/^(\d{1,2})\/10(?:\s|$)/);
  if (match === null) return '未评分';
  const score: number = Number(match[1]);
  return Number.isInteger(score) && score >= 1 && score <= 10 ? `${score}/10` : '未评分';
}

// 卡片上显示的价格。
export function serviceCardPrice(priceText: string): string {
  const value: string = priceText.trim();
  return /^¥\d+(?:\.\d{1,2})?$/.test(value) ? value : '价格待补充';
}
