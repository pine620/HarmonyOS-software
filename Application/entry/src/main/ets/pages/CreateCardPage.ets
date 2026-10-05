import { common } from '@kit.AbilityKit';
import util from '@ohos.util';
import {
  FoodCategory, PrepareCardPhotoRequest, PublishCardRequest, RoundedLocation
} from '../model/CloudContracts';
import { CardRepository } from '../repository/CardRepository';
import { ImagePreparationService, PreparedPhoto } from '../service/ImagePreparationService';
import { LocationService } from '../service/LocationService';
import { MediaServiceUnavailableError } from '../service/CloudGateway';
import { PhotoUploadService } from '../service/PhotoUploadService';
import { categoryLabel, coverFor } from '../components/FoodCover';
import { tasteScoreLabel, tasteScoreReason } from '../model/TasteScore';
import { ErrorDetail, errorText } from '../common/ErrorKit';

interface CategoryOption {
  value: FoodCategory;
  label: string;
}

interface CategorySelectOption {
  value: string;
  icon: Resource;
}

function priceToFen(value: string): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? Math.round(parsed * 100) : 0;
}

const CATEGORY_OPTIONS: Array<CategoryOption> = [
  { value: 'staple', label: '米饭' },
  { value: 'bakery', label: '汤粉' },
  { value: 'drink', label: '饮品' },
  { value: 'snack', label: '炸鸡' },
  { value: 'fresh', label: '烧烤' },
  { value: 'other', label: '其他' }
];
const FIRST_SCORE_ROW: Array<number> = [1, 2, 3, 4, 5];
const SECOND_SCORE_ROW: Array<number> = [6, 7, 8, 9, 10];
const MAX_CARD_PHOTOS: number = 6;

function categoryIcon(category: FoodCategory): Resource {
  if (category === 'staple') return $r('app.media.create_category_rice');
  if (category === 'bakery') return $r('app.media.create_category_noodles');
  if (category === 'drink') return $r('app.media.create_category_drink');
  if (category === 'snack') return $r('app.media.create_category_snack');
  if (category === 'fresh') return $r('app.media.create_category_grill');
  return $r('app.media.create_category_other');
}

function categorySelectOptions(): Array<CategorySelectOption> {
  return CATEGORY_OPTIONS.map((option: CategoryOption): CategorySelectOption => {
    return { value: option.label, icon: categoryIcon(option.value) };
  });
}

@Component
export struct CreateCardPage {
  onPublished: () => void = (): void => {};
  @State productName: string = '';
  @State price: string = '';
  @State placeText: string = '';
  @State sourceLink: string = '';
  @State reviewText: string = '';
  @State tasteScore: number = 9;
  @State category: FoodCategory = 'staple';
  @State photoLabel: string = '';
  @State photoPreviewUris: Array<string> = [];
  @State ownsPhoto: boolean = false;
  @State publishing: boolean = false;
  @State hasPublishedNotice: boolean = false;
  @State status: string = '填写美食信息，留下你的真实口碑。';
  private repository: CardRepository = new CardRepository();
  private preparedPhotos: Array<PreparedPhoto> = [];
  private photoPreparationRevision: number = 0;
  private publicationRequestId: string = '';
  private pendingPublication: PublishCardRequest | undefined = undefined;
  private pendingFormFingerprint: string = '';

  private publicationFingerprint(): string {
    const fields: Array<string> = [this.productName.trim(), this.price.trim(), this.placeText.trim(),
      this.sourceLink.trim(), this.reviewText.trim(), this.tasteScore.toString(), this.category];
    return JSON.stringify(fields);
  }

  private scoreLabel(score: number = this.tasteScore): string {
    return tasteScoreLabel(score);
  }

  private scoreReason(score: number = this.tasteScore): string {
    return tasteScoreReason(score);
  }

  private hasValidPrice(): boolean {
    const value = this.price.trim();
    if (!/^\d+(\.\d{1,2})?$/.test(value)) return false;
    const parsed = Number(value);
    return Number.isFinite(parsed) && parsed >= 0 && parsed <= 1000000;
  }

  private resetPublicationState(): void {
    if (this.hasPublishedNotice) this.status = '填写美食信息，留下你的真实口碑。';
    this.hasPublishedNotice = false;
  }

