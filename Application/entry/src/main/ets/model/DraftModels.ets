import { CardRevisionView, FoodCard, FoodCategory, FoodCategoryV2, FoodConsumptionMode, PublishCardRequest, SubmitCardRevisionRequest } from './CloudContracts';
import { Merchant, MerchantChoice, CreateUserMerchantRequest } from './MerchantModels';
export interface DraftRetainedPhoto { id: string; url: string; }
/** Raw strings preserve incomplete amount/date input without discarding the form. */
export interface DraftForm {
  ownsPhoto: boolean;
  productName: string; price: string; dineInAvg: string; orderTotal: string; deliveryFee: string; consumedDate: string;
  sourceLink: string; reviewText: string; tasteScore: number; category: FoodCategory; categoryV2: FoodCategoryV2;
  mode: FoodConsumptionMode; merchant?: Merchant; merchantChoice?: MerchantChoice;
  merchantName: string; merchantAddress: string; platformKey: string; platformLabel: string; moreDeliveryInfo: boolean;
  historicalShop: string; retainedPhotos: Array<DraftRetainedPhoto>; uploadedMediaIds: Array<string>;
  publicationRequestId: string; requestUnconfirmed: boolean; pendingPublication?: PublishCardRequest; pendingRevision?: SubmitCardRevisionRequest;
  baseCard?: FoodCard; currentRevision?: CardRevisionView; merchantRequestId: string; pendingMerchantRequest?: CreateUserMerchantRequest;
  merchantRequestUnconfirmed: boolean; correctingMerchant: boolean;
}
export interface LocalDraft { draftId: string; ownerUid: string; draftType: 'NEW' | 'EDIT'; targetCardId: string; form: DraftForm; createdAt: number; updatedAt: number; reminderSent: boolean; }
export interface DraftMedia { path: string; sha256: string; width: number; height: number; byteSize: number; mimeType: string; }
export interface DraftRestore { draft: LocalDraft; media: Array<DraftMedia>; missingMediaCount: number; }
