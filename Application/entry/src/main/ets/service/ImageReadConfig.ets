/**
 * 【文件职责】图片与首页相关的发布开关（编译期常量，改动后需重新构建 App）。
 * IMAGE_TRANSPORT：读图方式。BATCH = 批量调用 shike-image；LEGACY = 旧的逐张读取。每个账号会话只选一次，不做逐张探测。
 */
export type ImageTransport = 'BATCH' | 'LEGACY';
export const IMAGE_TRANSPORT: ImageTransport = 'BATCH';
// BATCH 模式下服务端返回 NOT_SUPPORTED 时是否自动退回 LEGACY；默认关闭，未部署 shike-image 时图片显示可重试占位。
export const IMAGE_ALLOW_LEGACY_ON_UNSUPPORTED: boolean = false;
// 二级页面（收藏、浏览记录等）在切换页签时短时间复用已加载的数据，避免重复读云端。
export const SECONDARY_DATA_REUSE_MS: number = 30000;
// 公开封面直读：已发布的 480px 封面直接从 Cloud Storage 读取，失败时回落到 shike-image。
export const PUBLIC_COVER_DIRECT_READ_ENABLED: boolean = true;
// 游客首页快照：游客的第一页推荐来自每 5 分钟生成一次的快照（先取预取结果，再读 Cloud Storage）。
export const HOME_SNAPSHOT_ENABLED: boolean = true;
// 首页快照所在的 Cloud Storage 实例名，必须等于云端环境变量 SHIKE_STORAGE_BUCKET；空串表示默认实例。切换后端时必须修改。
export const HOME_SNAPSHOT_BUCKET: string = 'shike-otidx';
/**
 * 客户端直传：邮箱原生登录的用户把实拍图直接上传到 Cloud Storage 的 private/pending/{uid}/，
 * shike-media 只负责校验并转为公开图片。这个开关同时决定是否把用户的 AGC Token 交给 Cloud Foundation Kit
 * （存储安全规则需要它来识别上传者）。false = 所有人都走原来的函数上传。
 */
export const CLIENT_DIRECT_UPLOAD_ENABLED: boolean = true;