  private resetForm(): void {
    this.photoPreparationRevision++;
    this.publicationRequestId = '';
    this.pendingPublication = undefined;
    this.pendingFormFingerprint = '';
    this.productName = '';
    this.price = '';
    this.placeText = '';
    this.sourceLink = '';
    this.reviewText = '';
    this.tasteScore = 9;
    this.category = 'staple';
    this.photoLabel = '';
    this.photoPreviewUris = [];
    this.ownsPhoto = false;
    this.preparedPhotos = [];
    this.hasPublishedNotice = false;
    this.status = '填写美食信息，留下你的真实口碑。';
  }

  private isScoreSelected(score: number): boolean {
    return this.tasteScore === score;
  }

  private publishBlocker(): string {
    if (this.productName.trim().length < 2) return '请填写至少 2 个字符的美食名称。';
    if (!this.hasValidPrice()) return '请填写有效价格，最多保留两位小数。';
    if (this.reviewText.trim().length < 2) return '请写下至少 2 个字符的真实评价。';
    if (this.tasteScore < 1 || this.tasteScore > 10) return '请选择 1–10 分的口味评分。';
    const link = this.sourceLink.trim();
    if (link.length > 0 && !/^https:\/\//i.test(link)) return '商品链接如填写，需以 https:// 开头。';
    if (this.preparedPhotos.length === 0) return '请至少添加一张本人实拍图，推荐页才会展示这张卡片。';
    if (!this.ownsPhoto) return '请确认实拍图由你拍摄或你有权使用。';
    return '';
  }

  private cardPreviewTitle(): string {
    return this.productName.trim().length > 0 ? this.productName.trim() : '未命名美食';
  }

  private async chooseOwnedPhoto(): Promise<void> {
    if (this.pendingPublication !== undefined) {
      this.status = '请先重试确认上次发布结果，再更换照片。';
      return;
    }
    const revision: number = this.photoPreparationRevision + 1;
    this.photoPreparationRevision = revision;
    try {
      const uris = await ImagePreparationService.selectMany(MAX_CARD_PHOTOS);
      if (revision !== this.photoPreparationRevision || uris.length === 0 || this.publishing) return;
      this.resetPublicationState();
      this.status = '正在本地处理 ' + uris.length + ' 张实拍图…';
      const prepared: Array<PreparedPhoto> = [];
      for (let index = 0; index < uris.length; index++) {
        const photo: PreparedPhoto = await ImagePreparationService.prepareOwnedPhoto(uris[index]);
        if (revision !== this.photoPreparationRevision || this.publishing) return;
        prepared.push(photo);
      }
      this.preparedPhotos = prepared;
      this.photoPreviewUris = uris;
      const totalBytes = prepared.reduce((sum: number, item: PreparedPhoto): number => sum + item.byteSize, 0);
      this.photoLabel = '已处理 ' + prepared.length + ' 张 JPEG · ' + (totalBytes / 1024).toFixed(0) + ' KB';
      this.ownsPhoto = false;
      this.status = '实拍图已在本地去除 EXIF/GPS；勾选权利声明后才会上传。';
    } catch (error) {
      if (revision !== this.photoPreparationRevision) return;
      this.resetPublicationState();
      this.preparedPhotos = [];
      this.photoPreviewUris = [];
      this.photoLabel = '实拍图处理失败';
      this.status = errorText(error as ErrorDetail);
    }
  }

  private async publish(): Promise<void> {
    if (this.publishing) return;
    const blocker = this.publishBlocker();
    if (blocker.length > 0) {
      this.status = blocker;
      return;
    }
    this.publishing = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const fingerprint: string = this.publicationFingerprint();
      const pending: PublishCardRequest | undefined = this.pendingPublication;
      if (pending !== undefined && this.pendingFormFingerprint !== fingerprint) {
        this.status = '上次发布结果尚未确认，请恢复原表单后重试，或先到“我的卡片”确认结果。';
        return;
      }
      if (this.publicationRequestId.length === 0) this.publicationRequestId = util.generateRandomUUID();
      let request: PublishCardRequest;
      if (pending !== undefined) {
        request = pending;
      } else {
        this.status = '正在获取本次发布所需的位置…';
        const location: RoundedLocation = await LocationService.getPreciseRoundedLocation(context);
        const mediaIds: Array<string> = [];
        for (let index = 0; index < this.preparedPhotos.length; index++) {
          const photo = this.preparedPhotos[index];
          this.status = '正在准备实拍图 ' + (index + 1) + '/' + this.preparedPhotos.length + '…';
          const photoRequest: PrepareCardPhotoRequest = {
            mimeType: photo.mimeType,
            byteSize: photo.byteSize,
            sha256: photo.sha256,
            width: photo.width,
            height: photo.height
          };
          const prepared = await this.repository.preparePhoto(context, photoRequest);
          this.status = '正在上传实拍图 ' + (index + 1) + '/' + this.preparedPhotos.length + '…';
          await PhotoUploadService.upload(context, prepared.bucketName, prepared.cloudPath, photo.data, photo.sha256);
          mediaIds.push(prepared.mediaId);
        }
        request = {
          requestId: this.publicationRequestId,
          productName: this.productName.trim(),
          brand: '',
          priceFen: priceToFen(this.price),
          priceLabel: '',
          originalPriceFen: 0,
          specification: '',
          shop: this.placeText.trim(),
          sellingPoints: [],
          publicOffers: [],
          reviewText: this.reviewText.trim(),
          tasteScore: this.tasteScore,
          sourceLink: this.sourceLink.trim(),
          category: this.category,
          mediaId: mediaIds[0],
          mediaIds,
          latE3: location.latE3,
          lonE3: location.lonE3,
          district: location.district
        };
        this.pendingPublication = request;
        this.pendingFormFingerprint = fingerprint;
      }
      this.status = '正在保存推荐卡…';
      const result = await this.repository.publish(context, request);
      if (result.status === 'APPROVED') {
        this.resetForm();
        this.hasPublishedNotice = true;
        this.status = '发布成功：你的评分和点评已显示在推荐页、口碑榜与详情页。';
        this.onPublished();
      } else {
        this.hasPublishedNotice = false;
        this.status = '发布结果异常，请到“我的”页面确认。';
      }
    } catch (error) {
      this.status = error instanceof MediaServiceUnavailableError
        ? '发布未完成：实拍图服务暂时不可用，请稍后再次发布；已填写内容和照片会保留。'
        : '发布未完成：' + errorText(error as ErrorDetail) + '；当前表单会保留。';
    } finally {
      this.publishing = false;
    }
  }

