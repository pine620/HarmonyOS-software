import { AppDestinationStyle } from '../common/AppPageUi';
import { common } from '@kit.AbilityKit';
import { PrepareCardPhotoRequest, PrepareCardPhotoResponse, UpdateProfileRequest, UserProfile } from '../model/CloudContracts';
import { CardRepository } from '../repository/CardRepository';
import { AuthService } from '../service/AuthService';
import { AvatarCrop, ImageDimensions, ImagePreparationService, PreparedPhoto } from '../service/ImagePreparationService';
import { ImageRepository } from '../service/ImageRepository';
import { PhotoUploadService } from '../service/PhotoUploadService';
import { ErrorDetail, errorText } from '../common/ErrorKit';

/**
 * 【文件职责】编辑资料页面：修改昵称、头像（选图 → 拖动/双指缩放裁剪 → 本机处理 → 上传）与主页背景（选图 → 处理 → 上传 / 恢复默认），最后通过 upsert-profile 保存。
 */

const AVATAR_CROP_VIEWPORT = 240;

const CLOUD_BUSY_MAX_ATTEMPTS = 3;

const CLOUD_BUSY_RETRY_BASE_DELAY_MS = 800;

// 编辑资料页面。
@Component
export struct ProfileEditPage {
  onProfileChanged: (profile: UserProfile) => void = (_profile: UserProfile): void => {};
  @State profile: UserProfile | undefined = undefined;
  @State nickname: string = '';
  @State avatarPreviewUri: string = '';
  @State coverPreviewUri: string = '';
  @State preparingCover: boolean = false;
  @State clearCoverRequested: boolean = false;
  @State cropSourceUri: string = '';
  @State cropImageWidth: number = 0;
  @State cropImageHeight: number = 0;
  @State cropScale: number = 1;
  @State cropOffsetX: number = 0;
  @State cropOffsetY: number = 0;
  @State cropEditing: boolean = false;
  @State preparingAvatar: boolean = false;
  @State status: string = '';
  @State saving: boolean = false;
  private repository: CardRepository = new CardRepository();
  private preparedAvatar: PreparedPhoto | undefined = undefined;
  private avatarUpload: PrepareCardPhotoResponse | undefined = undefined;
  private avatarUploadCompleted: boolean = false;
  private preparedCover: PreparedPhoto | undefined = undefined;
  private coverUpload: PrepareCardPhotoResponse | undefined = undefined;
  private coverUploadCompleted: boolean = false;
  private activeCropTouchId: number = -1;
  private cropTouchStartX: number = 0;
  private cropTouchStartY: number = 0;
  private cropTouchStartOffsetX: number = 0;
  private cropTouchStartOffsetY: number = 0;
  private cropTouchStartDistance: number = 0;
  private cropTouchStartScale: number = 1;

  // 出现时读取当前资料。
  aboutToAppear(): void {
    this.profile = AuthService.profile();
    this.nickname = this.profile?.nickname || '';
    this.avatarPreviewUri = this.profile?.avatarUrl || '';
    this.coverPreviewUri = this.profile?.coverUrl || '';
    this.clearCoverRequested = false;
    void this.resolveCurrentCover();
    this.preparedAvatar = undefined;
    this.clearAvatarUpload();
    this.clearCrop();
    this.status = '';
  }

