import { emptySocialUser, SocialUser } from '../../model/FriendModels';

@Component
export struct SocialAvatar {
  @Prop user: SocialUser = emptySocialUser();
  @Prop avatarSize: number = 52;

  build() {
    if (this.user.avatarUrl.length > 0) {
      Image(this.user.avatarUrl)
        .width(this.avatarSize).height(this.avatarSize)
        .borderRadius(this.avatarSize / 2).objectFit(ImageFit.Cover)
        .accessibilityText(`${this.user.nickname}的头像`);
    } else {
      Image($r('app.media.app_icon'))
        .width(this.avatarSize).height(this.avatarSize).borderRadius(Math.min(18, this.avatarSize / 3))
        .objectFit(ImageFit.Cover).accessibilityText(`${this.user.nickname}的默认头像`);
    }
  }
}
