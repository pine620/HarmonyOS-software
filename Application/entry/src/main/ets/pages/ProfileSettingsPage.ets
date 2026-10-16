import { AppDestinationStyle } from '../common/AppPageUi';
import { common } from '@kit.AbilityKit';
import { UserProfile } from '../model/CloudContracts';
import { CardVisitStore } from '../service/CardVisitStore';
import { AuthService, PasswordSavedError } from '../service/AuthService';
import { AuthSessionStore } from '../service/AuthSessionStore';
import { CloudBusinessError } from '../service/CloudReadErrors';
import { ErrorDetail, errorText } from '../common/ErrorKit';
import { ModeFieldCache } from '../service/ModeFieldCache';
import { CardReportRepository } from '../repository/CardReportRepository';
import { CardReportAccess } from '../model/CardReportModels';

// Pack 4.3 (2026-10-15): split out of ProfileSubPages.ets without behaviour changes.

@Component
export struct ProfileSettingsPage {
  @Consume('pathStack') pathStack: NavPathStack;
  onSessionEnded: (message: string) => void = (_message: string): void => {};
  onProfileChanged: (profile: UserProfile) => void = (_profile: UserProfile): void => {};
  @State profile: UserProfile | undefined = undefined;
  @State status: string = '';
  @State busy: boolean = false;
  @State passwordChangeVisible: boolean = false;
  @State passwordSaving: boolean = false;
  @State currentPassword: string = '';
  @State newPassword: string = '';
  @State confirmPassword: string = '';
  @State currentPasswordError: string = '';
  @State newPasswordError: string = '';
  @State confirmPasswordError: string = '';
  @State passwordMessage: string = '';
  @State passwordFailed: boolean = false;
  private active: boolean = false;
  @State deleteConfirmationVisible: boolean = false;
  @State deleteEmailAddress: string = '';
  @State deleteVerifyCode: string = '';
  @State deleteCodeBusy: boolean = false;
  @State deleteCodeCountdown: number = 0;
  @State emailBindingVisible: boolean = false;
  @State emailBindingAddress: string = '';
  @State emailBindingVerifyCode: string = '';
  @State emailBindingCodeBusy: boolean = false;
  @State emailBindingCodeCountdown: number = 0;
  // Only accounts on the server reviewer allowlist see the review entry; the server still checks every call.
  @State reviewerAllowed: boolean = false;
  private reviewAccessGeneration: number = 0;
  private deleteCodeTimer: number | undefined = undefined;
  private emailBindingCodeTimer: number | undefined = undefined;

  aboutToAppear(): void {
    this.active = true;
    this.profile = AuthService.profile();
    void this.loadReviewerAccess();
  }

  private async loadReviewerAccess(): Promise<void> {
    const generation: number = ++this.reviewAccessGeneration;
    this.reviewerAllowed = false;
    if (this.profile === undefined) return;
    try {
      const access: CardReportAccess = await new CardReportRepository().access();
      if (this.active && generation === this.reviewAccessGeneration) this.reviewerAllowed = access.allowed === true;
    } catch (_error) {
      // Treat any failure as "not a reviewer"; the entry stays hidden.
    }
  }

  aboutToDisappear(): void {
    this.active = false;
    this.reviewAccessGeneration++;
    if (this.deleteCodeTimer !== undefined) {
      clearTimeout(this.deleteCodeTimer);
      this.deleteCodeTimer = undefined;
    }
    if (this.emailBindingCodeTimer !== undefined) {
      clearTimeout(this.emailBindingCodeTimer);
      this.emailBindingCodeTimer = undefined;
    }
  }

  private clearPasswordInputs(): void {
    this.currentPassword = ''; this.newPassword = ''; this.confirmPassword = '';
    this.currentPasswordError = ''; this.newPasswordError = ''; this.confirmPasswordError = '';
  }

  private showPasswordChange(): void {
    if (this.busy || this.profile === undefined) return;
    this.clearPasswordInputs(); this.passwordMessage = ''; this.passwordFailed = false;
    this.emailBindingVisible = false; this.deleteConfirmationVisible = false;
    this.passwordChangeVisible = true;
  }

