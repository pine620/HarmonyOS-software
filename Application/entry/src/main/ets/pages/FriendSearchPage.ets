import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { UserProfile } from '../model/CloudContracts';
import { SocialUser } from '../model/FriendModels';
import { FriendRepository } from '../repository/FriendRepository';
import { AuthService } from '../service/AuthService';
import { SocialAvatar } from '../components/social/SocialDisplay';
import { ErrorDetail, errorText } from '../common/ErrorKit';

@Component
export struct FriendSearchPage {
  onOpenChat: (friend: SocialUser) => void = (_friend: SocialUser): void => {};
  onFriendRequestChanged: () => void = (): void => {};
  @State profile: UserProfile | undefined = undefined;
  @State searchKeyword: string = '';
  @State searchResults: Array<SocialUser> = [];
  @State searchPerformed: boolean = false;
  @State searching: boolean = false;
  @State actionUid: string = '';
  @State searchError: string = '';
  @State status: string = '';
  private repository: FriendRepository = new FriendRepository();

  aboutToAppear(): void {
    this.profile = AuthService.profile();
  }

  private ownFriendCode(): string {
    const code = this.profile?.friendCode;
    return typeof code === 'string' && code.length > 0 ? code : '部署新版云对象后生成';
  }

  private async copyOwnFriendCode(): Promise<void> {
    const code = this.ownFriendCode();
    if (code.startsWith('部署新版')) {
      this.status = '食刻号尚未生成，请稍后重试。';
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, code);
      await pasteboard.getSystemPasteboard().setData(data);
      this.status = '食刻号已复制，可直接发给朋友。';
    } catch (error) {
      this.status = `复制失败：${errorText(error as ErrorDetail)}`;
    }
  }

  private async search(): Promise<void> {
    const keyword = this.searchKeyword.trim();
    if (keyword.length < 2) {
      this.searchError = '请输入对方的完整昵称或食刻号。';
      return;
    }
    if (this.searching) return;
    this.searching = true;
    this.searchPerformed = true;
    this.searchError = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.searchResults = await this.repository.search(context, keyword);
      if (this.searchResults.length === 0) this.searchError = '没有找到匹配用户。请核对完整昵称或食刻号。';
    } catch (error) {
      this.searchResults = [];
      this.searchError = `查找失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.searching = false;
    }
  }

  private async sendRequest(user: SocialUser): Promise<void> {
    if (this.actionUid.length > 0) return;
    this.actionUid = user.uid;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.sendRequest(context, user.uid);
      this.status = `已向 ${user.nickname} 发送好友申请。`;
      this.onFriendRequestChanged();
      void this.search();
    } catch (error) {
      this.status = `申请未发送：${errorText(error as ErrorDetail)}`;
    } finally {
      this.actionUid = '';
    }
  }

  private searchActionText(user: SocialUser): string {
    if (user.friendshipState === 'FRIEND') return '发消息';
    if (user.friendshipState === 'OUTGOING') return '已申请';
    if (user.friendshipState === 'INCOMING') return '待处理';
    return '加好友';
  }

  private searchActionEnabled(user: SocialUser): boolean {
    return this.actionUid.length === 0
      && (user.friendshipState === 'NONE' || user.friendshipState === 'FRIEND');
  }

  private handleSearchAction(user: SocialUser): void {
    if (user.friendshipState === 'FRIEND') this.onOpenChat(user);
    else if (user.friendshipState === 'NONE') this.sendRequest(user);
  }

  @Builder
  private searchResultRow(user: SocialUser): void {
    Row({ space: 12 }) {
      SocialAvatar({ user: user, avatarSize: 52 });
      Column({ space: 4 }) {
        Text(user.nickname).fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
          .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`${user.friendCode} · 已发布 ${user.publishCount} 张`)
          .fontSize(12).fontColor($r('app.color.muted')).width('100%').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Button(this.actionUid === user.uid ? '处理中' : this.searchActionText(user))
        .height(48).enabled(this.searchActionEnabled(user)).fontSize(13)
        .backgroundColor(user.friendshipState === 'NONE' || user.friendshipState === 'FRIEND'
          ? $r('app.color.accent_action') : $r('app.color.accent_soft'))
        .fontColor(user.friendshipState === 'NONE' || user.friendshipState === 'FRIEND'
          ? $r('app.color.on_accent_action') : $r('app.color.muted'))
        .onClick((): void => {
          this.handleSearchAction(user);
        });
    }.width('100%').padding({ top: 8, bottom: 8 });
  }

  build() {
    NavDestination() {
      Column({ space: 16 }) {
        Column({ space: 4 }) {
          Text('通过食刻号添加好友').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
            .width('100%');
          Text('食刻号更准确，也可以用完整昵称查找。').fontSize(13).fontColor($r('app.color.muted')).width('100%');
        }.width('100%').alignItems(HorizontalAlign.Start);

        Column({ space: 12 }) {
          Text('我的食刻号').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink')).width('100%');
          Row({ space: 8 }) {
            Text(this.ownFriendCode()).fontSize(14).fontColor($r('app.color.leaf')).layoutWeight(1).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).copyOption(CopyOptions.LocalDevice)
              .accessibilityDescription('长按可选择并复制食刻号');
            Button('复制').height(48).fontSize(13).backgroundColor($r('app.color.accent_soft'))
              .fontColor($r('app.color.accent_action')).accessibilityText('复制我的食刻号').onClick((): void => {
                this.copyOwnFriendCode();
              });
          }.width('100%').alignItems(VerticalAlign.Center);
          Divider().strokeWidth(1).color($r('app.color.line'));
          Text('查找用户').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink')).width('100%');
          Text('输入完整昵称，或输入对方的食刻号。').fontSize(12).fontColor($r('app.color.muted')).width('100%');
          Row({ space: 10 }) {
            TextInput({ text: this.searchKeyword, placeholder: '昵称或 SK-XXXX-XXXX-XXXX' })
              .layoutWeight(1).height(52).fontSize(15).backgroundColor($r('app.color.canvas')).borderRadius(14)
              .onChange((value: string): void => {
                this.searchKeyword = value;
                this.status = '';
              });
            Button(this.searching ? '查找中' : '查找').height(52).enabled(!this.searching)
              .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
              .onClick((): void => {
                this.search();
              });
          }.width('100%');
          if (this.searchError.length > 0) {
            Text(this.searchError).fontSize(12).lineHeight(18).fontColor($r('app.color.warning')).width('100%');
          }
        }
        .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(20)
        .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start);

        if (this.status.length > 0) {
          Text(this.status).fontSize(12).lineHeight(18).fontColor($r('app.color.warning')).width('100%')
            .padding(10).backgroundColor($r('app.color.accent_soft')).borderRadius(12);
        }
        if (this.searchPerformed && this.searchResults.length > 0) {
          Text(`找到 ${this.searchResults.length} 位用户`).fontSize(15).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink')).width('100%');
          List({ space: 8 }) {
            ForEach(this.searchResults, (user: SocialUser): void => {
              ListItem() { this.searchResultRow(user); }
            }, (user: SocialUser): string => user.uid);
          }
          .width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
          .padding(12).backgroundColor($r('app.color.surface')).borderRadius(18)
          .border({ width: 1, color: $r('app.color.line') });
        } else {
          Blank().layoutWeight(1);
        }
      }
      .width('100%').height('100%').padding({ left: 16, right: 16, top: 14, bottom: 20 })
      .backgroundColor($r('app.color.canvas')).alignItems(HorizontalAlign.Start);
    }.title('添加好友');
  }
}
