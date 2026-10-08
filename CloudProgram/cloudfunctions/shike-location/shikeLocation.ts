type CloudEnvelope = {
  accessToken: string;
  payload: object;
  readRequestId?: string;
  readAttempt?: number;
};

type CloudResponse = {
  ok: boolean;
  data: object;
  message: string;
  code?: string;
  retryable?: boolean;
  retryAfterMs?: number;
  requestId?: string;
  operation?: string;
  stage?: string;
  functionVersion?: string;
};

type RuntimeModule = {
  executeOperation(operation: string, input: CloudEnvelope, env?: NodeJS.ProcessEnv): Promise<object>;
  safeLogError(error: unknown): string;
};

const runtime = require('./runtime') as RuntimeModule;
interface ReadErrorsModule {
  requestId(input: object): string;
  errorResponse(error: unknown, operation: string, requestId: string): CloudResponse;
}
const readErrors = require('./read-errors') as ReadErrorsModule;

async function executeCloudOperation(operation: string, input: CloudEnvelope): Promise<CloudResponse> {
  const requestId: string = readErrors.requestId(input);
  try {
    const request = Object.assign({}, input, { readRequestId: requestId });
    const data = await runtime.executeOperation(operation, request, process.env);
    return { ok: true, data, message: '', requestId, operation, functionVersion: 'stages89-20261007-v1' };
  } catch (error) {
    const response: CloudResponse = readErrors.errorResponse(error, operation, requestId);
    console.error(`${operation} requestId=${requestId} code=${response.code} stage=${response.stage} failed: ${runtime.safeLogError(error)}`);
    return response;
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
