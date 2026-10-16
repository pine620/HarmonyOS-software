import BuildProfile from 'BuildProfile';

// Release builds call the `prod` alias of every cloud function; rolling back a bad deployment is then a
// matter of pointing `prod` at the previous version in AGC. Debug builds keep using `$latest` so day-to-day
// deployments are visible to developers immediately. Create the `prod` alias before shipping a release build.
function resolveCloudFunctionVersion(buildMode: string): string {
  return buildMode === 'release' ? 'prod' : '$latest';
}

export const CLOUD_FUNCTION_VERSION: string = resolveCloudFunctionVersion(BuildProfile.BUILD_MODE_NAME);
