import { PagePaletteName, pageColor } from '../common/PagePaletteUi';
import { AppDestinationStyle } from '../common/AppPageUi';
import { FoodCard } from '../model/CloudContracts';
import { SocialUser } from '../model/FriendModels';
import { UserProfileContent } from './UserProfileContent';

@Component
export struct FriendProfilePage {
  @Prop palette: PagePaletteName = 'SOCIAL';
  friendUid: string = '';
  friendCode: string = '';
  onOpenChat: (friend: SocialUser) => void = (_friend: SocialUser): void => {};
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @State foreground: boolean = false;
  build() {
    NavDestination() {
      UserProfileContent({ palette: this.palette, userUid: this.friendUid, friendCode: this.friendCode, foreground: this.foreground,
        onOpenChat: this.onOpenChat, onOpenCard: this.onOpenCard });
    }.attributeModifier(new AppDestinationStyle('用户主页', pageColor(this.palette, 'canvas'), pageColor(this.palette, 'header'), this.palette)).onShown((): void => { this.foreground = true; })
      .onHidden((): void => { this.foreground = false; });
  }
}
