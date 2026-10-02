export type CardStatus = 'APPROVED' | 'REMOVED';
export type FoodCategory = 'staple' | 'bakery' | 'drink' | 'snack' | 'fresh' | 'other';

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

export interface ReportCardRequest {
  cardId: string;
  reason: string;
}

export type CardActionType = 'LIKE' | 'FAVORITE';
export type CommentReactionType = 'LIKE' | 'DISLIKE';

export interface CardPhoto {
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
  id: string;
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
}

export interface PublicMediaResponse {
  mimeType: string;
  dataBase64: string;
  byteSize: number;
}

export interface PublishCardRequest {
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
  latE3: number;
  lonE3: number;
  district: string;
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
