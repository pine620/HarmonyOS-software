/**
 * 【文件职责】登录 / 注册界面（在“我的”页弹出）。支持：昵称+密码登录（PASSWORD）、邮箱验证码登录（CODE）、
 * 邮箱注册（REGISTER）、找回密码（RESET）、首次设置昵称密码（SETUP）以及华为账号登录入口。
 * 所有实际逻辑在 AuthService 中，本组件只负责表单、校验提示、验证码倒计时与视图切换。
 */
import { common } from '@kit.AbilityKit';
import { PasswordAccountStatus, UserProfile } from '../model/CloudContracts';
import { AuthService, PasswordSavedError } from '../service/AuthService';
import { AuthSessionStore } from '../service/AuthSessionStore';

// 登录界面的几种视图。
type LoginView = 'PASSWORD' | 'CODE' | 'REGISTER' | 'RESET' | 'SETUP' | 'VERIFIED';

// 登录 / 注册组件。
@Component
export struct EmailLoginPage {
  onAuthenticated: (profile: UserProfile) => void = (_profile: UserProfile): void => {};
  onClose: () => void = (): void => {};
  onBusyChanged: (busy: boolean) => void = (_busy: boolean): void => {};
  @Prop @Watch('onBackRequest') backRequest: number = 0;
  @State view: LoginView = 'PASSWORD';
  @State nickname: string = '';
  @State email: string = '';
  @State password: string = '';
  @State code: string = '';
  @State nicknameError: string = '';
  @State emailError: string = '';
  @State passwordError: string = '';
  @State codeError: string = '';
  @State message: string = '';
  @State failed: boolean = false;
  @State busy: boolean = false;
  @State sending: boolean = false;
  @State huaweiBusy: boolean = false;
  @State countdown: number = 0;
  private timer: number | undefined = undefined;
  private resendAt: number = 0;
  private active: boolean = false;
  private verifiedProfile: UserProfile | undefined = undefined;
  private recovering: boolean = false;

  // 组件显示时标记为活动。
  aboutToAppear(): void { this.active = true; }
  // 组件销毁时停止验证码倒计时。
  aboutToDisappear(): void {
    this.active = false;
    if (this.timer !== undefined) clearTimeout(this.timer);
    this.timer = undefined;
  }

  // 取得 UIAbility 上下文。
  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  // 处理返回键：忙碌时忽略；不在“昵称密码登录”视图时退回该视图，否则关闭登录界面。
  private onBackRequest(): void {
    if (this.busy || this.sending) return;
    if (this.view !== 'PASSWORD') void this.changeView('PASSWORD');
    else void this.close();
  }

  // 设置忙碌状态并通知父组件。
  private setBusy(value: boolean): void { this.busy = value; this.onBusyChanged(value); }

  // 已完成邮箱/华为验证但未设置昵称密码时取消：退出该会话。
  private async cancelVerified(): Promise<void> {
    await AuthService.cancelAuthentication(this.context());
    this.verifiedProfile = undefined;
  }

  // 关闭登录界面。
  private async close(): Promise<void> {
    if (this.busy || this.sending) return;
    this.setBusy(true);
    try {
      await this.cancelVerified();
      if (!this.active) return;
      this.password = ''; this.code = ''; this.setBusy(false); this.onClose();
    } catch (_error) {
      if (this.active) { this.failed = true; this.message = '退出登录流程失败，请重试'; }
    } finally { if (this.active) this.setBusy(false); }
  }

  // 切换视图并清空相关输入与错误提示。
  private async changeView(view: LoginView): Promise<void> {
    if (this.busy || this.sending) return;
    this.setBusy(true);
    try {
      await this.cancelVerified();
      if (!this.active) return;
      this.view = view; this.recovering = view === 'RESET';
      this.password = ''; this.code = ''; this.nicknameError = ''; this.emailError = '';
      this.passwordError = ''; this.codeError = ''; this.message = ''; this.failed = false;
    } catch (_error) {
      if (this.active) { this.failed = true; this.message = '切换登录方式失败，请重试'; }
    } finally { if (this.active) this.setBusy(false); }
  }

  // 当前视图的标题。
  private title(): string {
    if (this.view === 'REGISTER') return '注册';
    if (this.view === 'RESET') return '找回密码';
    if (this.view === 'SETUP') return this.recovering ? '重设密码' : '设置昵称和密码';
    if (this.view === 'VERIFIED') return '身份已验证';
    return '登录';
  }

