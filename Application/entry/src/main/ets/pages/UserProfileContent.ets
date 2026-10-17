/**
 * 【文件职责】用户主页内容：资料头部（头像、昵称、食刻号、主页背景）、与我的关系、公开卡片网格（分页 + 可见窗口懒加载）、发私信入口。数据来自 SocialDiscoveryRepository.get-user-page。
 */
import { PagePaletteName, pageColor } from '../common/PagePaletteUi';
import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { SocialUser } from '../model/FriendModels';
import { UserPageRequest, UserPageResponse } from '../model/SocialDiscoveryModels';
import { SocialDiscoveryRepository } from '../repository/SocialDiscoveryRepository';
import { CardRepository } from '../repository/CardRepository';
import { PersonalPreviewLoader, PersonalPreviewRow, PersonalPreviewSource } from '../service/PersonalPreviewLoader';
import { NotePreviewTile } from '../components/NotePreviewTile';
import { NoteActionStyle, WarmNoteBackdrop } from '../common/WarmNoteUi';
import { BreakpointSystem } from '../common/BreakpointSystem';
import { AuthService } from '../service/AuthService';
import { AuthSessionStore } from '../service/AuthSessionStore';
import { ImageRepository } from '../service/ImageRepository';
import { ReadRequestOptions } from '../service/ReadScheduler';
import { CloudBusinessError } from '../service/CloudReadErrors';
import { ErrorDetail, errorText } from '../common/ErrorKit';

