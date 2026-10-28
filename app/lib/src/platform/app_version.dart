/// 应用自身版本与仓库坐标。
///
/// 版本号通过 `--dart-define=APP_VERSION=x.y.z` 在构建时注入（CI 从 git tag 取），
/// 默认值只用于本地开发。真正的发布口径是 git tag，这里只是运行期可比较的副本。
library;

const String kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '1.0.0',
);

/// 应用自身的发布仓库（用于"检查更新"）。
///
/// 注意：这与**插件库**是两套东西。
/// - 这里指向 App 的 Release，用来下载新的 APK/IPA；
/// - 插件库地址由用户在「插件库设置」里填（见 [kDefaultPluginRepoUrl]）。
///
/// 必须是**公开**仓库，否则 App 端匿名请求拿不到 Release，
/// GitHub 会返回 404（私有仓库对匿名者不可见）或 403（带 UA 时）。
const String kRepoOwner = 'qiaoba223';
const String kRepoName = 'tool-plugin';

/// 更新包在 Release 里的资源名后缀。
const String kApkAssetKeyword = '.apk';
const String kIpaAssetKeyword = '.ipa';

/// 插件库的默认地址（与上游一致，指向规范/示例仓库）。
///
/// 上游那个仓库只放 schema 与文档、没有 index.json，所以首次打开
/// 插件库页会是空列表——这是预期行为：插件库由用户自己维护，
/// 或填第三方维护的仓库（如 `https://github.com/mtguowang/plugin-harbor`）。
const String kDefaultPluginRepoUrl = 'https://github.com/mtguowang/tool-plugin';
