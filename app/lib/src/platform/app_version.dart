/// 应用自身版本。
///
/// 通过 `--dart-define=APP_VERSION=x.y.z` 在构建时注入（CI 从 git tag 取），
/// 默认值只用于本地开发。不要把这里当作"唯一真相"——
/// `pubspec.yaml` 的 version 与 git tag 才是发布口径，此处只是运行期可比对的副本。
const String kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '1.0.0',
);

/// 仓库坐标：检查更新时拼 GitHub Releases API。
const String kRepoOwner = 'qiaoba223';
const String kRepoName = 'tool-plugin';

/// 更新包在 Release 里的资源名关键字（CI 产出名包含这些）。
///
/// 一次 Release 会同时挂 APK 与 IPA，按平台各取所需。
const String kApkAssetKeyword = '.apk';
const String kIpaAssetKeyword = '.ipa';
