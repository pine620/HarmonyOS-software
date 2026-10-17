/**
 * 【文件职责】端云之间最主要的数据结构（DTO）：用户资料、登录会话、卡片、图片、发布与修订、Push 与桌面卡片登记等。
 * 这些接口描述的是云函数的请求参数与返回值，字段名必须与云端 runtime.js 中的实现保持一致；
 * 新增字段时，云端应保证旧客户端可以忽略、新客户端对缺失字段有兜底（因此很多字段是可选的）。
 */
// 卡片状态：APPROVED 公开可见 / REMOVED 已移除。
export type CardStatus = 'APPROVED' | 'REMOVED';
// 旧版 6 个分类（兼容历史数据与默认封面）。
export type FoodCategory = 'staple' | 'bakery' | 'drink' | 'snack' | 'fresh' | 'other';
// 消费方式：未指定 / 外卖 / 到店。
export type FoodConsumptionMode = 'UNSPECIFIED' | 'DELIVERY' | 'DINE_IN';
// 新版 11 个分类。
export type FoodCategoryV2 = 'NOODLES' | 'RICE_SET' | 'HOT_POT' | 'GRILL_FRIED' | 'SNACK' |
  'FAST_WESTERN' | 'BREAKFAST_BAKERY' | 'DESSERT' | 'DRINK' | 'PACKAGED' | 'OTHER';
// 可见性：目前所有卡片都是公开的。
export type FoodVisibility = 'PUBLIC';
// 卡片审核状态（发布即公开，之后可能被事后审核下架或要求修改）。
export type CardReviewState = 'LEGACY_APPROVED' | 'PENDING_POST_REVIEW' | 'APPROVED' | 'TAKEN_DOWN' | 'REQUEST_CHANGE';
// 对卡片的反应：赞 / 踩。
export type CardReactionType = 'LIKE' | 'DISLIKE';
// 作者修订的状态：待生效 / 已生效 / 被拒绝 / 已撤回。
export type CardRevisionStatus = 'PENDING' | 'APPROVED' | 'REJECTED' | 'WITHDRAWN';

// 用户资料（upsert-profile 等返回）。
export interface UserProfile {
  uid: string;
  nickname: string;
  avatarUrl: string;
  // 由社交服务补充的字段。旧版云端仍可能返回没有好友信息的资料，所以是可选的。
  friendCode?: string;
  // 存储位置与解析后的地址分开保存，避免响应里出现过期的签名地址；旧资料可能两者都没有。
  avatarPath?: string;
  avatarBucket?: string;
  coverPath?: string;
  coverBucket?: string;
  coverUrl?: string;
  accountStatus: string;
  publishCount: number;
  createdAt: number;
  updatedAt: number;
}

// 更新资料请求；readOnly=true 时只读取（登录后加载资料用）。
export interface UpdateProfileRequest {
  nickname: string;
  // 空串表示保留现有头像。新头像要先按“自有图片”流程准备并上传，再发送本请求。
  avatarMediaId: string;
  // 空串表示保留当前主页背景；clearCover=true 表示恢复默认背景。
  coverMediaId?: string;
  clearCover?: boolean;
  // 仅在 Account Kit 已验证会话之后使用：读取/创建食刻自己的资料，不申请华为账号资料权限。
  readOnly?: boolean;
}

// 华为账号交换后得到的会话（Token、到期时间与迁移票据）。
export interface AuthSession {
  accessToken: string;
  expiresAt: number;
  profile: UserProfile;
  migrationTicket?: string;
}

// 华为账号操作：SIGN_IN 登录 / LINK_HUAWEI 关联到当前邮箱账号。
export type HuaweiAccountOperation = 'SIGN_IN' | 'LINK_HUAWEI';

// SIGN_IN：用华为授权码换取 AGC 会话；LINK_HUAWEI：通过认证服务的 user-link 接口，把华为身份关联到当前的邮箱原生会话。
export interface ExchangeHuaweiAccountRequest {
  operation: HuaweiAccountOperation;
  authorizationCode?: string;
  nonce?: string;
}

