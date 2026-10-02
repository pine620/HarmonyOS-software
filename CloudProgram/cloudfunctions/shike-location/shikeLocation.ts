type CloudEnvelope = {
  accessToken: string;
  payload: object;
};

type CloudResponse = {
  ok: boolean;
  data: object;
  message: string;
};

type RuntimeModule = {
  executeOperation(operation: string, input: CloudEnvelope, env?: NodeJS.ProcessEnv): Promise<object>;
  safeLogError(error: unknown): string;
};

const runtime = require('./runtime') as RuntimeModule;

async function executeCloudOperation(operation: string, input: CloudEnvelope): Promise<CloudResponse> {
  try {
    const data = await runtime.executeOperation(operation, input, process.env);
    return { ok: true, data, message: '' };
  } catch (error) {
    console.error(`${operation} failed: ${runtime.safeLogError(error)}`);
    const message = error instanceof Error ? error.message : '位置服务暂时不可用。';
    return { ok: false, data: {}, message };
  }
}

/**
 * Temporary isolated location object. checkLocation separates account-token and
 * coordinate validation from the Cloud DB query performed by listNearbyCards.
 */
export class ShikeLocation {
  checkLocation(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('check-location', input);
  }

  listNearbyCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-nearby-cards', input);
  }
}
