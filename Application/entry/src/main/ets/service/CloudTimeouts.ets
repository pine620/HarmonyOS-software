/**
 * 【文件职责】个别云调用的单独超时（其余调用使用 Cloud Foundation 默认的 70 秒）。
 * 卡片互动写入超时属于“结果未知”：CardInteractionController 会用同一个请求 UUID 查询回执或重发，
 * 服务端按 UUID 去重，所以同一次点击绝不会被执行两次。昵称登录要串行访问 AGC 认证接口，给 45 秒。
 */
export const INTERACTION_WRITE_TIMEOUT_MS: number = 12 * 1000;
export const INTERACTION_READ_TIMEOUT_MS: number = 10 * 1000;
export const NICKNAME_AUTH_TIMEOUT_MS: number = 45 * 1000;
