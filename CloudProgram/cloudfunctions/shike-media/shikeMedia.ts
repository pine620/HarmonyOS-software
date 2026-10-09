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
  execute(input: object, env?: NodeJS.ProcessEnv): Promise<object>;
  prepareCardPhoto(input: object, env?: NodeJS.ProcessEnv): Promise<object>;
  uploadCardPhoto(input: object, env?: NodeJS.ProcessEnv): Promise<object>;
  getPublicMedia(input: object, env?: NodeJS.ProcessEnv): Promise<object>;
  safeLogError(error: unknown): string;
};

type MediaOperation = 'execute' | 'prepareCardPhoto' | 'uploadCardPhoto' | 'getPublicMedia';

const runtime = require('./runtime') as RuntimeModule;
interface ReadErrorsModule {
  READ_OPT_VERSION: string;
  requestId(input: object): string;
  errorResponse(error: unknown, operation: string, requestId: string): CloudResponse;
}
const readErrors = require('./shared/read-errors') as ReadErrorsModule;
interface ReleaseInfo { buildId: string; policyHash: string; protocolVersion: string; }
const releaseInfo = require('./shared/release-info') as { buildInfo: ReleaseInfo };

/**
 * Cloud Object invokes exported methods without preserving their class
 * receiver. Keep the dispatcher at module scope so every method works whether
 * the runtime supplies an instance or calls the handler as a bare function.
 */
async function executeMediaOperation(operation: MediaOperation, input: object): Promise<CloudResponse> {
  const requestId: string = readErrors.requestId(input);
  const operationName: string = operation === 'getPublicMedia' ? 'get-public-media' : operation;
  try {
    const request = Object.assign({}, input, { readRequestId: requestId });
    const data = await runtime[operation](request, process.env);
    return { ok: true, data, message: '', requestId, operation: operationName, functionVersion: readErrors.READ_OPT_VERSION, ...releaseInfo.buildInfo };
  } catch (error) {
    const response: CloudResponse = readErrors.errorResponse(error, operationName, requestId);
    console.error(`${operationName} requestId=${requestId} code=${response.code} stage=${response.stage} failed: ${runtime.safeLogError(error)}`);
    return response;
  }
}

/**
 * Authenticated media boundary. Client methods validate the AGC access token
 * and the Cloud DB media record; execute remains for signed service-to-service
 * storage operations only.
 */
export class ShikeMedia {
  async prepareCardPhoto(input: object): Promise<CloudResponse> {
    return executeMediaOperation('prepareCardPhoto', input);
  }

  async uploadCardPhoto(input: object): Promise<CloudResponse> {
    return executeMediaOperation('uploadCardPhoto', input);
  }

  async getPublicMedia(input: object): Promise<CloudResponse> {
    return executeMediaOperation('getPublicMedia', input);
  }

  /** Internal only: shike-service supplies a HMAC-protected envelope. */
  async execute(input: object): Promise<CloudResponse> {
    return executeMediaOperation('execute', input);
  }
}