  @Builder
  private fieldLabel(title: string, required: boolean = false): void {
    Row({ space: 6 }) {
      Text(title).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink'));
      if (required) {
        Text('必填').fontSize(10).fontColor($r('app.color.accent_action'))
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .backgroundColor($r('app.color.accent_soft')).borderRadius(6);
      }
    }.width('100%');
  }

  @Builder
  private scoreButton(score: number): void {
    Button() {
      Column({ space: 2 }) {
        Text(score.toString()).fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(this.isScoreSelected(score) ? $r('app.color.accent_action') : $r('app.color.ink'));
        Text(this.scoreLabel(score)).fontSize(12)
          .fontColor(this.isScoreSelected(score) ? $r('app.color.accent_action') : $r('app.color.muted'));
      }.alignItems(HorizontalAlign.Center);
    }
      .height(56).layoutWeight(1)
      .backgroundColor(this.isScoreSelected(score) ? $r('app.color.accent_soft') : $r('app.color.canvas'))
      .border({ width: this.isScoreSelected(score) ? 1.5 : 1,
        color: this.isScoreSelected(score) ? $r('app.color.accent_action') : $r('app.color.line') })
      .borderRadius(12)
      .accessibilityText(`${score} 分，${this.scoreLabel(score)}${this.isScoreSelected(score) ? '，已选中' : ''}`)
      .onClick((): void => {
        this.tasteScore = score;
        this.resetPublicationState();
      });
  }

