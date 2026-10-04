export const SERVICE_CARD_REFRESH_MESSAGE: string = 'refresh-service-card';

interface ServiceCardEventParams {
  message: string;
}

export function isServiceCardRefreshMessage(message: string): boolean {
  if (message === SERVICE_CARD_REFRESH_MESSAGE) return true;
  try {
    // postCardAction message params are serialized before onFormEvent receives them.
    const params: ServiceCardEventParams = JSON.parse(message) as ServiceCardEventParams;
    return params !== null && typeof params === 'object' &&
      typeof params.message === 'string' && params.message === SERVICE_CARD_REFRESH_MESSAGE;
  } catch (_error) {
    return false;
  }
}
