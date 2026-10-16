// Every build calls the `$latest` version of each cloud function. The app is not distributed through
// AppGallery, so there is no release alias to maintain.
export const CLOUD_FUNCTION_VERSION: string = '$latest';