// 用户主页内容组件。
@Component
export struct UserProfileContent {
  @Prop palette: PagePaletteName = 'SOCIAL';
  @Prop userUid: string = '';
  @Prop friendCode: string = '';
  @State profileWidth: number = 390;
  @Prop @Watch('onEnvironmentChanged') foreground: boolean = false;
  @StorageLink('stage47AppActive') @Watch('onEnvironmentChanged') appActive: boolean = true;
  @StorageLink('accountContentRevision') @Watch('onEnvironmentChanged') accountContentRevision: number = 0;
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  onOpenChat: (friend: SocialUser) => void = (_friend: SocialUser): void => {};
  @State response: UserPageResponse | undefined = undefined;
  @State avatarUrl: string = '';
  @State coverUrl: string = '';
  @State count: number = 0;
  @State cursor: string = '';
  @State busy: boolean = false;
  @State message: string = '';
  private source: PersonalPreviewSource = new PersonalPreviewSource();
  private previews: PersonalPreviewLoader = new PersonalPreviewLoader(this.source, true);
  private repo: SocialDiscoveryRepository = new SocialDiscoveryRepository();
  private cards: CardRepository = new CardRepository();
  private active: boolean = false;
  private generation: number = 0;
  private owner: string = '';
  private session: number = 0;
  // 取得 UIAbility 上下文。
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  // 异步结果是否仍有效。
  private valid(generation: number): boolean { return this.active && this.foreground && this.appActive &&
    generation === this.generation && this.owner === (AuthService.profile()?.uid || '') && this.session === AuthSessionStore.generation(); }
  // 出现时按当前环境加载。
  aboutToAppear(): void { this.onEnvironmentChanged(); }
  // 消失时停用。
  aboutToDisappear(): void { this.deactivate(); }
  // 停用：作废进行中的加载。
  private deactivate(): void {
    this.active = false; this.generation++; this.previews.reset(false); this.source.setRows([]);
    this.response = undefined; this.avatarUrl = ''; this.coverUrl = ''; this.count = 0; this.cursor = ''; this.busy = false;
  }
  // App 前后台或账号变化时重新加载。
  private onEnvironmentChanged(): void {
    this.deactivate();
    if (!this.foreground || !this.appActive) return;
    this.active = true; this.owner = AuthService.profile()?.uid || ''; this.session = AuthSessionStore.generation();
    this.previews.reset(true); void this.load();
  }
  // 加载资料与一页卡片（more=true 为下一页）。
  private async load(more: boolean = false): Promise<void> {
    if (this.busy || !this.active) return;
    this.busy = true; this.message = '';
    const generation: number = this.generation;
    if (!more) { this.previews.reset(true); this.source.setRows([]); this.count = 0; this.cursor = ''; this.response = undefined; this.avatarUrl = ''; this.coverUrl = ''; }
    try {
      const request: UserPageRequest = { userUid: this.userUid, cursor: more ? this.cursor : '', pageSize: 12 };
      const options: ReadRequestOptions = { mayContinue: async (): Promise<boolean> => this.valid(generation) };
      const result: UserPageResponse = await this.repo.user(request, options);
      if (!this.valid(generation)) return;
      this.response = result; this.cursor = result.nextCursor;
      const rows: Array<PersonalPreviewRow> = more ? this.source.rows().slice() : [];
      for (const card of result.cards) {
        if (rows.some((row: PersonalPreviewRow): boolean => row.cardId === card.id)) continue;
        const row: PersonalPreviewRow = new PersonalPreviewRow(card.id, card.publishedAt || card.createdAt);
        row.card = card; row.state = card.photoPath.length === 0 ? 'NO_IMAGE' : 'MEDIA'; rows.push(row);
      }
      this.source.setRows(rows); this.count = rows.length; this.window(0, 5);
      if (!more) void this.loadHeader(result, generation);
    } catch (error) {
      if (this.valid(generation)) {
        this.previews.reset(false); this.source.setRows([]); this.count = 0; this.cursor = '';
        this.response = undefined; this.avatarUrl = ''; this.coverUrl = ''; this.message = errorText(error as ErrorDetail);
      }
    } finally { if (this.valid(generation)) this.busy = false; }
  }
  // 补全头部的头像与背景图。
  private async loadHeader(result: UserPageResponse, generation: number): Promise<void> {
    try {
      const avatar: string = await ImageRepository.getDownloadUrl(this.context(), result.profile.avatarBucket,
        result.profile.avatarPath, 'normal', async (): Promise<boolean> => this.valid(generation));
      if (!this.valid(generation)) return;
      this.avatarUrl = avatar;
      if ((result.relationshipState === 'FRIEND' || result.relationshipState === 'SELF') && result.profile.coverPath !== undefined && result.profile.coverBucket !== undefined) {
        const cover: string = await ImageRepository.getDownloadUrl(this.context(), result.profile.coverBucket,
          result.profile.coverPath, 'low', async (): Promise<boolean> => this.valid(generation));
        if (this.valid(generation)) this.coverUrl = cover;
      }
    } catch (error) {
      if (this.valid(generation) && error instanceof CloudBusinessError && ['CONTENT_ACCESS_DENIED', 'CONTENT_UNAVAILABLE', 'ACCOUNT_INACTIVE'].includes(error.code)) {
        this.previews.reset(false); this.source.setRows([]); this.response = undefined;
        this.avatarUrl = ''; this.coverUrl = ''; this.count = 0; this.cursor = '';
        this.message = '该主页当前不可访问。';
      }
    }
  }
  // 可见范围变化时更新懒加载窗口。
  private window(first: number, last: number): void { if (this.active) this.previews.window(this.context(), first, last, false); }
  // 打开与该用户的私信。
  private chat(): void {
    const result: UserPageResponse | undefined = this.response;
    if (result === undefined || result.relationshipState !== 'FRIEND') return;
    const friend: SocialUser = { uid: result.profile.uid, nickname: result.profile.nickname, avatarUrl: this.avatarUrl,
      avatarPath: result.profile.avatarPath, avatarBucket: result.profile.avatarBucket, publishCount: result.profile.publishCount,
      friendCode: this.profileCode(), friendshipState: 'FRIEND', requestId: '' };
    this.onOpenChat(friend);
  }
  // 打开卡片详情。
  private async open(cardId: string): Promise<void> {
    if (this.busy || !this.active) return;
    const generation: number = this.generation; this.busy = true;
    try {
      const options: ReadRequestOptions = { mayContinue: async (): Promise<boolean> => this.valid(generation) };
      const card: FoodCard = await this.cards.detail(this.context(), cardId, options);
      if (this.valid(generation)) this.onOpenCard(card);
    } catch (error) { if (this.valid(generation)) { this.busy = false; void this.load(); } }
    finally { if (this.valid(generation)) this.busy = false; }
  }
  // 食刻号显示文本。
  private profileCode(): string {
    if (this.response?.relationshipState === 'SELF') return AuthService.profile()?.friendCode || '';
    return this.response?.relationshipState === 'FRIEND' ? this.friendCode : '';
  }
  // 资料头部区域。
  @Builder
  private profileHeader(): void {
    Column({ space: 12 }) {
      if (this.coverUrl.length > 0) {
        Image(this.coverUrl).width('100%').height(180).objectFit(ImageFit.Cover).borderRadius(22).accessibilityText('好友主页封面');
      } else {
        Column() {}.width('100%').height(160).backgroundColor(pageColor(this.palette, 'soft')).borderRadius(22).accessibilityLevel('no');
      }
      Row({ space: 12 }) {
        Image(this.avatarUrl.length > 0 ? this.avatarUrl : $r('app.media.app_icon')).width(88).height(88)
          .objectFit(ImageFit.Cover).borderRadius(44).border({ width: 4, color: pageColor(this.palette, 'surface') }).accessibilityLevel('no');
        Column({ space: 6 }) {
          Text(this.response === undefined ? '用户主页' : this.response.profile.nickname).fontSize(23).fontWeight(FontWeight.Bold)
            .fontColor(pageColor(this.palette, 'ink')).width('100%').maxLines(2);
          if (this.profileCode().length > 0) { Text('食刻号 ' + this.profileCode()).fontSize(12).fontColor(pageColor(this.palette, 'muted'))
            .copyOption(CopyOptions.LocalDevice).width('100%').maxLines(2); }
          Text(this.response?.relationshipState === 'SELF' ? '我的主页' : this.response?.relationshipState === 'FRIEND' ? '已是好友' : '公开主页')
            .fontSize(12).fontColor(pageColor(this.palette, 'action'));
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      }.width('100%').padding({ left: 12, right: 12 }).margin({ top: -34 });
      Row({ space: 12 }) {
        Text(this.response === undefined ? '正在读取主页…' : `已发布 ${this.response.profile.publishCount} 张`).fontSize(14)
          .fontColor(pageColor(this.palette, 'muted')).layoutWeight(1);
        if (this.response?.relationshipState === 'FRIEND') { Button('发消息').enabled(!this.busy)
          .attributeModifier(new NoteActionStyle(true, this.palette)).onClick((): void => this.chat()); }
      }.width('100%').padding({ left: 12, right: 12, bottom: 12 });
    }.width('100%').backgroundColor(pageColor(this.palette, 'surface')).borderRadius(22);
  }
  // 页面布局。
  build() {
    Stack() {
      WarmNoteBackdrop({ palette: this.palette });
      Column({ space: 14 }) {
        this.profileHeader();
        Row() {
          Text('美食推荐').fontSize(19).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')).layoutWeight(1);
          Button(this.busy ? '读取中…' : '刷新').enabled(!this.busy).height(48).fontSize(13)
            .backgroundColor(Color.Transparent).fontColor(pageColor(this.palette, 'action')).onClick((): void => { void this.load(); });
        }.width('100%');
        if (this.message.length > 0) { Text(this.message).fontSize(13).fontColor(pageColor(this.palette, 'muted')).width('100%'); }
        if (!this.busy && this.response !== undefined && this.count === 0) {
          Text('这里还没有公开推荐。').fontSize(14).fontColor(pageColor(this.palette, 'muted')).width('100%');
        }
        Grid() {
          LazyForEach(this.source, (row: PersonalPreviewRow): void => {
            GridItem() { NotePreviewTile({ palette: this.palette, row, busy: this.busy, onOpen: (cardId: string): void => { void this.open(cardId); } }); }
          }, (row: PersonalPreviewRow): string => row.cardId);
          if (this.cursor.length > 0) {
            GridItem() { Button(this.busy ? '正在加载…' : '加载更多推荐').width('100%').enabled(!this.busy)
              .attributeModifier(new NoteActionStyle(false, this.palette)).onClick((): void => { void this.load(true); }); }
              .columnStart(0).columnEnd(BreakpointSystem.columns(BreakpointSystem.fromWidth(this.profileWidth)) - 1);
          }
        }.width('100%').layoutWeight(1).columnsTemplate(BreakpointSystem.columnsTemplate(BreakpointSystem.fromWidth(this.profileWidth)))
          .columnsGap(12).rowsGap(12).cachedCount(2).onScrollIndex((first: number, last: number): void => this.window(first, last));
      }.width('100%').height('100%').padding({ left: 16, right: 16, top: 8, bottom: 12 })
        .onAreaChange((_oldArea: Area, newArea: Area): void => {
          const width: number = Number(newArea.width); if (Number.isFinite(width) && width > 0) this.profileWidth = width;
        });
    }.width('100%').height('100%').backgroundColor(pageColor(this.palette, 'canvas'));
  }
}