// 完成华为兼容登录时提交的迁移票据。
export interface MigrationTicketRequest {
  ticket: string;
  registerOnly?: boolean;
}

// 绑定邮箱时云端签发的一次性票据。
export interface MigrationTicketResponse {
  ticket: string;
  expiresAt: number;
}

// 登记本设备 Push：deviceId 是 App 随机生成的安装标识；Push Token 只在用户明确开启通知后发送，由受信任的云对象加密后才写入 Cloud DB。
export interface PushDeviceRequest {
  deviceId: string;
  token: string;
}

// 删除本设备 Push 登记的请求。
export interface PushDeviceUnregisterRequest {
  deviceId: string;
}

// 桌面卡片登记与好友通知是两回事。只有用户明确开启“桌面卡片远程同步”后，客户端才上报不透明的本地卡片 id 与 Push Token。
export interface ServiceCardFormSyncRequest {
  deviceId: string;
  token: string;
  formIds: Array<string>;
}

// 桌面卡片登记结果。
export interface ServiceCardFormSyncResponse {
  success: boolean;
  registeredFormCount: number;
}

// 删除桌面卡片登记的请求。
export interface ServiceCardFormUnregisterRequest {
  deviceId: string;
}

// 请求云端立即推送一次桌面卡片更新。
export interface ServiceCardRemoteUpdateRequest {
  cardId: string;
}

// 桌面卡片推送结果（含当天剩余次数等）。
export interface ServiceCardRemoteUpdateResponse {
  success: boolean;
  registeredFormCount: number;
  deliveredFormCount: number;
  rateLimitedFormCount: number;
  deliveryAvailable: boolean;
}

// 只含卡片 id 的通用请求。
export interface CardIdRequest {
  cardId: string;
}

// 读取卡片详情的请求。
export interface CardDetailRequest extends CardIdRequest {
}

// 设置赞/踩的请求。
export interface SetCardReactionRequest extends CardIdRequest {
  reaction: CardReactionType | 'NONE';
  requestId?: string;
  expectedReaction?: CardReactionType | '';
}

// 作者修订中允许修改的字段。
export interface CardRevisionChanges {
  consumptionMode?: FoodConsumptionMode;
  categoryV2?: FoodCategoryV2;
  merchantId?: string;
  itemPriceFen?: number | null;
  dineInAvgFen?: number | null;
  orderTotalFen?: number | null;
  deliveryFeeFen?: number | null;
  deliveryPlatformKey?: string;
  deliveryPlatformLabelSnapshot?: string;
  consumedAt?: number | null;

  productName?: string;
  brand?: string;
  priceFen?: number;
  priceLabel?: string;
  originalPriceFen?: number;
  specification?: string;
  shop?: string;
  sellingPoints?: Array<string>;
  publicOffers?: Array<string>;
  reviewText?: string;
  tasteScore?: number;
  sourceLink?: string;
  category?: FoodCategory;
  visibility?: FoodVisibility;
}

// 提交修订请求（含基准版本，用于冲突检测）。
export interface SubmitCardRevisionRequest extends CardIdRequest {
  requestId: string;
  baseModifiedAt: number;
  baseLifecycleGeneration: number;
  changes: CardRevisionChanges;
  mediaIds: Array<string>;
}

// 只含修订 id 的请求。
export interface CardRevisionIdRequest {
  revisionId: string;
}

// 修订的展示数据。
export interface CardRevisionView {
  revisionId: string;
  cardId: string;
  authorUid: string;
  status: CardRevisionStatus;
  baseModifiedAt: number;
  baseLifecycleGeneration: number;
  changes: CardRevisionChanges;
  mediaIds: Array<string>;
  submittedAt: number;
  reviewedAt: number | null;
  reviewReason: string;
}

// 提交 / 撤回修订后的返回值。
export interface CardRevisionResponse {
  success?: boolean;
  alreadyProcessed?: boolean;
  revision: CardRevisionView;
}