  @Builder
  private scoreStage(): void {
    Row({ space: 12 }) {
      Row({ space: 3 }) {
        Text(this.tasteScore.toString()).fontSize(38).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.accent_action')).lineHeight(42);
        Text('/10').fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.muted'))
          .padding({ top: 22 });
      }.alignItems(VerticalAlign.Top);
      Column({ space: 4 }) {
        Text(this.scoreLabel()).fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.accent_action')).width('100%');
        Text(this.scoreReason()).fontSize(12).lineHeight(17)
          .fontColor($r('app.color.ink')).width('100%').maxLines(2);
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
    }
    .width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.accent_soft')).borderRadius(15)
    .accessibilityText(`${this.tasteScore} 分，${this.scoreLabel()}。${this.scoreReason()}`);
  }

  @Builder
  private productInfoSection(): void {
    Column({ space: 10 }) {
      Text('商品信息').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
      Row({ space: 10 }) {
        Column({ space: 5 }) {
          this.fieldLabel('美食名称', true);
          TextInput({ text: this.productName, placeholder: '例如：黑椒鸡排饭' })
            .width('100%').height(48).fontSize(15).backgroundColor($r('app.color.canvas')).borderRadius(12)
            .onChange((value: string): void => {
              this.productName = value;
              this.resetPublicationState();
            });
        }.layoutWeight(1.65).alignItems(HorizontalAlign.Start);
        Column({ space: 5 }) {
          this.fieldLabel('价格', true);
          TextInput({ text: this.price, placeholder: '28.00' })
            .width('100%').height(48).fontSize(15).backgroundColor($r('app.color.canvas')).borderRadius(12)
            .onChange((value: string): void => {
              this.price = value;
              this.resetPublicationState();
            });
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      }.width('100%');

      Column({ space: 5 }) {
        this.fieldLabel('店名-地址（可选）');
        TextInput({ text: this.placeText, placeholder: '例如：湖滨银泰·平海路' })
          .width('100%').height(48).fontSize(15).backgroundColor($r('app.color.canvas')).borderRadius(12)
          .onChange((value: string): void => {
            this.placeText = value;
            this.resetPublicationState();
          });
      }.width('100%').alignItems(HorizontalAlign.Start);

      Column({ space: 5 }) {
        this.fieldLabel('商品链接（可选）');
        TextInput({ text: this.sourceLink, placeholder: 'https://…' })
          .width('100%').height(48).fontSize(15).backgroundColor($r('app.color.canvas')).borderRadius(12)
          .onChange((value: string): void => {
            this.sourceLink = value;
            this.resetPublicationState();
          });
      }.width('100%').alignItems(HorizontalAlign.Start);

      Column({ space: 5 }) {
        this.fieldLabel('美食分类', true);
        Select(categorySelectOptions())
          .selected(this.selectedCategoryIndex())
          .width('100%').height(48)
          .backgroundColor($r('app.color.canvas'))
          .accessibilityText(`选择美食分类，当前为${categoryLabel(this.category)}`)
          .onSelect((index: number, _value: string): void => {
            const selectedOption: CategoryOption | undefined = CATEGORY_OPTIONS[index];
            if (selectedOption === undefined) return;
            this.category = selectedOption.value;
            this.resetPublicationState();
          });
      }.width('100%').alignItems(HorizontalAlign.Start);
    }
    .width('100%').padding(14).backgroundColor($r('app.color.surface')).borderRadius(18)
    .border({ width: 1, color: $r('app.color.line') });
  }

  private selectedCategoryIndex(): number {
    for (let index: number = 0; index < CATEGORY_OPTIONS.length; index++) {
      const option: CategoryOption | undefined = CATEGORY_OPTIONS[index];
      if (option !== undefined && option.value === this.category) return index;
    }
    return 0;
  }

  @Builder
  private reviewSection(): void {
    Column({ space: 10 }) {
      Text('口碑表达').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
      this.scoreStage();
      Row({ space: 8 }) {
        ForEach(FIRST_SCORE_ROW, (score: number): void => {
          this.scoreButton(score);
        }, (score: number): string => score.toString());
      }.width('100%');
      Row({ space: 8 }) {
        ForEach(SECOND_SCORE_ROW, (score: number): void => {
          this.scoreButton(score);
        }, (score: number): string => score.toString());
      }.width('100%');

      Row() {
        this.fieldLabel('我的评论', true);
        Blank();
        Text(this.reviewText.length.toString() + ' 字').fontSize(12).fontColor($r('app.color.muted'));
      }.width('100%');
      TextArea({
        text: this.reviewText,
        placeholder: '说说味道、口感或值得推荐的理由…'
      })
        .width('100%').height(88).fontSize(15).backgroundColor($r('app.color.canvas')).borderRadius(12)
        .onChange((value: string): void => {
          this.reviewText = value;
          this.resetPublicationState();
        });
    }
    .width('100%').padding(14).backgroundColor($r('app.color.surface')).borderRadius(18)
    .border({ width: 1, color: $r('app.color.line') });
  }

  @Builder
  private photoSection(): void {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('本人实拍图').fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
        Blank();
        Text(`${this.photoPreviewUris.length}/${MAX_CARD_PHOTOS}`).fontSize(12)
          .fontColor($r('app.color.muted'));
      }.width('100%');
      Row({ space: 10 }) {
        Image(this.photoPreviewUris.length > 0 ? this.photoPreviewUris[0] : coverFor(this.category))
          .width(68).height(68).objectFit(ImageFit.Cover).borderRadius(13)
          .accessibilityText(this.photoPreviewUris.length > 0 ? '第一张待发布实拍图' : categoryLabel(this.category) + '分类示意图');
        Column({ space: 3 }) {
          Text(this.cardPreviewTitle()).fontSize(14).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink')).width('100%').maxLines(1);
          Text(this.photoPreviewUris.length > 0 ? '已选 ' + this.photoPreviewUris.length + ' 张' : '至少添加一张照片')
            .fontSize(12).fontColor($r('app.color.muted')).width('100%');
          if (this.photoLabel.length > 0) {
            Text(this.photoLabel).fontSize(12).fontColor($r('app.color.muted')).width('100%').maxLines(1);
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
        Button(this.photoPreviewUris.length > 0 ? '更换' : '添加')
          .height(48).width(76).fontSize(14).fontWeight(FontWeight.Medium)
          .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent_action'))
          .border({ width: 1, color: $r('app.color.line') }).borderRadius(12)
          .accessibilityText('选择最多六张本人实拍图')
          .onClick((): void => {
            this.chooseOwnedPhoto();
          });
      }.width('100%');
      Row({ space: 8 }) {
        Checkbox({ name: 'photo-rights', group: 'manual-publish' }).select(this.ownsPhoto)
          .onChange((value: boolean): void => {
            this.ownsPhoto = value;
            this.resetPublicationState();
          });
        Text('确认照片由本人拍摄或已获授权').fontSize(12).lineHeight(17)
          .fontColor($r('app.color.ink')).layoutWeight(1);
      }.width('100%').height(48);
    }
    .width('100%').padding(14).backgroundColor($r('app.color.surface')).borderRadius(18)
    .border({ width: 1, color: $r('app.color.line') });
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('制作推荐').fontSize(23).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).width('100%');
            Text('记录一顿好味道').fontSize(12).fontColor($r('app.color.muted')).width('100%');
          }.layoutWeight(1).alignItems(HorizontalAlign.Start);
          Button('重置')
            .height(28).fontSize(11).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accent_action'))
            .padding({ left: 9, right: 9, top: 6, bottom: 6 })
            .backgroundColor($r('app.color.canvas'))
            .border({ width: 1, color: $r('app.color.line') })
            .borderRadius(14)
            .enabled(!this.publishing)
            .accessibilityText('重置制作页已填写的信息')
            .onClick((): void => {
              this.resetForm();
            });
        }.width('100%');

        this.productInfoSection();
        this.reviewSection();
        this.photoSection();

        Text(this.status).fontSize(12).lineHeight(17)
          .fontColor(this.hasPublishedNotice ? $r('app.color.leaf') : $r('app.color.warning')).width('100%')
          .padding({ left: 10, right: 10, top: 8, bottom: 8 }).backgroundColor($r('app.color.accent_soft')).borderRadius(12);
        Button(this.publishing ? '正在发布…' : '发布这张卡')
          .enabled(!this.publishing)
          .width('100%').height(52).fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.on_accent_action')).backgroundColor($r('app.color.accent_action'))
          .borderRadius(15).onClick((): void => {
            this.publish();
          });
      }
      .width('100%').padding({ left: 14, right: 14, top: 14, bottom: 26 }).alignItems(HorizontalAlign.Start);
    }.width('100%').height('100%').backgroundColor($r('app.color.canvas'));
  }
}
