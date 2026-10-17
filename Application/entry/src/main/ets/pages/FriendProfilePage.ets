/**
 * 【文件职责】好友/用户主页的 NavDestination 外壳：设置页面外观，内容交给 UserProfileContent。由 Index 的 user-page / friend-profile 路由打开。
 */
import { PagePaletteName, pageColor } from '../common/PagePaletteUi';
import { AppDestinationStyle } from '../common/AppPageUi';
import { FoodCard } from '../model/CloudContracts';
import { SocialUser } from '../model/FriendModels';
import { UserProfileContent } from './UserProfileContent';

// 用户主页外壳。
@Component
export struct FriendProfilePage {
  @Prop palette: PagePaletteName = 'SOCIAL';
  friendUid: string = '';
  friendCode: string = '';
  onOpenChat: (friend: SocialUser) => void = (_friend: SocialUser): void => {};
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @State foreground: boolean = false;
  // 页面布局。
  build() {
    NavDestination() {
      UserProfileContent({ palette: this.palette, userUid: this.friendUid, friendCode: this.friendCode, foreground: this.foreground,
        onOpenChat: this.onOpenChat, onOpenCard: this.onOpenCard });
    }.attributeModifier(new AppDestinationStyle('用户主页', pageColor(this.palette, 'canvas'), pageColor(this.palette, 'header'), this.palette)).onShown((): void => { this.foreground = true; })
      .onHidden((): void => { this.foreground = false; });
  }
}