// 编辑上下文：当前内容、修订状态与可编辑性。
export interface CardEditContextResponse {
  card: FoodCard;
  revision: CardRevisionView | null;
}

// 举报卡片的请求（旧接口结构，CardReportModels 中另有同名的新结构）。
export interface ReportCardRequest {
  cardId: string;
  reason: string;
}


// 卡片中的一张图片：存储位置 + 尺寸 + 本机地址（url 只在客户端填写）。
export interface CardPhoto {
  sha256?: string;
  byteSize?: number;
  coverSha256?: string;
  coverByteSize?: number;
  coverWidth?: number;
  coverHeight?: number;
  accessDenied?: boolean;
  readAcceptedAt?: number;
  id: string;
  url: string;
  path: string;
  bucket: string;
  width: number;
  height: number;
}

// 旧版互动接口的返回值。
export interface CardActionResponse {
  active: boolean;
  likeCount: number;
  favoriteCount: number;
  viewerLiked: boolean;
  viewerFavorited: boolean;
  dislikeCount?: number;
  myReaction?: CardReactionType | '';
}

// 无参数请求。
export interface EmptyRequest {
}

// 卡片（端侧最核心的数据结构）。
export interface FoodCard {
  contentRevision?: string;
  mediaContentChanged?: boolean;
  mediaAccessDenied?: boolean;
  authorUid?: string;
  collectionReady?: boolean;
  collectionStatus?: string;
  collectionReason?: string;
  id: string;
  // 可选：旧版云端和历史数据仍保留旧的结构。
  schemaVersion?: number;
  migrationSource?: string;
  consumptionMode?: FoodConsumptionMode;
  visibility?: FoodVisibility;
  merchantId?: string;
  merchantNameSnapshot?: string;
  merchantAddressSnapshot?: string;
  categoryV2?: string;
  categoryVersion?: number;
  // 未知价格时字段不出现；出现 0 表示明确知道价格是 0。
  itemPriceFen?: number;
  dineInAvgFen?: number;
  orderTotalFen?: number;
  deliveryFeeFen?: number;
  queryPriceFen?: number;
  deliveryPlatformKey?: string;
  deliveryPlatformLabelSnapshot?: string;
  consumedAt?: number;
  publishedAt?: number;
  modifiedAt?: number;
  edited?: boolean;
  reviewState?: CardReviewState;
  reviewReason?: string;
  deletedAt?: number;
  purgeAt?: number;
  lifecycleGeneration?: number;
  dislikeCount?: number;
  myReaction?: CardReactionType | '';
  productName: string;
  brand: string;
  priceFen: number;
  priceLabel: string;
  originalPriceFen: number;
  specification: string;
  shop: string;
  sellingPoints: Array<string>;
  publicOffers: Array<string>;
  // 发布者手动填写的点评（≤600 字）。
  reviewText: string;
  // 口味评分，整数 1–10。
  tasteScore: number;
  sourceLink: string;
  category: FoodCategory;
  photoUrl: string;
  photoPath: string;
  photoBucket: string;
  photoWidth: number;
  photoHeight: number;
  // 仅客户端使用的展示状态。undefined 表示附近封面可能仍在加载；绝不会放进云请求。
  primaryPhotoResolved?: boolean;
  // 只有当已发布封面有存储路径、但获取临时地址失败时才为 true。
  primaryPhotoLoadFailed?: boolean;
  // 作者信息是可选的，这样旧版云端响应仍能正常显示。
  authorNickname?: string;
  authorAvatarUrl?: string;
  authorAvatarPath?: string;
  authorAvatarBucket?: string;
  // 瀑布流使用上面的首图字段；详情页会收到全部已通过的图片（按上传时间排序）。
  photos?: Array<CardPhoto>;
  viewerIsOwner?: boolean;
  likeCount?: number;
  favoriteCount?: number;
  viewerLiked?: boolean;
  viewerFavorited?: boolean;
  district: string;
  distanceKm: number;
  status: CardStatus;
  createdAt: number;
}

