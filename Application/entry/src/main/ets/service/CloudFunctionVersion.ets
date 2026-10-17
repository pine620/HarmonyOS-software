/**
 * 【文件职责】所有云函数调用使用的版本号。
 * 本项目不上架应用市场，所以固定调用各函数的 $latest 版本，没有需要维护的发布别名；
 * 注意：云端一部署，所有连接同一后端的成员立即生效。
 */
export const CLOUD_FUNCTION_VERSION: string = '$latest';
