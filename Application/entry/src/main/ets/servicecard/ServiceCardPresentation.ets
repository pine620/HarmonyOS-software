import { SERVICE_CARD_REFRESH_MESSAGE } from '../service/ServiceCardInteraction';

interface ServiceCardRouteParams {
  shikeRoute: string;
  shikeCardId: string;
  shikeTab: string;
}

interface ServiceCardRouteAction {
  action: string;
  bundleName: string;
  abilityName: string;
  params: ServiceCardRouteParams;
}

interface ServiceCardMessageParams {
  message: string;
}

interface ServiceCardMessageAction {
  action: string;
  params: ServiceCardMessageParams;
}

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

export function serviceCardRefreshAction(): ServiceCardMessageAction {
  const params: ServiceCardMessageParams = { message: SERVICE_CARD_REFRESH_MESSAGE };
  const action: ServiceCardMessageAction = { action: 'message', params };
  return action;
}

export function serviceCardShortScore(scoreText: string): string {
  const match: RegExpMatchArray | null = scoreText.trim().match(/^(\d{1,2})\/10(?:\s|$)/);
  if (match === null) return '未评分';
  const score: number = Number(match[1]);
  return Number.isInteger(score) && score >= 1 && score <= 10 ? `${score}/10` : '未评分';
}

export function serviceCardPrice(priceText: string): string {
  const value: string = priceText.trim();
  return /^¥\d+(?:\.\d{1,2})?$/.test(value) ? value : '价格待补充';
}