  private cancelPasswordChange(): void {
    if (this.busy) return;
    this.clearPasswordInputs(); this.passwordChangeVisible = false;
    this.passwordMessage = ''; this.passwordFailed = false;
  }

  private validatePasswordChange(): boolean {
    this.currentPasswordError = ''; this.newPasswordError = ''; this.confirmPasswordError = '';
    if (this.currentPassword.length === 0) this.currentPasswordError = '请输入当前密码';
    try { AuthSessionStore.validateNewPassword(this.newPassword); }
    catch (error) { this.newPasswordError = error instanceof Error ? error.message : '请输入有效的新密码'; }
    if (this.newPasswordError.length === 0 && this.newPassword === this.currentPassword) {
      this.newPasswordError = '新密码不能与当前密码相同';
    }
    if (this.confirmPassword.length === 0) this.confirmPasswordError = '请再次输入新密码';
    else if (this.confirmPassword !== this.newPassword) this.confirmPasswordError = '两次新密码不一致';
    return this.currentPasswordError.length === 0 && this.newPasswordError.length === 0 && this.confirmPasswordError.length === 0;
  }

  private async savePassword(): Promise<void> {
    if (this.busy || !this.validatePasswordChange()) return;
    this.busy = true; this.passwordSaving = true; this.passwordMessage = ''; this.passwordFailed = false;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const updated: UserProfile = await AuthService.changePassword(context, this.currentPassword, this.newPassword);
      if (!this.active) return;
      this.profile = updated; this.clearPasswordInputs(); this.passwordChangeVisible = false;
      this.passwordMessage = '密码已更改。'; this.onProfileChanged(updated);
    } catch (error) {
      if (!this.active) return;
      const message: string = AuthService.credentialError(error as Object, '更改密码未完成，请重试。');
      if (error instanceof PasswordSavedError || AuthService.profile() === undefined) {
        this.clearPasswordInputs(); this.passwordChangeVisible = false;
        this.onSessionEnded(message);
      } else {
        const code: string = error instanceof CloudBusinessError ? error.code : '';
        if (code === 'CURRENT_PASSWORD_INCORRECT') {
          this.currentPassword = ''; this.currentPasswordError = '当前密码不正确';
        }
        if (code === 'INVALID_PASSWORD') this.newPasswordError = message;
        this.passwordFailed = true; this.passwordMessage = message;
      }
    } finally {
      if (this.active) { this.busy = false; this.passwordSaving = false; }
    }
  }

  @Builder
  private passwordFieldError(message: string): void {
    if (message.length > 0) {
      Text(message).fontSize(13).fontColor($r('app.color.danger')).width('100%').accessibilityText(message)
    }
  }

  @Builder
  private passwordChangeForm(): void {
    Column({ space: 10 }) {
      Text('当前密码').fontSize(14).fontColor($r('app.color.personal_muted')).width('100%')
      TextInput({ text: this.currentPassword, placeholder: '输入当前密码' })
        .type(InputType.Password).showPasswordIcon(true).maxLength(128).enterKeyType(EnterKeyType.Next)
        .height(52).width('100%').fontSize(16).fontColor($r('app.color.personal_ink')).backgroundColor($r('app.color.personal_canvas'))
        .border({ width: 1, color: $r('app.color.personal_line') }).borderRadius(14).enabled(!this.busy).accessibilityText('当前密码')
        .onChange((value: string): void => { this.currentPassword = value; this.currentPasswordError = ''; this.passwordMessage = ''; })
      this.passwordFieldError(this.currentPasswordError)
      Text('新密码').fontSize(14).fontColor($r('app.color.personal_muted')).width('100%').margin({ top: 6 })
      TextInput({ text: this.newPassword, placeholder: '至少 8 位，含两种字符' })
        .type(InputType.Password).showPasswordIcon(true).maxLength(128).enterKeyType(EnterKeyType.Next)
        .height(52).width('100%').fontSize(16).fontColor($r('app.color.personal_ink')).backgroundColor($r('app.color.personal_canvas'))
        .border({ width: 1, color: $r('app.color.personal_line') }).borderRadius(14).enabled(!this.busy).accessibilityText('新密码')
        .onChange((value: string): void => { this.newPassword = value; this.newPasswordError = ''; this.confirmPasswordError = ''; this.passwordMessage = ''; })
      this.passwordFieldError(this.newPasswordError)
      Text('确认新密码').fontSize(14).fontColor($r('app.color.personal_muted')).width('100%').margin({ top: 6 })
      TextInput({ text: this.confirmPassword, placeholder: '再次输入新密码' })
        .type(InputType.Password).showPasswordIcon(true).maxLength(128).enterKeyType(EnterKeyType.Done)
        .height(52).width('100%').fontSize(16).fontColor($r('app.color.personal_ink')).backgroundColor($r('app.color.personal_canvas'))
        .border({ width: 1, color: $r('app.color.personal_line') }).borderRadius(14).enabled(!this.busy).accessibilityText('确认新密码')
        .onChange((value: string): void => { this.confirmPassword = value; this.confirmPasswordError = ''; this.passwordMessage = ''; })
        .onSubmit((): void => { void this.savePassword(); })
      this.passwordFieldError(this.confirmPasswordError)
      Text('忘记当前密码时，可从登录页通过绑定的邮箱或华为账号找回。')
        .fontSize(13).lineHeight(20).fontColor($r('app.color.personal_muted')).width('100%')
      Button(this.passwordSaving ? '保存中…' : '确认更改').width('100%').height(48)
        .backgroundColor($r('app.color.personal_action')).fontColor($r('app.color.personal_surface')).enabled(!this.busy)
        .onClick((): void => { void this.savePassword(); })
      Button('取消').width('100%').height(48).backgroundColor(Color.Transparent).fontColor($r('app.color.personal_muted'))
        .enabled(!this.busy).onClick((): void => this.cancelPasswordChange())
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  private async logout(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await AuthService.logout(context);
      this.onSessionEnded('已退出食刻，认证会话和本机状态已清理。');
    } catch (error) {
      if (AuthService.profile() === undefined) {
        this.onSessionEnded(`本地食刻会话已清除，但云端退出未完成：${errorText(error as ErrorDetail)}`);
      } else {
        this.status = `退出未完成：${errorText(error as ErrorDetail)} 请保持登录并重试，以便先移除通知设备。`;
      }
    } finally {
      this.busy = false;
    }
  }

  private async switchUser(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await AuthService.logout(context);
      this.onSessionEnded('食刻会话已清除，可使用其他邮箱或华为账号重新登录。');
    } catch (_error) {
      if (AuthService.profile() === undefined) {
        this.onSessionEnded('食刻会话已清除，可使用其他邮箱或华为账号重新登录。');
      } else {
        this.status = '切换用户未完成：请保持当前账号登录并重试，以便先移除通知设备。';
      }
    } finally {
      this.busy = false;
    }
  }

  private showEmailBinding(): void {
    if (this.busy) return;
    this.emailBindingAddress = '';
    this.emailBindingVerifyCode = '';
    this.emailBindingCodeCountdown = 0;
    this.emailBindingVisible = true;
    this.status = '';
  }

  private startEmailBindingCodeCountdown(): void {
    if (this.emailBindingCodeTimer !== undefined) {
      clearTimeout(this.emailBindingCodeTimer);
    }
    this.emailBindingCodeTimer = setTimeout((): void => {
      if (this.emailBindingCodeCountdown <= 1) {
        this.emailBindingCodeCountdown = 0;
        this.emailBindingCodeTimer = undefined;
      } else {
        this.emailBindingCodeCountdown -= 1;
        this.startEmailBindingCodeCountdown();
      }
    }, 1000);
  }

  private async requestEmailBindingCode(): Promise<void> {
    if (this.busy || this.emailBindingCodeBusy || this.emailBindingCodeCountdown > 0) return;
    this.emailBindingCodeBusy = true;
    this.status = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await AuthService.requestEmailCode(context, this.emailBindingAddress);
      this.emailBindingCodeCountdown = 60;
      this.startEmailBindingCodeCountdown();
      this.status = '邮箱验证码已发送；验证后会关联到当前食刻账号。';
    } catch (error) {
      this.status = `验证码发送失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.emailBindingCodeBusy = false;
    }
  }

  private async completeEmailBinding(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.status = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.profile = await AuthService.linkEmailToHuawei(
        context, this.emailBindingAddress, this.emailBindingVerifyCode);
      this.emailBindingVisible = false;
      this.status = '邮箱已关联到当前食刻账号。退出后使用邮箱验证码登录，仍会进入同一账号。';
    } catch (error) {
      this.status = `邮箱关联未完成：${errorText(error as ErrorDetail)}`;
    } finally {
      this.busy = false;
    }
  }

  private async linkHuaweiAccount(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.status = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.profile = await AuthService.linkHuaweiToEmail(context);
      this.status = '华为账号已关联到当前食刻账号。之后可使用任一方式登录。';
    } catch (error) {
      this.status = `华为账号关联未完成：${errorText(error as ErrorDetail)}`;
    } finally {
      this.busy = false;
    }
  }

  private async deleteAccount(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const deletedUid: string = AuthService.profile()?.uid || '';
      const message: string = await AuthService.deleteAccount(
        context, this.deleteEmailAddress, this.deleteVerifyCode);
      if (deletedUid.length > 0) {
        try {
          CardVisitStore.clear(context, deletedUid);
        } catch (_error) {
          // Account deletion has already succeeded; local history cleanup is best effort.
        }
        try { ModeFieldCache.clearAccount(context, deletedUid); } catch (_error) { }
      }
      this.deleteConfirmationVisible = false;
      this.onSessionEnded(message);
    } catch (error) {
      this.status = `账号注销未完成：${errorText(error as ErrorDetail)}`;
    } finally {
      this.busy = false;
    }
  }

  private startDeleteCodeCountdown(): void {
    if (this.deleteCodeTimer !== undefined) {
      clearTimeout(this.deleteCodeTimer);
    }
    this.deleteCodeTimer = setTimeout((): void => {
      if (this.deleteCodeCountdown <= 1) {
        this.deleteCodeCountdown = 0;
        this.deleteCodeTimer = undefined;
      } else {
        this.deleteCodeCountdown -= 1;
        this.startDeleteCodeCountdown();
      }
    }, 1000);
  }

  private async requestDeleteCode(): Promise<void> {
    if (this.busy || this.deleteCodeBusy || this.deleteCodeCountdown > 0) return;
    this.deleteCodeBusy = true;
    this.status = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await AuthService.requestEmailCode(context, this.deleteEmailAddress);
      this.deleteCodeCountdown = 60;
      this.startDeleteCodeCountdown();
      this.status = '注销邮箱验证码已发送，请在有效期内完成最近一次认证。';
    } catch (error) {
      this.status = `验证码发送失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.deleteCodeBusy = false;
    }
  }

  // ---- Pack 2: grouped settings list (forms still expand in place) ----

  private rowBorder(first: boolean, danger: boolean): BorderOptions {
    if (first) {
      const none: BorderOptions = { width: 0 };
      return none;
    }
    const dashed: BorderOptions = { width: { top: 1.2 }, color: danger ? $r('app.color.danger_soft') : $r('app.color.personal_line'),
      style: BorderStyle.Dashed };
    return dashed;
  }

  @Builder
  private settingsRow(icon: Resource, label: string, hint: string, first: boolean, danger: boolean, expanded: boolean,
    onTap: () => void) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: 12 }) {
        Stack() {
          SymbolGlyph(icon).fontSize(17)
            .fontColor([danger ? $r('app.color.danger') : $r('app.color.personal_action')]).accessibilityLevel('no')
        }
        .width(30).height(30).borderRadius(10)
        .backgroundColor(danger ? $r('app.color.danger_soft') : $r('app.color.personal_soft'))
        Column({ space: 2 }) {
          Text(label).fontSize(15).fontColor(danger ? $r('app.color.danger') : $r('app.color.personal_ink')).width('100%')
          if (hint.length > 0) {
            Text(hint).fontSize(11.5).fontColor($r('app.color.personal_muted')).width('100%').maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Image($r('app.media.ic_me_chevron')).width(16).height(16).rotate({ angle: expanded ? 90 : 0 })
          .accessibilityLevel('no')
      }.width('100%').alignItems(VerticalAlign.Center)
    }
    .width('100%').constraintSize({ minHeight: 56 }).padding({ top: 10, bottom: 10 })
    .backgroundColor(Color.Transparent).borderRadius(0).border(this.rowBorder(first, danger))
    .enabled(!this.busy).accessibilityText(hint.length > 0 ? `${label}，${hint}` : label).onClick(onTap)
  }

  @Builder
  private groupTitle(title: string) {
    Text(title).fontSize(12.5).fontColor($r('app.color.personal_muted')).width('100%').padding({ left: 4 })
  }

  @Builder
  private emailBindingForm() {
    Column({ space: 10 }) {
      Text('验证邮箱后会直接关联到当前 AGC 用户；不会新建另一份食刻账号。')
        .fontSize(12.5).lineHeight(19).fontColor($r('app.color.personal_muted')).width('100%')
      TextInput({ text: this.emailBindingAddress, placeholder: 'name@example.com' })
        .width('100%').height(48).backgroundColor($r('app.color.personal_canvas')).borderRadius(14)
        .accessibilityText('要关联的邮箱地址')
        .onChange((value: string): void => {
          this.emailBindingAddress = value;
        })
      Row({ space: 10 }) {
        TextInput({ text: this.emailBindingVerifyCode, placeholder: '邮箱验证码' })
          .layoutWeight(1).height(48).backgroundColor($r('app.color.personal_canvas')).borderRadius(14)
          .accessibilityText('关联邮箱验证码')
          .onChange((value: string): void => {
            this.emailBindingVerifyCode = value;
          })
        Button(this.emailBindingCodeCountdown > 0 ? `${this.emailBindingCodeCountdown} 秒后重发` :
          (this.emailBindingCodeBusy ? '发送中…' : '获取验证码'))
          .enabled(!this.busy && !this.emailBindingCodeBusy && this.emailBindingCodeCountdown === 0)
          .height(46).fontSize(13).backgroundColor(Color.Transparent)
          .fontColor($r('app.color.personal_action'))
          .border({ width: 1.2, color: $r('app.color.personal_action'), style: BorderStyle.Dashed })
          .onClick(() => this.requestEmailBindingCode())
      }.width('100%')
      Button(this.busy ? '正在关联…' : '确认关联邮箱').enabled(!this.busy && !this.emailBindingCodeBusy)
        .width('100%').height(46).backgroundColor($r('app.color.personal_action'))
        .fontColor($r('app.color.personal_surface')).onClick(() => this.completeEmailBinding())
      Button('收起').width('100%').height(40).backgroundColor(Color.Transparent).fontColor($r('app.color.personal_muted'))
        .enabled(!this.busy).onClick((): void => { this.emailBindingVisible = false; })
    }.width('100%').padding({ bottom: 12 })
  }

  @Builder
  private deleteConfirmation() {
    Column({ space: 10 }) {
      Text('请再次确认：你将永久失去当前食刻账号及其相关数据。注销后账号立即停用、内容不可访问；相关数据和认证身份按后台清理流程处理。')
        .fontSize(13).lineHeight(20).fontColor($r('app.color.danger')).width('100%')
        .padding(12).backgroundColor($r('app.color.danger_soft')).borderRadius(14)
      if (AuthService.isEmailSession()) {
        Text('邮箱会话需要在注销前完成最近 5 分钟内的邮箱验证码重新认证。')
          .fontSize(12).lineHeight(18).fontColor($r('app.color.personal_muted')).width('100%')
        TextInput({ text: this.deleteEmailAddress, placeholder: '当前认证邮箱 name@example.com' })
          .width('100%').height(48).backgroundColor($r('app.color.personal_canvas')).borderRadius(14)
          .accessibilityText('当前认证邮箱')
          .onChange((value: string): void => {
            this.deleteEmailAddress = value;
          })
        Row({ space: 10 }) {
          TextInput({ text: this.deleteVerifyCode, placeholder: '邮箱验证码' })
            .layoutWeight(1).height(48).backgroundColor($r('app.color.personal_canvas')).borderRadius(14)
            .accessibilityText('邮箱验证码')
            .onChange((value: string): void => {
              this.deleteVerifyCode = value;
            })
          Button(this.deleteCodeCountdown > 0 ? `${this.deleteCodeCountdown} 秒后重发` :
            (this.deleteCodeBusy ? '发送中…' : '获取验证码'))
            .enabled(!this.busy && !this.deleteCodeBusy && this.deleteCodeCountdown === 0)
            .height(46).fontSize(13).backgroundColor(Color.Transparent).fontColor($r('app.color.personal_action'))
            .border({ width: 1.2, color: $r('app.color.personal_action'), style: BorderStyle.Dashed })
            .onClick(() => this.requestDeleteCode())
        }.width('100%')
      }
      Row({ space: 10 }) {
        Button('取消').layoutWeight(1).height(46).enabled(!this.busy)
          .backgroundColor($r('app.color.personal_canvas')).fontColor($r('app.color.personal_ink'))
          .onClick((): void => {
            this.deleteConfirmationVisible = false;
          })
        Button(this.busy ? '正在注销…' : '确认永久注销').layoutWeight(1).height(46).enabled(!this.busy)
          .backgroundColor($r('app.color.danger_action')).fontColor($r('app.color.on_danger_action'))
          .onClick((): void => {
            this.deleteAccount();
          })
      }.width('100%')
    }.width('100%').padding({ bottom: 12 })
  }

  build() {
    NavDestination() {
      Column() {
        List({ space: 14 }) {
          ListItem() {
            Button({ type: ButtonType.Normal, stateEffect: true }) {
              Row({ space: 12 }) {
                if (this.profile !== undefined && this.profile.avatarUrl.length > 0) {
                  Image(this.profile.avatarUrl).width(48).height(48).borderRadius(24).objectFit(ImageFit.Cover)
                    .accessibilityText('当前用户头像')
                } else {
                  Image($r('app.media.app_icon')).width(48).height(48).borderRadius(24)
                    .accessibilityText('食刻默认头像')
                }
                Column({ space: 3 }) {
                  Text(this.profile?.nickname || '游客').fontSize(16)
                    .fontWeight(FontWeight.Bold).fontColor($r('app.color.personal_ink')).width('100%').maxLines(1)
                  Text(this.profile === undefined ? '当前未登录' : `${this.profile.friendCode || '当前食刻账号'} · 编辑资料`)
                    .fontSize(12).fontColor($r('app.color.personal_muted')).width('100%').maxLines(1)
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                if (this.profile !== undefined) {
                  Image($r('app.media.ic_me_chevron')).width(16).height(16).accessibilityLevel('no')
                }
              }.width('100%')
            }
            .width('100%').padding({ left: 14, right: 14, top: 12, bottom: 12 }).borderRadius(18)
            .backgroundColor($r('app.color.personal_surface'))
            .border({ width: 1.2, color: $r('app.color.personal_line'), style: BorderStyle.Dashed })
            .enabled(this.profile !== undefined && !this.busy).accessibilityText('编辑个人资料')
            .onClick((): void => { this.pathStack.pushPathByName('profile-edit', null); })
          }

          ListItem() {
            Column({ space: 6 }) {
              this.groupTitle('隐私与通知')
              Column() {
                this.settingsRow($r('sys.symbol.lock_shield'), '权限与隐私', '位置、通知与桌面卡片同步', true, false, false,
                  (): void => { if (!this.busy) this.pathStack.pushPathByName('profile-privacy', null); })
                if (this.reviewerAllowed) {
                  this.settingsRow($r('sys.symbol.doc_text'), '管理员系统', '卡片举报审核', false, false, false,
                    (): void => this.pathStack.pushPathByName('card-review-reports', null))
                }
              }
              .width('100%').padding({ left: 14, right: 14 }).borderRadius(16).backgroundColor($r('app.color.personal_surface'))
              .border({ width: 1.2, color: $r('app.color.personal_line'), style: BorderStyle.Dashed })
            }.width('100%')
          }

          if (this.profile !== undefined) {
            ListItem() {
              Column({ space: 6 }) {
                this.groupTitle('登录与会话')
                Column() {
                  this.settingsRow($r('sys.symbol.key'), '更改密码', '', true, false, this.passwordChangeVisible,
                    (): void => { if (this.passwordChangeVisible) this.cancelPasswordChange(); else this.showPasswordChange(); })
                  if (this.passwordChangeVisible) {
                    Column() { this.passwordChangeForm() }.width('100%').padding({ bottom: 12 })
                  }
                  if (this.passwordMessage.length > 0) {
                    Text(this.passwordMessage).fontSize(12.5).lineHeight(19).width('100%').padding({ bottom: 10 })
                      .fontColor(this.passwordFailed ? $r('app.color.danger') : $r('app.color.personal_muted'))
                  }
                  if (!AuthService.isNicknameSession() && !AuthService.isEmailSession()) {
                    this.settingsRow($r('sys.symbol.envelope'), '关联邮箱登录', '关联后可用邮箱登录同一账号', false, false,
                      this.emailBindingVisible,
                      (): void => { if (this.emailBindingVisible) this.emailBindingVisible = false; else this.showEmailBinding(); })
                    if (this.emailBindingVisible) { this.emailBindingForm() }
                  } else if (!AuthService.isNicknameSession()) {
                    this.settingsRow($r('sys.symbol.link'), this.busy ? '正在关联…' : '关联华为账号',
                      '之后可用邮箱或华为账号登录同一账号', false, false, false, (): void => { this.linkHuaweiAccount(); })
                  }
                  this.settingsRow($r('sys.symbol.arrow_left_arrow_right'), this.busy ? '处理中…' : '切换用户',
                    '使当前会话失效并清除本机状态后重新登录', false, false, false, (): void => { this.switchUser(); })
                  this.settingsRow($r('sys.symbol.power'), '退出登录', '', false, false, false, (): void => { this.logout(); })
                }
                .width('100%').padding({ left: 14, right: 14 }).borderRadius(16).backgroundColor($r('app.color.personal_surface'))
                .border({ width: 1.2, color: $r('app.color.personal_line'), style: BorderStyle.Dashed })
                if (AuthService.isNicknameSession()) {
                  Text('忘记密码时，可在登录页通过绑定的邮箱或华为账号验证后重设。关联身份或注销账号前，请先使用绑定的邮箱或华为账号登录。昵称密码会话仅在本次应用运行期间保留；退出登录会撤销所有设备上的昵称密码会话。')
                    .fontSize(12).lineHeight(18).fontColor($r('app.color.personal_muted')).width('100%').padding({ left: 4, right: 4 })
                }
              }.width('100%')
            }

            ListItem() {
              Column({ space: 6 }) {
                this.groupTitle('账号')
                Column() {
                  this.settingsRow($r('sys.symbol.trash'), '注销食刻账号', '提交后账号立即停用，不可恢复', true, true,
                    this.deleteConfirmationVisible,
                    (): void => {
                      if (this.deleteConfirmationVisible) { this.deleteConfirmationVisible = false; return; }
                      this.status = '';
                      this.deleteConfirmationVisible = true;
                    })
                  if (this.deleteConfirmationVisible) { this.deleteConfirmation() }
                }
                .width('100%').padding({ left: 14, right: 14 }).borderRadius(16).backgroundColor($r('app.color.personal_surface'))
                .border({ width: 1.2, color: $r('app.color.danger'), style: BorderStyle.Dashed })
              }.width('100%')
            }
          }

          if (this.status.length > 0) {
            ListItem() {
              Text(this.status).fontSize(13).lineHeight(20).fontColor($r('app.color.warning')).width('100%')
                .padding(12).backgroundColor($r('app.color.personal_soft')).borderRadius(14)
            }
          }
        }
        .width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
        .padding({ left: 14, right: 14, top: 12, bottom: 28 })
      }.width('100%').height('100%').backgroundColor($r('app.color.personal_canvas'))
    }.attributeModifier(new AppDestinationStyle('设置', $r('app.color.personal_canvas'), $r('app.color.personal_header'), 'PERSONAL'))
      .onBackPressed((): boolean => {
        if (this.busy) return true;
        if (this.passwordChangeVisible) { this.cancelPasswordChange(); return true; }
        return false;
      })
  }
}
