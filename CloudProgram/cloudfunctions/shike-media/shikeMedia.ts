type CloudResponse = {
  ok: boolean;
  data: object;
  message: string;
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

/**
 * Cloud Object invokes exported methods without preserving their class
 * receiver. Keep the dispatcher at module scope so every method works whether
 * the runtime supplies an instance or calls the handler as a bare function.
 */
async function executeMediaOperation(operation: MediaOperation, input: object): Promise<CloudResponse> {
  try {
    const data = await runtime[operation](input, process.env);
    return { ok: true, data, message: '' };
  } catch (error) {
    console.error(`${String(operation)} failed: ${runtime.safeLogError(error)}`);
    return {
      ok: false,
      data: {},
      message: error instanceof Error ? error.message : '媒体服务请求失败。'
    };
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