  // 补全当前主页背景的本地地址。
  private async resolveCurrentCover(): Promise<void> {
    const profile = this.profile;
    if (profile === undefined || profile.coverPath === undefined || profile.coverPath.length === 0 ||
      profile.coverBucket === undefined || profile.coverBucket.length === 0) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const coverUrl = await ImageRepository.getDownloadUrl(context, profile.coverBucket, profile.coverPath);
      if (this.preparedCover === undefined && !this.clearCoverRequested) this.coverPreviewUri = coverUrl;
    } catch (_error) {
      if (this.preparedCover === undefined && !this.clearCoverRequested) this.coverPreviewUri = '';
    }
  }

  // 当前裁剪参数。
  private cropSpec(): AvatarCrop {
    return {
      scale: this.cropScale,
      offsetX: this.cropOffsetX,
      offsetY: this.cropOffsetY
    };
  }

  // 把数值限制在区间内。
  private bounded(value: number, minimum: number, maximum: number): number {
    return Math.max(minimum, Math.min(maximum, value));
  }

  // 清除已准备的头像上传。
  private clearAvatarUpload(): void {
    this.avatarUpload = undefined;
    this.avatarUploadCompleted = false;
  }

  // 清除已准备的背景上传。
  private clearCoverUpload(): void {
    this.coverUpload = undefined;
    this.coverUploadCompleted = false;
  }

  // 选择主页背景图并在本机处理。
  private async chooseCover(): Promise<void> {
    if (this.saving || this.preparingCover || this.preparingAvatar) return;
    try {
      const uri = await ImagePreparationService.selectOne();
      if (uri.length === 0) return;
      this.preparingCover = true;
      this.status = '正在本机处理主页背景…';
      const prepared: PreparedPhoto = await ImagePreparationService.prepareOwnedPhoto(uri);
      this.preparedCover = prepared;
      this.coverPreviewUri = uri;
      this.clearCoverRequested = false;
      this.clearCoverUpload();
      this.status = '背景图片已选定，保存后才会上传。';
    } catch (error) {
      this.preparedCover = undefined;
      this.clearCoverUpload();
      this.status = `背景处理失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.preparingCover = false;
    }
  }

  // 上传已处理的背景图，返回 mediaId。
  private async uploadPreparedCover(context: common.UIAbilityContext): Promise<string> {
    const cover: PreparedPhoto | undefined = this.preparedCover;
    if (cover === undefined) return '';
    if (this.coverUpload === undefined) {
      const photoRequest: PrepareCardPhotoRequest = {
        mimeType: cover.mimeType,
        byteSize: cover.byteSize,
        sha256: cover.sha256,
        width: cover.width,
        height: cover.height
      };
      this.status = '正在准备主页背景…';
      this.coverUpload = await this.retryCloudBusy('背景准备', (): Promise<PrepareCardPhotoResponse> =>
        this.repository.preparePhoto(context, photoRequest));
    }
    const upload: PrepareCardPhotoResponse | undefined = this.coverUpload;
    if (upload === undefined) throw new Error('背景上传准备记录缺失，请重新选择图片。');
    if (!this.coverUploadCompleted) {
      this.status = '正在上传主页背景…';
      await this.retryCloudBusy('背景上传', (): Promise<void> =>
        PhotoUploadService.upload(context, upload.bucketName, upload.cloudPath, cover.data, cover.sha256));
      this.coverUploadCompleted = true;
    }
    return upload.mediaId;
  }

  // 恢复默认背景。
  private clearCover(): void {
    if (this.saving || this.preparingCover) return;
    this.preparedCover = undefined;
    this.clearCoverUpload();
    this.clearCoverRequested = true;
    this.coverPreviewUri = '';
    this.status = '将恢复食刻默认背景，保存后生效。';
  }

  // 是否为数据库繁忙错误（3007009）。
  private isCloudBusyError(error: ErrorDetail): boolean {
    const message = errorText(error).toLowerCase();
    return message.includes('3007009') || message.includes('too many requests') || message.includes('too busy');
  }

  // 等待一段时间后重试。
  private waitForCloudRetry(delayMs: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout((): void => resolve(), delayMs);
    });
  }

  // 遇到数据库繁忙时自动重试几次。
  private async retryCloudBusy<T>(operationName: string, operation: () => Promise<T>): Promise<T> {
    for (let attempt = 1; attempt <= CLOUD_BUSY_MAX_ATTEMPTS; attempt++) {
      try {
        return await operation();
      } catch (error) {
        const detail = error as ErrorDetail;
        if (!this.isCloudBusyError(detail) || attempt === CLOUD_BUSY_MAX_ATTEMPTS) {
          throw new Error(errorText(detail));
        }
        const delayMs = CLOUD_BUSY_RETRY_BASE_DELAY_MS * attempt;
        this.status = `${operationName}服务繁忙，正在重试（${attempt}/${CLOUD_BUSY_MAX_ATTEMPTS - 1}）…`;
        await this.waitForCloudRetry(delayMs);
      }
    }
    throw new Error(`${operationName}未完成，请稍后重试。`);
  }

  // 上传已处理的头像，返回 mediaId。
  private async uploadPreparedAvatar(context: common.UIAbilityContext): Promise<string> {
    const avatar: PreparedPhoto | undefined = this.preparedAvatar;
    if (avatar === undefined) return '';
    if (this.avatarUpload === undefined) {
      const photoRequest: PrepareCardPhotoRequest = {
        mimeType: avatar.mimeType,
        byteSize: avatar.byteSize,
        sha256: avatar.sha256,
        width: avatar.width,
        height: avatar.height
      };
      this.status = '正在准备新头像…';
      this.avatarUpload = await this.retryCloudBusy('头像准备', (): Promise<PrepareCardPhotoResponse> =>
        this.repository.preparePhoto(context, photoRequest));
    }
    const upload: PrepareCardPhotoResponse | undefined = this.avatarUpload;
    if (upload === undefined) throw new Error('头像上传准备记录缺失，请重新选择图片。');
    if (!this.avatarUploadCompleted) {
      this.status = '正在上传新头像…';
      await this.retryCloudBusy('头像上传', (): Promise<void> =>
        PhotoUploadService.upload(context, upload.bucketName, upload.cloudPath, avatar.data, avatar.sha256));
      this.avatarUploadCompleted = true;
    }
    return upload.mediaId;
  }

  // 两个触点之间的距离（用于双指缩放）。
  private cropTouchDistance(first: TouchObject, second: TouchObject): number {
    const deltaX = second.x - first.x;
    const deltaY = second.y - first.y;
    return Math.sqrt(deltaX * deltaX + deltaY * deltaY);
  }

  // 重置触摸状态。
  private resetCropTouch(): void {
    this.activeCropTouchId = -1;
    this.cropTouchStartDistance = 0;
  }

  /**
   * 处理裁剪框上的触摸：裁剪框保持不动，原图在下面移动（单指拖动、双指缩放），与常见的头像裁剪交互一致。
   */
  private handleCropTouch(viewport: number, event: TouchEvent): void {
    if (!this.cropEditing || this.saving || this.preparingAvatar) return;
    event.stopPropagation();

    if (event.type === TouchType.Down) {
      if (event.touches.length === 1) {
        const touch: TouchObject = event.touches[0];
        this.activeCropTouchId = touch.id;
        this.cropTouchStartX = touch.x;
        this.cropTouchStartY = touch.y;
        this.cropTouchStartOffsetX = this.cropOffsetX;
        this.cropTouchStartOffsetY = this.cropOffsetY;
        this.cropTouchStartDistance = 0;
      } else if (event.touches.length >= 2) {
        const first: TouchObject = event.touches[0];
        const second: TouchObject = event.touches[1];
        this.cropTouchStartDistance = this.cropTouchDistance(first, second);
        this.cropTouchStartScale = this.cropScale;
      }
      return;
    }

    if (event.type === TouchType.Move) {
      if (event.touches.length >= 2) {
        const first: TouchObject = event.touches[0];
        const second: TouchObject = event.touches[1];
        const distance = this.cropTouchDistance(first, second);
        if (distance > 0) {
          if (this.cropTouchStartDistance <= 0) {
            this.cropTouchStartDistance = distance;
            this.cropTouchStartScale = this.cropScale;
          }
          this.cropScale = this.bounded(
            this.cropTouchStartScale * distance / this.cropTouchStartDistance,
            1,
            3
          );
        }
        return;
      }

      if (event.touches.length === 1 && this.activeCropTouchId >= 0) {
        const touch: TouchObject = event.touches[0];
        if (touch.id !== this.activeCropTouchId) return;
        const panX = this.previewPanX(viewport);
        const panY = this.previewPanY(viewport);
        if (panX > 0) {
          this.cropOffsetX = this.bounded(
            this.cropTouchStartOffsetX - (touch.x - this.cropTouchStartX) / panX,
            -1,
            1
          );
        }
        if (panY > 0) {
          this.cropOffsetY = this.bounded(
            this.cropTouchStartOffsetY - (touch.y - this.cropTouchStartY) / panY,
            -1,
            1
          );
        }
      }
      return;
    }

    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.resetCropTouch();
    }
  }

  // 重置裁剪位置。
  private resetCropPosition(): void {
    this.cropScale = 1;
    this.cropOffsetX = 0;
    this.cropOffsetY = 0;
    this.status = '已重置取景位置。';
  }

  // 预览中图片的宽度。
  private previewImageWidth(viewport: number): number {
    if (this.cropImageWidth <= 0 || this.cropImageHeight <= 0) return viewport;
    const baseWidth = this.cropImageWidth >= this.cropImageHeight
      ? viewport * this.cropImageWidth / this.cropImageHeight : viewport;
    return baseWidth * this.cropScale;
  }

  // 预览中图片的高度。
  private previewImageHeight(viewport: number): number {
    if (this.cropImageWidth <= 0 || this.cropImageHeight <= 0) return viewport;
    const baseHeight = this.cropImageHeight >= this.cropImageWidth
      ? viewport * this.cropImageHeight / this.cropImageWidth : viewport;
    return baseHeight * this.cropScale;
  }

  // 预览中图片的水平偏移。
  private previewPanX(viewport: number): number {
    return Math.max(0, (this.previewImageWidth(viewport) - viewport) / 2);
  }

  // 预览中图片的垂直偏移。
  private previewPanY(viewport: number): number {
    return Math.max(0, (this.previewImageHeight(viewport) - viewport) / 2);
  }

  // 清除裁剪状态。
  private clearCrop(): void {
    this.resetCropTouch();
    this.cropSourceUri = '';
    this.cropImageWidth = 0;
    this.cropImageHeight = 0;
    this.cropScale = 1;
    this.cropOffsetX = 0;
    this.cropOffsetY = 0;
    this.cropEditing = false;
  }

  // 选择头像图片并进入裁剪。
  private async chooseAvatar(): Promise<void> {
    if (this.saving || this.preparingAvatar || this.preparingCover) return;
    try {
      const uri = await ImagePreparationService.selectOne();
      if (uri.length === 0) return;
      const dimensions: ImageDimensions = await ImagePreparationService.readImageDimensions(uri);
      this.preparedAvatar = undefined;
      this.clearAvatarUpload();
      this.cropSourceUri = uri;
      this.cropImageWidth = dimensions.width;
      this.cropImageHeight = dimensions.height;
      this.cropScale = 1;
      this.cropOffsetX = 0;
      this.cropOffsetY = 0;
      this.resetCropTouch();
      this.cropEditing = true;
      this.status = '请在取景框内调整头像；单指拖动图片、双指捏合缩放，确认后才会在本机生成头像。';
    } catch (error) {
      this.preparedAvatar = undefined;
      this.clearAvatarUpload();
      this.clearCrop();
      this.status = `头像处理失败：${errorText(error as ErrorDetail)}`;
    }
  }

  // 应用裁剪：在本机生成头像 JPEG。
  private async applyAvatarCrop(): Promise<void> {
    if (this.cropSourceUri.length === 0 || this.saving || this.preparingAvatar || this.preparingCover) return;
    this.preparingAvatar = true;
    try {
      this.clearAvatarUpload();
      this.status = '正在本机生成圆形头像…';
      const prepared: PreparedPhoto = await ImagePreparationService.prepareAvatarPhoto(
        this.cropSourceUri, this.cropSpec());
      this.preparedAvatar = prepared;
      this.avatarPreviewUri = this.cropSourceUri;
      this.cropEditing = false;
      this.status = '头像取景已选定，已本机重编码并移除 EXIF/GPS；保存后才会上传。';
    } catch (error) {
      this.preparedAvatar = undefined;
      this.status = `头像处理失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.preparingAvatar = false;
    }
  }

  // 取消裁剪。
  private cancelAvatarCrop(): void {
    if (this.preparingAvatar) return;
    this.preparedAvatar = undefined;
    this.clearAvatarUpload();
    this.clearCrop();
    this.status = '已取消这次头像选择。';
  }

  // 保存资料：先上传头像/背景（如有），再调用 upsert-profile。
  private async save(): Promise<void> {
    if (this.cropEditing) {
      this.status = '请先确认或取消头像取景，再保存资料。';
      return;
    }
    if (this.saving || this.preparingAvatar || this.preparingCover) return;
    const normalizedNickname = this.nickname.trim();
    if (normalizedNickname.length < 2 || normalizedNickname.length > 24) {
      this.status = '昵称需为 2–24 个字符。';
      return;
    }
    this.saving = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let avatarMediaId = '';
      if (this.preparedAvatar !== undefined) {
        avatarMediaId = await this.uploadPreparedAvatar(context);
      }
      let coverMediaId = '';
      if (this.preparedCover !== undefined) {
        coverMediaId = await this.uploadPreparedCover(context);
      }
      this.status = '正在保存资料…';
      const request: UpdateProfileRequest = {
        nickname: normalizedNickname,
        avatarMediaId,
        coverMediaId,
        clearCover: this.clearCoverRequested
      };
      const updated = await this.retryCloudBusy('资料保存', (): Promise<UserProfile> =>
        AuthService.updateProfile(context, request));
      this.profile = updated;
      this.nickname = updated.nickname;
      this.avatarPreviewUri = updated.avatarUrl;
      this.coverPreviewUri = updated.coverUrl || '';
      this.preparedAvatar = undefined;
      this.preparedCover = undefined;
      this.clearCoverRequested = false;
      this.clearAvatarUpload();
      this.clearCoverUpload();
      this.clearCrop();
      this.status = '资料已保存。';
      this.onProfileChanged(updated);
    } catch (error) {
      const detail = error as ErrorDetail;
      this.status = this.isCloudBusyError(detail)
        ? '云端服务暂时繁忙，已保留本次头像选择，请稍后再次保存。'
        : `保存失败：${errorText(detail)}`;
    } finally {
      this.saving = false;
    }
  }

  // 裁剪预览。
  @Builder
  private avatarCropPreview(viewport: number, description: string) {
    Stack({ alignContent: Alignment.Center }) {
      Image(this.cropSourceUri)
        .width(this.previewImageWidth(viewport)).height(this.previewImageHeight(viewport))
        .objectFit(ImageFit.Fill)
        .translate({
          x: -this.cropOffsetX * this.previewPanX(viewport),
          y: -this.cropOffsetY * this.previewPanY(viewport)
        })
        .accessibilityLevel('no')
      Column().width(viewport).height(viewport)
        .border({ width: 2, color: $r('app.color.personal_surface') }).borderRadius(viewport / 2)
        .accessibilityLevel('no')
    }
    .width(viewport).height(viewport).clip(true).backgroundColor($r('app.color.personal_canvas'))
    .borderRadius(viewport / 2)
    .onTouch((event: TouchEvent): void => this.handleCropTouch(viewport, event))
    .hitTestBehavior(this.cropEditing ? HitTestMode.Block : HitTestMode.Default)
    .accessibilityText(description);
  }

  // 裁剪编辑器。
  @Builder
  private cropEditor() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 4 }) {
          Text('选定头像区域').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.personal_ink'))
            .width('100%')
          Text('在固定取景框内拖动或缩放图片，框内内容会成为最终头像。')
            .fontSize(12).fontColor($r('app.color.personal_muted')).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text('第 2 步').fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.leaf'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 }).backgroundColor($r('app.color.personal_soft')).borderRadius(10)
      }.width('100%')

      Row() {
        this.avatarCropPreview(AVATAR_CROP_VIEWPORT, '头像圆形取景预览')
      }.width('100%').justifyContent(FlexAlign.Center)

      Text(`当前取景框：圆形；缩放 ${this.cropScale.toFixed(1)}×`)
        .fontSize(13).fontColor($r('app.color.personal_muted')).width('100%').textAlign(TextAlign.Center)

      Button('重置取景位置').height(44).width('100%')
        .backgroundColor($r('app.color.personal_canvas')).fontColor($r('app.color.personal_action'))
        .border({ width: 1, color: $r('app.color.personal_line') })
        .onClick(() => this.resetCropPosition())

      Row({ space: 10 }) {
        Button('取消').height(44).layoutWeight(1).enabled(!this.preparingAvatar)
          .backgroundColor($r('app.color.personal_surface')).fontColor($r('app.color.personal_ink'))
          .border({ width: 1, color: $r('app.color.personal_line') }).onClick(() => this.cancelAvatarCrop())
        Button(this.preparingAvatar ? '正在处理…' : '使用此头像').height(44).layoutWeight(1)
          .enabled(!this.preparingAvatar).backgroundColor($r('app.color.personal_action'))
          .fontColor($r('app.color.personal_surface')).onClick(() => this.applyAvatarCrop())
      }.width('100%')
    }
    .width('100%').padding(16).backgroundColor($r('app.color.personal_surface')).borderRadius(20)
    .border({ width: 1, color: $r('app.color.personal_line') }).alignItems(HorizontalAlign.Start)
  }

  // 页面布局。
  build() {
    NavDestination() {
      Column() {
        List({ space: 18 }) {
          ListItem() {
            if (this.cropEditing) {
              this.cropEditor()
            } else {
              Column({ space: 14 }) {
                Text('头像').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.personal_ink')).width('100%')
                Row({ space: 16 }) {
                  if (this.preparedAvatar !== undefined && this.cropSourceUri.length > 0) {
                    this.avatarCropPreview(76, '待保存的用户头像')
                  } else if (this.avatarPreviewUri.length > 0) {
                    Image(this.avatarPreviewUri).width(76).height(76).borderRadius(38).objectFit(ImageFit.Cover)
                      .accessibilityText('当前用户头像')
                  } else {
                    Image($r('app.media.app_icon')).width(76).height(76).borderRadius(22)
                      .accessibilityText('食刻默认头像')
                  }
                  Column({ space: 6 }) {
                    Button('更换头像').height(44).fontSize(14)
                      .enabled(!this.saving && !this.preparingAvatar && !this.preparingCover)
                      .backgroundColor($r('app.color.personal_soft')).fontColor($r('app.color.personal_action'))
                      .onClick(() => this.chooseAvatar())
                    Text('选择后可在取景框中拖动或缩放；保存前不会上传。')
                      .fontSize(12).lineHeight(18).fontColor($r('app.color.personal_muted')).width('100%')
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                }.width('100%')
              }
              .width('100%').padding(16).backgroundColor($r('app.color.personal_surface')).borderRadius(20)
              .border({ width: 1.2, color: $r('app.color.personal_line'), style: BorderStyle.Dashed }).alignItems(HorizontalAlign.Start)
            }
          }

          ListItem() {
            Column({ space: 12 }) {
              Text('主页背景').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.personal_ink')).width('100%')
              Stack({ alignContent: Alignment.Center }) {
                if (this.coverPreviewUri.length > 0) {
                  Image(this.coverPreviewUri).width('100%').height(132).objectFit(ImageFit.Cover)
                    .borderRadius(16).accessibilityText('主页背景预览');
                } else {
                  Column({ space: 6 }) {
                    Text('食刻好友主页').fontSize(20).fontWeight(FontWeight.Bold)
                      .fontColor($r('app.color.personal_action'));
                    Text('把喜欢的味道分享给朋友').fontSize(13).fontColor($r('app.color.leaf'));
                  }
                  .width('100%').height(132).justifyContent(FlexAlign.Center)
                  .backgroundColor($r('app.color.personal_soft')).borderRadius(16);
                }
              }.width('100%').height(132);
              Row({ space: 8 }) {
                Button(this.preparingCover ? '正在处理…' : '更换背景').height(44).layoutWeight(1)
                  .enabled(!this.saving && !this.preparingCover && !this.preparingAvatar)
                  .backgroundColor($r('app.color.personal_soft')).fontColor($r('app.color.personal_action'))
                  .onClick((): void => {
                    this.chooseCover();
                  });
                Button('恢复默认').height(44).layoutWeight(1)
                  .enabled(!this.saving && !this.preparingCover &&
                    (this.coverPreviewUri.length > 0 || (this.profile?.coverPath || '').length > 0))
                  .backgroundColor($r('app.color.personal_surface')).fontColor($r('app.color.personal_ink'))
                  .border({ width: 1, color: $r('app.color.personal_line') }).onClick((): void => {
                    this.clearCover();
                  });
              }.width('100%');
              Text('背景图片会显示在你的好友主页；选择后先在本机移除图片位置等元数据，保存时再上传。')
                .fontSize(12).lineHeight(18).fontColor($r('app.color.personal_muted')).width('100%');
            }
            .width('100%').padding(16).backgroundColor($r('app.color.personal_surface')).borderRadius(20)
            .border({ width: 1.2, color: $r('app.color.personal_line'), style: BorderStyle.Dashed }).alignItems(HorizontalAlign.Start)
          }

          ListItem() {
            Column({ space: 10 }) {
              Text('昵称').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.personal_ink')).width('100%')
              TextInput({ text: this.nickname, placeholder: '请输入昵称' })
                .width('100%').height(48).fontSize(16).backgroundColor($r('app.color.personal_canvas'))
                .fontColor($r('app.color.personal_ink')).placeholderColor($r('app.color.personal_muted'))
                .border({ width: 1, color: $r('app.color.personal_line') }).borderRadius(14)
                .padding({ left: 14, right: 14 })
                .onChange((value: string) => this.nickname = value)
              Text('昵称也是登录名，需唯一；修改后请使用新昵称登录。')
                .fontSize(12).lineHeight(18).fontColor($r('app.color.personal_muted')).width('100%')
            }
            .width('100%').padding(16).backgroundColor($r('app.color.personal_surface')).borderRadius(20)
            .border({ width: 1.2, color: $r('app.color.personal_line'), style: BorderStyle.Dashed }).alignItems(HorizontalAlign.Start)
          }

          if (this.status.length > 0) {
            ListItem() {
              Text(this.status).fontSize(13).lineHeight(20).width('100%')
                .fontColor(this.status.includes('失败') ? $r('app.color.warning') : $r('app.color.personal_muted'))
                .padding(12).backgroundColor($r('app.color.personal_soft')).borderRadius(14)
            }
          }
        }
        .width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
        .padding({ left: 20, right: 20, top: 12, bottom: 16 })
        // 保存按钮固定在底部，不随表单滚动。
        Column() {
          Button(this.cropEditing ? '请先确认头像取景' : (this.saving ? '正在保存…' : '保存资料'))
            .enabled(!this.saving && !this.cropEditing && !this.preparingAvatar && !this.preparingCover)
            .width('100%').height(48).borderRadius(24)
            .backgroundColor($r('app.color.personal_action')).fontColor($r('app.color.personal_surface'))
            .onClick(() => this.save())
        }
        .width('100%').padding({ left: 20, right: 20, top: 10, bottom: 10 })
        .backgroundColor($r('app.color.personal_surface'))
        .border({ width: { top: 1.2 }, color: $r('app.color.personal_line'), style: BorderStyle.Dashed })
      }.width('100%').height('100%').backgroundColor($r('app.color.personal_canvas'))
    }.attributeModifier(new AppDestinationStyle('编辑资料', $r('app.color.personal_canvas'), $r('app.color.personal_header'), 'PERSONAL'))
  }
}
