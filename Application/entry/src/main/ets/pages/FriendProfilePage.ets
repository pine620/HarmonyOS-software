import { FoodCard } from '../model/CloudContracts';
import { SocialUser } from '../model/FriendModels';
import { UserProfileContent } from './UserProfileContent';

@Component
export struct FriendProfilePage {
  friendUid: string = '';
  onOpenChat: (friend: SocialUser) => void = (_friend: SocialUser): void => {};
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @State foreground: boolean = false;
  build() {
    NavDestination() {
      UserProfileContent({ userUid: this.friendUid, foreground: this.foreground,
        onOpenChat: this.onOpenChat, onOpenCard: this.onOpenCard });
    }.title('用户主页').onShown((): void => { this.foreground = true; })
      .onHidden((): void => { this.foreground = false; });
  }
}
