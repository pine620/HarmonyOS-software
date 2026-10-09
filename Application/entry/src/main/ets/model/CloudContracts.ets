export type CardStatus = 'APPROVED' | 'REMOVED';
export type FoodCategory = 'staple' | 'bakery' | 'drink' | 'snack' | 'fresh' | 'other';
export type FoodConsumptionMode = 'UNSPECIFIED' | 'DELIVERY' | 'DINE_IN';
export type FoodCategoryV2 = 'NOODLES' | 'RICE_SET' | 'HOT_POT' | 'GRILL_FRIED' | 'SNACK' |
  'FAST_WESTERN' | 'BREAKFAST_BAKERY' | 'DESSERT' | 'DRINK' | 'PACKAGED' | 'OTHER';
export type FoodVisibility = 'PUBLIC' | 'FRIENDS';
export type CardReviewState = 'LEGACY_APPROVED' | 'PENDING_POST_REVIEW' | 'APPROVED' | 'TAKEN_DOWN' | 'REQUEST_CHANGE';
export type CardReactionType = 'LIKE' | 'DISLIKE';
export type CardRevisionStatus = 'PENDING' | 'APPROVED' | 'REJECTED' | 'WITHDRAWN';
export type MaintenanceJobType = 'PURGE_GROUP' | 'MODERATION_AUDIT' | 'PURGE_CARD' | 'DELETE_ACCOUNT' | 'BACKFILL_CARD' | 'MIGRATE_REACTION' | 'PURGE_CONVERSATION' | 'MIGRATE_PERSONAL_COLLECTION' | 'MIGRATE_PERSONAL_COLLECTION_BATCH' | 'MEDIA_COVER_BACKFILL';
export type MaintenanceJobStatus = 'PENDING' | 'RUNNING' | 'RETRY_WAIT' | 'DONE' | 'CANCELLED' | 'FAILED';

/** Cloud DB Date values cross the JSON boundary as millisecond numbers. */
export interface CardReactionRecord {
  cardId: string;
  uid: string;
  reaction: CardReactionType;
  createdAt: number;
  updatedAt: number;
}

/** Storage contract; public card responses never include the access-grant row. */
export interface FriendContentAccessGrantRecord {
  authorUid: string;
  viewerUid: string;
  accessThroughAt: number;
  accessThroughSequence: number;
  revoked: boolean;
  revokedAt?: number;
  updatedAt: number;
}

export interface SetCardVisibilityRequest {
  cardId: string;
  visibility: FoodVisibility;
  expectedModifiedAt?: number;
}

export interface SetCardVisibilityResponse {
  success: boolean;
  cardId: string;
  visibility: FoodVisibility;
  modifiedAt: number;
  publishedAt?: number;
  friendVisibilitySince?: number;
  friendVisibilitySequence?: number;
  lifecycleGeneration?: number;
  unchanged: boolean;
}

export interface RevokeFriendContentAccessRequest {
  viewerUid: string;
}

export interface FriendCleanupJobRequest {
  jobId: string;
}

export interface PublishRequestRecord {
  requestId: string;
  uid: string;
  operationType: string;
  payloadHash: string;
  resultEntityId?: string;
  status: string;
  createdAt: number;
  expiresAt: number;
}

export interface FoodCardRevisionRecord {
  revisionId: string;
  cardId: string;
  authorUid: string;
  baseModifiedAt: number;
  baseLifecycleGeneration: number;
  payloadJson: string;
  mediaManifestJson: string;
  status: CardRevisionStatus;
  submittedAt: number;
  reviewedAt?: number;
  reviewReason?: string;
}

/** Server-owned task metadata; clients do not access the database directly. */
export interface MaintenanceJobRecord {
  jobId: string;
  jobType: MaintenanceJobType;
  entityId: string;
  ownerUid?: string;
  generation: number;
  status: MaintenanceJobStatus;
  runAfterAt: number;
  leaseUntilAt?: number;
  leaseOwner?: string;
  attemptCount: number;
  cursor?: string;
  checkpointJson?: string;
  lastErrorCode?: string;
  createdAt: number;
  updatedAt: number;
}