// 公开推荐流请求。刻意不包含坐标。
export interface PublicCardsRequest {
  scope: 'all';
  category: string;
  pageToken: string;
  pageSize: number;
}

// 推荐流一页的返回值：卡片、下一页游标、覆盖情况（是否因扫描上限只返回部分结果）。
export interface NearbyCardsResponse {
  coverage?: 'COMPLETE' | 'PARTIAL_SCAN_LIMIT' | 'PARTIAL_RESULT_LIMIT';
  scannedCandidateCount?: number;
  fetchedCandidateCount?: number;
  cards: Array<FoodCard>;
  nextPageToken: string;
  district: string;
}

// 图片准备请求（发布第 1 步）：本机已处理好的 JPEG 的尺寸、大小与 sha256。
export interface PrepareCardPhotoRequest {
  mimeType: string;
  byteSize: number;
  sha256: string;
  width: number;
  height: number;
}

// 图片准备返回：mediaId、目标路径 cloudPath 与存储桶名。
export interface PrepareCardPhotoResponse {
  mediaId: string;
  cloudPath: string;
  bucketName: string;
}

// 直传确认请求：客户端已经把图片上传到 private/pending/，请 shike-media 校验并转为公开图片。
export interface ConfirmPhotoUploadRequest {
  mediaId: string;
  sha256: string;
}

// 函数上传请求：Base64 图片字节 + sha256（只发送给鉴权的 shike-media）。
export interface UploadPreparedPhotoRequest {
  mediaId: string;
  dataBase64: string;
  sha256: string;
}

// 发布卡片请求（发布第 3 步）。
export interface PublishCardRequest {
  consumptionMode?: FoodConsumptionMode;
  categoryV2?: FoodCategoryV2;
  merchantId?: string;
  itemPriceFen?: number | null;
  dineInAvgFen?: number | null;
  orderTotalFen?: number | null;
  deliveryFeeFen?: number | null;
  deliveryPlatformKey?: string;
  deliveryPlatformLabelSnapshot?: string;
  consumedAt?: number | null;
  visibility?: FoodVisibility;
  requestId?: string;
  productName: string;
  brand: string;
  priceFen: number;
  priceLabel: string;
  originalPriceFen: number;
  specification: string;
  shop: string;
  sellingPoints: Array<string>;
  publicOffers: Array<string>;
  reviewText: string;
  tasteScore: number;
  sourceLink: string;
  category: FoodCategory;
  // mediaId 仍表示首图，兼容旧版瀑布流数据；mediaIds 为全部图片。
  mediaId: string;
  mediaIds: Array<string>;
  latE3?: number;
  lonE3?: number;
  district?: string;
}

// 发布结果：新卡片 id 与状态。
export interface PublishCardResponse {
  cardId: string;
  status: CardStatus;
}

// “我的卡片”返回值。
export interface MyCardsResponse {
  cards: Array<FoodCard>;
}

// 通用的操作结果。
export interface OperationResponse {
  success: boolean;
}

// 注销账号结果：cleanupPending=true 表示云端数据仍在后台清理中。
export interface DeleteAccountResponse extends OperationResponse {
  cleanupPending: boolean;
  jobId: string;
}

// 昵称 + 密码请求（登录或设置）。
export interface NicknamePasswordRequest {
  nickname: string;
  password: string;
}

// 昵称密码设置状态。
export interface PasswordAccountStatus {
  configured: boolean;
}

// 昵称登录得到的会话（Token 只存内存）。
export interface NicknameAuthSession {
  accessToken: string;
  expiresAt: number;
}

// 设置/修改密码的返回值：新会话 + 资料。
export interface PasswordAccountSetupResponse extends NicknameAuthSession {
  profile: UserProfile;
}

// 修改密码请求（expectedUid 防止换号后误改）。
export interface ChangePasswordRequest {
  currentPassword: string;
  newPassword: string;
  expectedUid: string;
}