  // 当前视图主按钮的文字。
  private actionLabel(): string {
    if (this.busy) return this.view === 'SETUP' ? '保存中…' : '处理中…';
    if (this.view === 'SETUP') return '保存并登录';
    if (this.view === 'REGISTER' || this.view === 'RESET' || this.view === 'VERIFIED') return '继续';
    return '登录';
  }

  // 校验邮箱格式。
  private validateEmail(): boolean {
    try { AuthSessionStore.normalizeEmail(this.email); this.emailError = ''; return true; }
    catch (_error) { this.emailError = '请输入有效的邮箱地址'; return false; }
  }

  // 校验当前视图的表单字段。
  private validateForm(): boolean {
    this.nicknameError = ''; this.passwordError = ''; this.codeError = '';
    if (this.view === 'VERIFIED') return true;
    if (this.view === 'PASSWORD' || this.view === 'SETUP') {
      if (this.nickname.trim().length < 2 || this.nickname.trim().length > 24) this.nicknameError = '请输入 2–24 个字的昵称';
      if (this.password.length === 0) this.passwordError = '请输入密码';
      else if (this.view === 'SETUP') {
        try { AuthSessionStore.validateNewPassword(this.password); }
        catch (error) { this.passwordError = error instanceof Error ? error.message : '请设置有效的密码'; }
      }
      return this.nicknameError.length === 0 && this.passwordError.length === 0;
    }
    const emailValid: boolean = this.validateEmail();
    if (this.code.trim().length === 0) this.codeError = '请输入验证码';
    return emailValid && this.codeError.length === 0;
  }

  // 验证码重发倒计时（每秒更新）。
  private updateCountdown(): void {
    if (this.timer !== undefined) clearTimeout(this.timer);
    this.timer = undefined;
    this.countdown = Math.max(0, Math.ceil((this.resendAt - Date.now()) / 1000));
    if (this.countdown > 0 && this.active) this.timer = setTimeout((): void => this.updateCountdown(), 1000);
  }

  // 发送邮箱验证码（找回密码或注册/登录）。
  private async sendCode(): Promise<void> {
    if (this.busy || this.sending || Date.now() < this.resendAt || !this.validateEmail()) return;
    this.sending = true; this.onBusyChanged(true); this.message = ''; this.failed = false;
    try {
      await AuthService.requestEmailCode(this.context(), this.email);
      if (!this.active) return;
      this.resendAt = Date.now() + 60000; this.updateCountdown(); this.message = '验证码已发送';
    } catch (error) {
      if (this.active) { this.failed = true; this.message = AuthService.credentialError(error as Object, '验证码发送失败，请稍后重试。'); }
    } finally { if (this.active) { this.sending = false; this.onBusyChanged(false); } }
  }

  // 登录完成：通知父组件并关闭。
  private finish(profile: UserProfile): void {
    this.password = ''; this.code = ''; this.verifiedProfile = undefined;
    this.huaweiBusy = false; this.setBusy(false); this.onAuthenticated(profile);
  }

  // 邮箱/华为验证成功后：账号已设置昵称密码（且不是找回密码流程）则直接完成登录，否则进入 SETUP 设置昵称密码。
  private async continueVerified(): Promise<void> {
    const profile: UserProfile | undefined = this.verifiedProfile;
    if (profile === undefined) throw new Error('请先验证邮箱或华为账号。');
    const status: PasswordAccountStatus = await AuthService.passwordAccountStatus();
    if (!this.active) return;
    if (status.configured && !this.recovering) { this.finish(profile); return; }
    this.nickname = profile.nickname;
    this.view = 'SETUP'; this.password = ''; this.code = '';
  }

  // 记录验证得到的资料并进入 VERIFIED 视图，然后继续后续步骤。
  private async acceptProvider(profile: UserProfile): Promise<void> {
    this.verifiedProfile = profile; this.view = 'VERIFIED'; this.code = '';
    await this.continueVerified();
  }

  // 提交当前视图的表单（调用 AuthService 对应方法）。
  private async submit(): Promise<void> {
    if (this.busy || this.sending || !this.validateForm()) return;
    this.setBusy(true); this.message = ''; this.failed = false;
    try {
      if (this.view === 'VERIFIED') { await this.continueVerified(); return; }
      if (this.view === 'SETUP') {
        const profile: UserProfile = await AuthService.configurePasswordAccount(this.context(), this.nickname, this.password);
        if (this.active) this.finish(profile);
      } else if (this.view === 'PASSWORD') {
        const profile: UserProfile = await AuthService.nicknameLogin(this.context(), this.nickname, this.password);
        if (this.active) this.finish(profile);
      } else {
        const profile: UserProfile = this.view === 'REGISTER'
          ? await AuthService.registerVerifiedEmail(this.context(), this.email, this.code)
          : await AuthService.emailLogin(this.context(), this.email, this.code, false);
        if (this.active) await this.acceptProvider(profile);
      }
    } catch (error) {
      if (this.active) {
        if (error instanceof PasswordSavedError) {
          this.view = 'PASSWORD'; this.recovering = false; this.verifiedProfile = undefined;
          this.password = ''; this.code = '';
        }
        this.failed = true;
        this.message = AuthService.credentialError(error as Object,
          this.view === 'SETUP' ? '昵称和密码保存未完成，请重试。' : '登录未完成，请重试。');
      }
    } finally { if (this.active) this.setBusy(false); }
  }

