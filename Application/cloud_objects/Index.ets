/**
 * 【文件职责】本地 HAR @shike/cloud-objects 的公共导出（entry 模块通过 oh-package.json5 依赖它）。
 * 只包含 shike-auth 与 shike-media 两个云对象的调用代理（由 DevEco “Generate Invoke Interface” 生成，src 下文件不要手改），
 * 其余云对象由 CloudGateway 直接用 cloudFunction.call 调用。CloudEnvelope 是所有云对象方法的统一入参格式。
 */
export { importObject } from './src/main/ets/ImportObject';
export { ShikeMedia } from './src/main/ets/shike-media/ShikeMedia';

export interface CloudEnvelope {
  accessToken: string;
  payload: object;
}

export { ShikeAuth } from './src/main/ets/shike-auth/ShikeAuth';
