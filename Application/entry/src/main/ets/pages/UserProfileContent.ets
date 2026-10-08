import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { SocialUser } from '../model/FriendModels';
import { UserPageRequest, UserPageResponse } from '../model/SocialDiscoveryModels';
import { SocialDiscoveryRepository } from '../repository/SocialDiscoveryRepository';
import { CardRepository } from '../repository/CardRepository';
import { PersonalPreviewLoader, PersonalPreviewRow, PersonalPreviewSource } from '../service/PersonalPreviewLoader';
import { PersonalPreviewTile } from '../components/PersonalPreviewTile';
import { AuthService } from '../service/AuthService';
import { AuthSessionStore } from '../service/AuthSessionStore';
import { PhotoUploadService } from '../service/PhotoUploadService';
import { ReadRequestOptions } from '../service/ReadScheduler';
import { CloudBusinessError } from '../service/CloudReadErrors';
import { ErrorDetail, errorText } from '../common/ErrorKit';

@Component
export struct UserProfileContent {
  @Prop userUid: string = '';
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
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private valid(generation: number): boolean { return this.active && this.foreground && this.appActive &&
    generation === this.generation && this.owner === (AuthService.profile()?.uid || '') && this.session === AuthSessionStore.generation(); }
  aboutToAppear(): void { this.onEnvironmentChanged(); }
  aboutToDisappear(): void { this.deactivate(); }
  private deactivate(): void {
    this.active = false; this.generation++; this.previews.reset(false); this.source.setRows([]);
    this.response = undefined; this.avatarUrl = ''; this.coverUrl = ''; this.count = 0; this.cursor = ''; this.busy = false;
  }
  private onEnvironmentChanged(): void {
    this.deactivate();
    if (!this.foreground || !this.appActive) return;
    this.active = true; this.owner = AuthService.profile()?.uid || ''; this.session = AuthSessionStore.generation();
    this.previews.reset(true); void this.load();
  }
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
  private async loadHeader(result: UserPageResponse, generation: number): Promise<void> {
    try {
      const avatar: string = await PhotoUploadService.getDownloadUrl(this.context(), result.profile.avatarBucket,
        result.profile.avatarPath, 'normal', async (): Promise<boolean> => this.valid(generation));
      if (!this.valid(generation)) return;
      this.avatarUrl = avatar;
      if ((result.relationshipState === 'FRIEND' || result.relationshipState === 'SELF') && result.profile.coverPath !== undefined && result.profile.coverBucket !== undefined) {
        const cover: string = await PhotoUploadService.getDownloadUrl(this.context(), result.profile.coverBucket,
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
  private window(first: number, last: number): void { if (this.active) this.previews.window(this.context(), first, last, false); }
  private chat(): void {
    const result: UserPageResponse | undefined = this.response;
    if (result === undefined || result.relationshipState !== 'FRIEND') return;
    const friend: SocialUser = { uid: result.profile.uid, nickname: result.profile.nickname, avatarUrl: this.avatarUrl,
      avatarPath: result.profile.avatarPath, avatarBucket: result.profile.avatarBucket, publishCount: result.profile.publishCount,
      friendCode: '', friendshipState: 'FRIEND', requestId: '' };
    this.onOpenChat(friend);
  }
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
  build() {
    Column({ space: 12 }) {
      if (this.coverUrl.length > 0) { Image(this.coverUrl).width('100%').height(120).objectFit(ImageFit.Cover).borderRadius(16).accessibilityLevel('no'); }
      Row({ space: 12 }) {
        Image(this.avatarUrl.length > 0 ? this.avatarUrl : $r('app.media.app_icon')).width(48).height(48)
          .objectFit(ImageFit.Cover).borderRadius(24).accessibilityLevel('no');
        Column({ space: 4 }) {
          Text(this.response === undefined ? '用户主页' : this.response.profile.nickname).fontSize(20)
            .fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
          Text(this.response?.relationshipState === 'SELF' ? '我的主页' : this.response?.relationshipState === 'FRIEND' ? '好友 · 可查看好友可见内容' : '访客 · 公开推荐')
            .fontSize(12).fontColor($r('app.color.muted'));
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
        if (this.response?.relationshipState === 'FRIEND') {
          Button('发消息').constraintSize({ minHeight: 48 }).fontSize(13).backgroundColor($r('app.color.accent_soft'))
            .fontColor($r('app.color.action_text')).onClick((): void => this.chat());
        }
      }.width('100%').padding(12).backgroundColor($r('app.color.surface')).borderRadius(16);
      Row() {
        Text(`已加载 ${this.count} 张卡片`).fontSize(12).fontColor($r('app.color.muted')); Blank();
        Button(this.busy ? '读取中' : '刷新').constraintSize({ minHeight: 48 }).fontSize(13).enabled(!this.busy)
          .backgroundColor(Color.Transparent).fontColor($r('app.color.action_text')).onClick((): void => { void this.load(); });
      }.width('100%');
      if (this.message.length > 0) { Text(this.message).fontSize(13).fontColor($r('app.color.muted')).width('100%'); }
      List({ space: 10 }) {
        LazyForEach(this.source, (row: PersonalPreviewRow): void => {
          ListItem() { PersonalPreviewTile({ row, busy: this.busy, onOpen: (cardId: string): void => { void this.open(cardId); } }); }
        }, (row: PersonalPreviewRow): string => row.cardId);
        if (this.cursor.length > 0) { ListItem() { Button('加载更多').width('100%').constraintSize({ minHeight: 48 }).enabled(!this.busy)
          .backgroundColor($r('app.color.surface')).fontColor($r('app.color.action_text')).onClick((): void => { void this.load(true); }); } }
      }.width('100%').layoutWeight(1).cachedCount(2).onScrollIndex((first: number, last: number): void => this.window(first, last));
    }.width('100%').height('100%').padding({ left: 16, right: 16, top: 8, bottom: 12 }).backgroundColor($r('app.color.canvas'));
  }
}