  // 华为账号登录入口。
  private async huaweiLogin(): Promise<void> {
    if (this.busy || this.sending) return;
    this.setBusy(true); this.huaweiBusy = true; this.message = ''; this.failed = false;
    try {
      const profile: UserProfile = await AuthService.login(this.context(), true, this.view === 'REGISTER');
      if (this.active) await this.acceptProvider(profile);
    } catch (error) {
      if (this.active) { this.failed = true; this.message = AuthService.credentialError(error as Object, '华为账号验证未完成，请重试。'); }
    } finally { if (this.active) { this.huaweiBusy = false; this.setBusy(false); } }
  }

  // 显示字段错误提示。
  @Builder
  private fieldError(message: string): void {
    if (message.length > 0) {
      Text(message).fontSize(13).fontColor($r('app.color.danger')).width('100%').margin({ top: 6 }).accessibilityText(message)
    }
  }

  // 表单区域（按视图显示不同输入框）。
  @Builder
  private form(): void {
    Column() {
      if (this.view === 'PASSWORD' || this.view === 'SETUP') {
        Text('昵称').fontSize(14).fontColor($r('app.color.muted')).width('100%')
        TextInput({ text: this.nickname, placeholder: '输入昵称' }).maxLength(24).enterKeyType(EnterKeyType.Next)
          .height(52).width('100%').fontSize(16).fontColor($r('app.color.ink')).backgroundColor($r('app.color.surface'))
          .border({ width: 1, color: $r('app.color.line') }).borderRadius(14).margin({ top: 8 })
          .enabled(!this.busy && !this.sending).accessibilityText('登录昵称')
          .onChange((value: string): void => { this.nickname = value; this.nicknameError = ''; this.message = ''; })
        this.fieldError(this.nicknameError)
        Text(this.recovering ? '新密码' : '密码').fontSize(14).fontColor($r('app.color.muted')).width('100%').margin({ top: 20 })
        TextInput({ text: this.password, placeholder: this.view === 'PASSWORD' ? '输入密码' : '至少 8 位，含两种字符' })
          .type(InputType.Password).showPasswordIcon(true).maxLength(128).enterKeyType(EnterKeyType.Done)
          .height(52).width('100%').fontSize(16).fontColor($r('app.color.ink')).backgroundColor($r('app.color.surface'))
          .border({ width: 1, color: $r('app.color.line') }).borderRadius(14).margin({ top: 8 })
          .enabled(!this.busy && !this.sending).accessibilityText('密码')
          .onChange((value: string): void => { this.password = value; this.passwordError = ''; this.message = ''; })
          .onSubmit((): void => { void this.submit(); })
        this.fieldError(this.passwordError)
      } else if (this.view !== 'VERIFIED') {
        Text('邮箱').fontSize(14).fontColor($r('app.color.muted')).width('100%')
        TextInput({ text: this.email, placeholder: 'name@example.com' }).type(InputType.Email).maxLength(254)
          .enterKeyType(EnterKeyType.Next).height(52).width('100%').fontSize(16).fontColor($r('app.color.ink'))
          .backgroundColor($r('app.color.surface')).border({ width: 1, color: $r('app.color.line') }).borderRadius(14).margin({ top: 8 })
          .enabled(!this.busy && !this.sending).accessibilityText('邮箱地址')
          .onChange((value: string): void => { this.email = value; this.emailError = ''; this.code = ''; this.message = ''; })
        this.fieldError(this.emailError)
        Text('验证码').fontSize(14).fontColor($r('app.color.muted')).width('100%').margin({ top: 20 })
        Row({ space: 8 }) {
          TextInput({ text: this.code, placeholder: '输入验证码' }).type(InputType.Number).maxLength(12)
            .enterKeyType(EnterKeyType.Done).layoutWeight(1).height(52).fontSize(16).fontColor($r('app.color.ink'))
            .backgroundColor($r('app.color.surface')).border({ width: 1, color: $r('app.color.line') }).borderRadius(14)
            .enabled(!this.busy && !this.sending).accessibilityText('邮箱验证码')
            .onChange((value: string): void => { this.code = value; this.codeError = ''; this.message = ''; })
            .onSubmit((): void => { void this.submit(); })
          Button(this.countdown > 0 ? `${this.countdown} 秒` : this.sending ? '发送中…' : '获取验证码')
            .height(48).fontSize(14).padding({ left: 10, right: 10 }).backgroundColor(Color.Transparent)
            .fontColor($r('app.color.action_text')).enabled(!this.busy && !this.sending && this.countdown === 0)
            .onClick((): void => { void this.sendCode(); })
        }.width('100%').margin({ top: 8 })
        this.fieldError(this.codeError)
      }
      if (this.view === 'PASSWORD') {
        Row() {
          Blank()
          Button('忘记密码').height(48).fontSize(14).padding({ left: 8, right: 0 }).backgroundColor(Color.Transparent)
            .fontColor($r('app.color.action_text')).enabled(!this.busy && !this.sending)
            .onClick((): void => { void this.changeView('RESET'); })
        }.width('100%')
      }
      if (this.message.length > 0) {
        Text(this.message).fontSize(13).lineHeight(20).width('100%').margin({ top: 12, bottom: 12 })
          .fontColor(this.failed ? $r('app.color.danger') : $r('app.color.muted'))
      }
      Button(this.actionLabel()).width('100%').height(52).fontSize(16).fontWeight(FontWeight.Medium).borderRadius(16)
        .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action')).margin({ top: 16 })
        .enabled(!this.busy && !this.sending).onClick((): void => { void this.submit(); })
      Button(this.view === 'PASSWORD' || this.view === 'CODE' ? '注册账号' : '返回登录').height(48).fontSize(14)
        .margin({ top: 12 }).alignSelf(ItemAlign.Center).backgroundColor(Color.Transparent).fontColor($r('app.color.action_text'))
        .enabled(!this.busy && !this.sending).onClick((): void => {
          void this.changeView(this.view === 'PASSWORD' || this.view === 'CODE' ? 'REGISTER' : 'PASSWORD');
        })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  // 整体布局。
  build() {
    Scroll() {
      Column() {
        Row() {
          Blank()
          Button('暂不登录').height(48).fontSize(14).backgroundColor(Color.Transparent).fontColor($r('app.color.muted'))
            .enabled(!this.busy && !this.sending).onClick((): void => { void this.close(); })
        }.width('100%')
        Row({ space: 10 }) {
          Image($r('app.media.app_icon')).width(44).height(44).borderRadius(14).objectFit(ImageFit.Contain).accessibilityLevel('no')
          Text('食刻').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
        }.justifyContent(FlexAlign.Center).width('100%').margin({ top: 16, bottom: 32 })
        Text(this.title()).width('100%').fontSize(28).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).margin({ bottom: 24 })
        if (this.view === 'PASSWORD' || this.view === 'CODE') {
          Row({ space: 20 }) {
            Button('密码登录').height(48).fontSize(15).backgroundColor(Color.Transparent)
              .fontColor(this.view === 'PASSWORD' ? $r('app.color.action_text') : $r('app.color.muted'))
              .enabled(!this.busy && !this.sending).onClick((): void => { void this.changeView('PASSWORD'); })
            Button('验证码登录').height(48).fontSize(15).backgroundColor(Color.Transparent)
              .fontColor(this.view === 'CODE' ? $r('app.color.action_text') : $r('app.color.muted'))
              .enabled(!this.busy && !this.sending).onClick((): void => { void this.changeView('CODE'); })
          }.width('100%').margin({ bottom: 20 })
        }
        this.form()
        if (this.view !== 'SETUP' && this.view !== 'VERIFIED') {
          Button(this.huaweiBusy ? '连接中…' : this.view === 'RESET' ? '通过华为账号找回' :
            this.view === 'REGISTER' ? '通过华为账号注册' : '华为账号登录')
            .height(48).fontSize(14).margin({ top: 24 }).backgroundColor(Color.Transparent).fontColor($r('app.color.muted'))
            .enabled(!this.busy && !this.sending).onClick((): void => { void this.huaweiLogin(); })
        }
      }.width('100%').constraintSize({ maxWidth: 420 }).padding({ left: 24, right: 24, top: 16, bottom: 32 })
        .alignItems(HorizontalAlign.Center)
    }.width('100%').height('100%').scrollBar(BarState.Off).backgroundColor($r('app.color.canvas'))
  }
}