export interface UserProfile {
  uid: string;
  nickname: string;
  avatarUrl: string;
  // Added by the social service. Optional while older cloud deployments are
  // still returning the pre-friends profile shape.
  friendCode?: string;
  // Storage object data is kept separate from the resolved URL so a profile
  // response never exposes a stale signed URL. Older profiles may omit both.
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

export interface UpdateProfileRequest {
  nickname: string;
  // Empty means retain the existing avatar. The media is prepared and uploaded
  // through the established owned-photo flow before this request is sent.
  avatarMediaId: string;
  // Empty retains the current cover; clearCover explicitly restores the default background.
  coverMediaId?: string;
  clearCover?: boolean;
  // Used only after Account Kit verifies the session, to read/create the
  // app-owned profile without requesting Huawei profile scopes.
  readOnly?: boolean;
}

export interface AuthSession {
  accessToken: string;
  expiresAt: number;
  profile: UserProfile;
  migrationTicket?: string;
}

export type HuaweiAccountOperation = 'SIGN_IN' | 'LINK_HUAWEI';

/**
 * `SIGN_IN` exchanges a Huawei authorization code for an AGC session.
 * `LINK_HUAWEI` associates a Huawei credential with an existing native AGC
 * email session through the Auth Service user-link endpoint.
 */
export interface ExchangeHuaweiAccountRequest {
  operation: HuaweiAccountOperation;
  authorizationCode?: string;
  nonce?: string;
}

export interface MigrationTicketRequest {
  ticket: string;
}

export interface MigrationTicketResponse {
  ticket: string;
  expiresAt: number;
}

/**
 * deviceId is an app-generated random installation identifier. The Push Token
 * is sent only after explicit notification opt-in and is encrypted at rest by
 * the trusted cloud object before it reaches Cloud DB.
 */
export interface PushDeviceRequest {
  deviceId: string;
  token: string;
}

export interface PushDeviceUnregisterRequest {
  deviceId: string;
}

/**
 * A desktop-card form registration is separate from friend notifications.
 * The client reports only opaque local identifiers and the Push Token after
 * the user explicitly enables remote card synchronization.
 */
export interface ServiceCardFormSyncRequest {
  deviceId: string;
  token: string;
  formIds: Array<string>;
}

export interface ServiceCardFormSyncResponse {
  success: boolean;
  registeredFormCount: number;
}

export interface ServiceCardFormUnregisterRequest {
  deviceId: string;
}

export interface ServiceCardRemoteUpdateRequest {
  cardId: string;
}

export interface ServiceCardRemoteUpdateResponse {
  success: boolean;
  registeredFormCount: number;
  deliveredFormCount: number;
  rateLimitedFormCount: number;
  deliveryAvailable: boolean;
}

export interface CardIdRequest {
  cardId: string;
}

export interface CardDetailRequest extends CardIdRequest {
  includeComments: boolean;
}

export interface SetCardReactionRequest extends CardIdRequest {
  reaction: CardReactionType | 'NONE';
  requestId?: string;
  expectedReaction?: CardReactionType | '';
}

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

export interface SubmitCardRevisionRequest extends CardIdRequest {
  requestId: string;
  baseModifiedAt: number;
  baseLifecycleGeneration: number;
  changes: CardRevisionChanges;
  mediaIds: Array<string>;
}

export interface CardRevisionIdRequest {
  revisionId: string;
}

export interface ModerateCardRevisionRequest extends CardRevisionIdRequest {
  action: 'APPROVE' | 'REJECT';
  reason: string;
}

export interface RevisionMediaRequest extends CardRevisionIdRequest {
  mediaId: string;
}

export interface StartMigrationJobRequest {
  jobType: 'BACKFILL_CARD' | 'MIGRATE_REACTION';
}

export interface MaintenanceJobIdRequest {
  jobId: string;
}

export interface MaintenanceJobsRequest {
  status?: MaintenanceJobStatus;
  pageToken: string;
}

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

export interface CardRevisionResponse {
  success?: boolean;
  alreadyProcessed?: boolean;
  revision: CardRevisionView;
}

export interface CardEditContextResponse {
  card: FoodCard;
  revision: CardRevisionView | null;
}

export interface ModerationRevisionsResponse {
  revisions: Array<CardRevisionView>;
  nextPageToken: string;
}

export interface MigrationCheckpoint {
  anchorUid?: string;
  baselineAt: number;
  scanned: number;
  migrated: number;
  skipped: number;
  failures: number;
  failedEntityId: string;
  coverageComplete: boolean;
  verificationCursor: string;
  verificationScanned: number;
  verificationMissing: number;
  phase: 'MIGRATE' | 'VERIFY';
}

export interface MaintenanceJobView {
  jobId: string;
  jobType: MaintenanceJobType;
  entityId: string;
  generation: number;
  status: MaintenanceJobStatus;
  attemptCount: number;
  cursor: string;
  lastErrorCode: string;
  runAfterAt: number | null;
  leaseUntilAt: number | null;
  createdAt: number | null;
  updatedAt: number | null;
}

export interface MigrationJobView extends MaintenanceJobView {
  checkpoint: MigrationCheckpoint;
}

export interface MigrationJobResponse {
  job: MigrationJobView;
}

export interface MigrationStatusResponse {
  jobs: Array<MigrationJobView>;
  cardCoverageComplete: boolean;
  reactionCoverageComplete: boolean;
  indexedQueryReady: boolean;
  userQueryVerificationRequired: boolean;
}

export interface ReportCardRequest {
  cardId: string;
  reason: string;
}

export type CardActionType = 'LIKE' | 'FAVORITE';
export type CommentReactionType = 'LIKE' | 'DISLIKE';

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

export interface CardComment {
  id: string;
  parentId: string;
  replyToNickname: string;
  authorNickname: string;
  authorAvatarUrl: string;
  authorAvatarPath: string;
  authorAvatarBucket: string;
  content: string;
  deleted: boolean;
  likeCount: number;
  dislikeCount: number;
  viewerReaction: CommentReactionType | '';
  viewerIsAuthor: boolean;
  // The service determines this from the authenticated user. It is optional
  // only so comments returned by an older deployed service remain readable.
  viewerCanDelete?: boolean;
  createdAt: number;
  replies: Array<CardComment>;
}

export interface ReceivedCommentItem {
  id: string;
  cardId: string;
  cardName: string;
  authorNickname: string;
  // Optional while an older cloud service is still deployed.
  authorAvatarUrl?: string;
  authorAvatarPath?: string;
  authorAvatarBucket?: string;
  content: string;
  kind: 'CARD_COMMENT' | 'REPLY';
  createdAt: number;
}

export interface ReceivedCommentsResponse {
  items: Array<ReceivedCommentItem>;
  nextPageToken: string;
}

export interface ReceivedCommentsRequest {
  pageToken: string;
  pageSize: number;
}

export interface CreateCardCommentRequest {
  cardId: string;
  parentCommentId: string;
  content: string;
}

export interface DeleteCardCommentRequest {
  commentId: string;
}

export interface ToggleCardActionRequest {
  cardId: string;
  action: CardActionType;
}

export interface ToggleCommentReactionRequest {
  commentId: string;
  reaction: CommentReactionType;
}

export interface CardActionResponse {
  active: boolean;
  likeCount: number;
  favoriteCount: number;
  viewerLiked: boolean;
  viewerFavorited: boolean;
  dislikeCount?: number;
  myReaction?: CardReactionType | '';
}

export interface CommentReactionResponse {
  active: boolean;
  reaction: CommentReactionType | '';
  likeCount: number;
  dislikeCount: number;
}

export interface EmptyRequest {
}

export interface RoundedLocation {
  latE3: number;
  lonE3: number;
  district: string;
}

export interface FoodCard {
  contentRevision?: string;
  mediaContentChanged?: boolean;
  mediaAccessDenied?: boolean;
  authorUid?: string;
  viewerWanted?: boolean;
  collectionReady?: boolean;
  collectionStatus?: string;
  collectionReason?: string;
  recommendationReasons?: Array<string>;
  id: string;
  // Optional while old deployments and historical rows retain their legacy shape.
  schemaVersion?: number;
  migrationSource?: string;
  consumptionMode?: FoodConsumptionMode;
  visibility?: FoodVisibility;
  merchantId?: string;
  merchantNameSnapshot?: string;
  merchantAddressSnapshot?: string;
  categoryV2?: string;
  categoryVersion?: number;
  // Unknown prices are omitted; a present zero represents an explicitly known zero.
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
  friendVisibilitySince?: number;
  friendVisibilitySequence?: number;
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
  /** The publisher's own tasting note, entered manually in the create flow. */
  reviewText: string;
  /** Integer taste score in the inclusive range 1–10. */
  tasteScore: number;
  sourceLink: string;
  category: FoodCategory;
  photoUrl: string;
  photoPath: string;
  photoBucket: string;
  photoWidth: number;
  photoHeight: number;
  // Client-only presentation state. Undefined means a nearby cover may still
  // be resolving; it is never included in a Cloud Object request.
  primaryPhotoResolved?: boolean;
  // True only when a published nearby cover has a storage path but resolving
  // its temporary download URL did not produce a usable URL.
  primaryPhotoLoadFailed?: boolean;
  // Author metadata is optional so older cloud responses remain renderable
  // while the card-detail surface rolls out the publisher identity block.
  authorNickname?: string;
  authorAvatarUrl?: string;
  authorAvatarPath?: string;
  authorAvatarBucket?: string;
  // The waterfall keeps using the primary-photo fields above. Detail pages
  // receive every approved uploader photo in chronological order.
  photos?: Array<CardPhoto>;
  viewerIsOwner?: boolean;
  likeCount?: number;
  favoriteCount?: number;
  viewerLiked?: boolean;
  viewerFavorited?: boolean;
  commentCount?: number;
  comments?: Array<CardComment>;
  district: string;
  distanceKm: number;
  status: CardStatus;
  createdAt: number;
}

export interface NearbyCardsRequest {
  latE3: number;
  lonE3: number;
  pageToken: string;
  pageSize: number;
}

/** Public homepage feed. Coordinates are deliberately absent. */
export interface PublicCardsRequest {
  scope: 'all';
  category: string;
  pageToken: string;
  pageSize: number;
}

export interface NearbyCardsResponse {
  cards: Array<FoodCard>;
  nextPageToken: string;
  district: string;
}

/**
 * The social ranking is intentionally unfiltered by category. The service
 * enforces the membership boundary: a card can only belong to the current
 * user or to a friendship whose status is ACCEPTED.
 */
export interface FriendRankingsResponse {
  cards: Array<FoodCard>;
}

export interface LocationCheckResponse {
  authenticated: boolean;
  locationAccepted: boolean;
  expiresAt: number;
}

export interface PrepareCardPhotoRequest {
  mimeType: string;
  byteSize: number;
  sha256: string;
  width: number;
  height: number;
}

export interface PrepareCardPhotoResponse {
  mediaId: string;
  cloudPath: string;
  bucketName: string;
}

/** JPEG bytes are sent only to the authenticated business cloud object. */
export interface UploadPreparedPhotoRequest {
  mediaId: string;
  dataBase64: string;
  sha256: string;
}

/** A server-authorized image payload, written to the app cache before rendering. */
export interface PublicMediaRequest {
  bucketName: string;
  cloudPath: string;
  metadataOnly?: boolean;
  variant?: string;
}

export interface PublicMediaResponse {
  mimeType: string;
  dataBase64: string;
  byteSize: number;
  sha256?: string;
  metadataOnly?: boolean;
  variant?: string;
}

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
  // mediaId remains the primary image for backward-compatible waterfall rows.
  mediaId: string;
  mediaIds: Array<string>;
  latE3?: number;
  lonE3?: number;
  district?: string;
}

export interface PublishCardResponse {
  cardId: string;
  status: CardStatus;
}

export interface MyCardsResponse {
  cards: Array<FoodCard>;
}

export interface OperationResponse {
  success: boolean;
}

export interface DeleteAccountResponse extends OperationResponse {
  cleanupPending: boolean;
  jobId: string;
}
