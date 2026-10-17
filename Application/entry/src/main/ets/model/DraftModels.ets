/**
 * 【文件职责】本机草稿箱的数据结构（DraftStore 使用）。
 */
import { CardRevisionView, FoodCard, FoodCategory, FoodCategoryV2, FoodConsumptionMode, PublishCardRequest, SubmitCardRevisionRequest } from './CloudContracts';
import { Merchant, MerchantChoice, CreateUserMerchantRequest } from './MerchantModels';
// 编辑已发布卡片时保留的原有图片。
export interface DraftRetainedPhoto { id: string; url: string; }
// 表单原样保存字符串，金额、日期等未填完的输入也不会丢失。
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
// 一条草稿（新建 NEW 或编辑 EDIT）。
export interface LocalDraft { draftId: string; ownerUid: string; draftType: 'NEW' | 'EDIT'; targetCardId: string; form: DraftForm; createdAt: number; updatedAt: number; reminderSent: boolean; }
// 草稿中的一张本地图片文件。
export interface DraftMedia { path: string; sha256: string; width: number; height: number; byteSize: number; mimeType: string; }
// 恢复草稿的结果（缺失的图片数量会提示用户）。
export interface DraftRestore { draft: LocalDraft; media: Array<DraftMedia>; missingMediaCount: number; }
