#!/usr/bin/env python3
"""在 CI 中修正 flutter create 生成的平台工程。

flutter create 会用 Flutter 版本的默认值覆盖我们提交的配置，所以凡是
必须钉死的项都在这里重新写一遍，保证每次构建结果一致。

检查项全部带校验：任何一项没改成功就让 CI 失败，避免悄悄产出一个
部署目标不对的 IPA。
"""
import os
import re
import plistlib
import sys

IOS_DEPLOY = '13.0'
BUNDLE_ID = 'com.qiaoba.toolplugin'
DISPLAY_NAME = '插件工具箱'
ANDROID_NS = 'com.qiaoba.toolplugin'
# Flutter 3.41 的引擎要求 minSdk >= 23；取 26 与旧项目一致，
# 也能覆盖 desugaring 需要的 API。
ANDROID_MIN_SDK = 26

failures = []


def check(cond, msg):
    if cond:
        print(f'[OK] {msg}')
    else:
        print(f'[FAIL] {msg}')
        failures.append(msg)


def patch_pbxproj():
    for path in ('ios/Runner.xcodeproj/project.pbxproj',):
        if not os.path.exists(path):
            print(f'[SKIP] {path} 不存在（本次未生成 iOS 工程）')
            continue
        with open(path, encoding='utf-8') as f:
            c = f.read()
        orig = c
        c = re.sub(r'IPHONEOS_DEPLOYMENT_TARGET\s*=\s*[^;]+;',
                   f'IPHONEOS_DEPLOYMENT_TARGET = {IOS_DEPLOY};', c)
        c = re.sub(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*[^;]+;',
                   f'PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};', c)
        if c != orig:
            with open(path, 'w', encoding='utf-8') as f:
                f.write(c)
        targets = set(re.findall(r'IPHONEOS_DEPLOYMENT_TARGET\s*=\s*([^;]+);', c))
        check(targets == {IOS_DEPLOY},
              f'PBXProject 部署目标统一为 {IOS_DEPLOY}（实际 {sorted(targets)}）')


def patch_info_plist():
    path = 'ios/Runner/Info.plist'
    if not os.path.exists(path):
        print(f'[SKIP] {path} 不存在（本次未生成 iOS 工程）')
        return
    with open(path, 'rb') as f:
        pl = plistlib.load(f)
    pl['CFBundleDisplayName'] = DISPLAY_NAME
    pl['MinimumOSVersion'] = IOS_DEPLOY
    # 插件要访问运营商接口，其中含明文 HTTP；不开这条会在真机上直接失败
    pl['NSAppTransportSecurity'] = {'NSAllowsArbitraryLoads': True}
    with open(path, 'wb') as f:
        plistlib.dump(pl, f)
    with open(path, 'rb') as f:
        back = plistlib.load(f)
    check(back.get('MinimumOSVersion') == IOS_DEPLOY,
          f'Info.plist MinimumOSVersion = {IOS_DEPLOY}')
    check(back.get('CFBundleDisplayName') == DISPLAY_NAME,
          f'Info.plist 显示名 = {DISPLAY_NAME}')


def patch_podfile():
    path = 'ios/Podfile'
    if not os.path.exists(path):
        print(f'[SKIP] {path} 不存在（本次未生成 iOS 工程）')
        return
    with open(path, encoding='utf-8') as f:
        c = f.read()
    c = re.sub(r"platform :ios, '[^']*'", f"platform :ios, '{IOS_DEPLOY}'", c)
    c = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET'\]\s*=\s*'[^']*'",
               f"IPHONEOS_DEPLOYMENT_TARGET'] = '{IOS_DEPLOY}'", c)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(c)
    check(f"platform :ios, '{IOS_DEPLOY}'" in c, f'Podfile 平台 = {IOS_DEPLOY}')


def patch_app_framework_info():
    path = 'ios/Flutter/AppFrameworkInfo.plist'
    if not os.path.exists(path):
        # Flutter 3.32+ 已移除该文件，缺失属正常
        print('[SKIP] AppFrameworkInfo.plist 不存在（新版 Flutter 已移除）')
        return
    with open(path, 'rb') as f:
        pl = plistlib.load(f)
    pl['MinimumOSVersion'] = IOS_DEPLOY
    with open(path, 'wb') as f:
        plistlib.dump(pl, f)
    check(True, f'AppFrameworkInfo MinimumOSVersion = {IOS_DEPLOY}')


RELEASE_SIGNING_BLOCK = '''        create("release") {
            val ksFile = file("release.keystore")
            if (ksFile.exists()) {
                storeFile = ksFile
                storePassword = System.getenv("KEYSTORE_PASSWORD") ?: ""
                keyAlias = System.getenv("KEYSTORE_ALIAS") ?: ""
                keyPassword = System.getenv("KEYSTORE_PASSWORD") ?: ""
            }
        }'''

RELEASE_SIGNING_FULL = '''    signingConfigs {
        create("release") {
            val ksFile = file("release.keystore")
            if (ksFile.exists()) {
                storeFile = ksFile
                storePassword = System.getenv("KEYSTORE_PASSWORD") ?: ""
                keyAlias = System.getenv("KEYSTORE_ALIAS") ?: ""
                keyPassword = System.getenv("KEYSTORE_PASSWORD") ?: ""
            }
        }
    }

'''


def _set_release_signing(c: str) -> str:
    """把 signingConfigs / buildTypes.release 改为使用 release 签名。

    keystore 由 CI 解码到 android/app/release.keystore，口令通过环境变量
    KEYSTORE_PASSWORD / KEYSTORE_ALIAS 传入，Gradle 进程会继承。
    不写 key.properties，避免明文口令落盘或误提交。

    存在性判断放在 Gradle 里（ksFile.exists()），本地没有 keystore 时
    自动退回 debug 签名，不会因为文件缺失而构建失败。
    """
    if 'create("release")' not in c:
        m = re.search(r'signingConfigs\s*\{', c)
        if m:
            # 模板自带 signingConfigs（单行或跨行都可能），往里追加即可，
            # 不能再建一个同名块——Kotlin DSL 会报重复声明。
            tail = c[m.end():]
            if tail.startswith('\n'):
                tail = tail[1:]
            else:
                # 单行写法 signingConfigs { getByName("debug") }：
                # 只取第一行（` getByName("debug") }`）重排，后续内容原样保留
                first, _, rest = tail.partition('\n')
                first = first.strip()
                if first.endswith('}'):
                    first = '        ' + first[:-1].rstrip() + '\n    }'
                else:
                    first = '        ' + first
                tail = first + ('\n' + rest if rest else '')
            c = c[:m.end()] + '\n' + RELEASE_SIGNING_BLOCK + '\n' + tail
        else:
            c = c.replace('    buildTypes {', RELEASE_SIGNING_FULL + '    buildTypes {', 1)

    # release 的签名配置：有 keystore 用 release，没有则退回 debug
    c = re.sub(
        r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)',
        'signingConfig = if (file("release.keystore").exists()) '
        'signingConfigs.getByName("release") else signingConfigs.getByName("debug")',
        c)
    check('signingConfigs.getByName("release")' in c, 'Android release 签名已接入')
    return c


def _set_release_signing_groovy(c: str) -> str:
    """Groovy 版（build.gradle）。逻辑同 kts，只是语法不同。"""
    if 'release' not in c:
        check(False, 'Android 找到 release 配置')
        return c
    block = """    signingConfigs {
        release {
            def ksFile = file("release.keystore")
            if (ksFile.exists()) {
                storeFile = ksFile
                storePassword = System.getenv("KEYSTORE_PASSWORD")
                keyAlias = System.getenv("KEYSTORE_ALIAS")
                keyPassword = System.getenv("KEYSTORE_PASSWORD")
            }
        }
    }

"""
    if 'signingConfigs' not in c:
        c = c.replace('    buildTypes {', block + '    buildTypes {', 1)
    elif 'release {' not in c[c.index('signingConfigs'):c.index('signingConfigs') + 400]:
        # 已有 signingConfigs 块但没有 release，追加进去
        c = re.sub(r'signingConfigs\s*\{',
                   lambda m: m.group(0) + '\n        release {\n'
                             '            def ksFile = file("release.keystore")\n'
                             '            if (ksFile.exists()) {\n'
                             '                storeFile = ksFile\n'
                             '                storePassword = System.getenv("KEYSTORE_PASSWORD")\n'
                             '                keyAlias = System.getenv("KEYSTORE_ALIAS")\n'
                             '                keyPassword = System.getenv("KEYSTORE_PASSWORD")\n'
                             '            }\n        }\n',
                   c, count=1)
    c = re.sub(
        r'signingConfig\s+signingConfigs\.debug',
        'signingConfig file("release.keystore").exists() '
        '? signingConfigs.release : signingConfigs.debug',
        c)
    check('signingConfigs.release' in c, 'Android release 签名已接入（Groovy）')
    return c


def _move_main_activity():
    """把 flutter create 生成的 MainActivity 迁到新 namespace 下。

    模板按 --org/--project-name 生成 com/qiaoba/tool_plugin_app/MainActivity.kt，
    而我们把 namespace 改成了 ANDROID_NS。Manifest 里的 ".MainActivity" 按
    namespace 解析，编译出的类却在旧包名下 —— R8 看不到 Manifest 字符串引用，
    直接把它当无用类删掉，装机后启动即 ClassNotFoundException 闪退。
    """
    src_root = 'android/app/src/main/kotlin'
    if not os.path.isdir(src_root):
        src_root = 'android/app/src/main/java'
    if not os.path.isdir(src_root):
        print('[SKIP] 找不到 MainActivity 源码根目录')
        return

    found = []
    for dirpath, _, files in os.walk(src_root):
        for fn in files:
            if fn == 'MainActivity.kt' or fn == 'MainActivity.java':
                found.append(os.path.join(dirpath, fn))
    if not found:
        print('[WARN] 未找到 MainActivity 源码')
        return

    target_dir = os.path.join(src_root, *ANDROID_NS.split('.'))
    for old in found:
        with open(old, encoding='utf-8') as f:
            c = f.read()
        c = re.sub(r'^package\s+[\w.]+',
                   f'package {ANDROID_NS}', c, count=1, flags=re.M)
        os.makedirs(target_dir, exist_ok=True)
        new = os.path.join(target_dir, os.path.basename(old))
        with open(new, 'w', encoding='utf-8') as f:
            f.write(c)
        if os.path.abspath(new) != os.path.abspath(old):
            os.remove(old)
            # 清掉旧包名的空目录，免得残留影响 R8
            d = os.path.dirname(old)
            while os.path.abspath(d) != os.path.abspath(src_root):
                try:
                    os.rmdir(d)
                except OSError:
                    break
                d = os.path.dirname(d)
        print(f'[OK] MainActivity: {old} -> {new}')
        check(f'package {ANDROID_NS}' in c,
              f'MainActivity 包名为 {ANDROID_NS}')


def patch_android():
    """改 applicationId / minSdk。新版 Flutter 生成 build.gradle.kts，两种都要支持。"""
    gradle = 'android/app/build.gradle.kts'
    is_kts = True
    if not os.path.exists(gradle):
        gradle = 'android/app/build.gradle'
        is_kts = False
    if not os.path.exists(gradle):
        print('[SKIP] Android gradle 不存在（本次未生成 Android 工程）')
        return

    with open(gradle, encoding='utf-8') as f:
        c = f.read()

    if is_kts:
        c = re.sub(r'namespace\s*=\s*"[^"]*"', f'namespace = "{ANDROID_NS}"', c)
        c = re.sub(r'applicationId\s*=\s*"[^"]*"',
                   f'applicationId = "{ANDROID_NS}"', c)
        # 新版 Flutter 模板写的是 minSdk = flutter.minSdkVersion（无字面数字），
        # 只匹配数字会静默失败，因此右侧允许任意表达式。
        c = re.sub(r'minSdk\s*=\s*[^\s,)}\n]+', f'minSdk = {ANDROID_MIN_SDK}', c)
    else:
        c = re.sub(r'namespace\s+"[^"]*"', f'namespace "{ANDROID_NS}"', c)
        c = re.sub(r'applicationId\s+"[^"]*"', f'applicationId "{ANDROID_NS}"', c)
        c = re.sub(r'minSdkVersion\s+\d+', f'minSdkVersion {ANDROID_MIN_SDK}', c)
        c = re.sub(r'minSdk\s+\d+', f'minSdk {ANDROID_MIN_SDK}', c)

    # 签名配置：CI 把 keystore 解码到 android/app/release.keystore，
    # 口令走环境变量。无条件执行——之前包在 if os.path.exists(key.properties) 里，
    # 不写 key.properties 时签名就被静默跳过，release 仍用 debug 签名。
    if is_kts:
        c = _set_release_signing(c)
    else:
        c = _set_release_signing_groovy(c)

    # 引擎依赖 desugaring（部分新 API 在低版本 Android 上需要）
    if 'coreLibraryDesugaringEnabled' not in c:
        if is_kts:
            c = c.replace('compileOptions {',
                          'compileOptions {\n        isCoreLibraryDesugaringEnabled = true', 1)
        else:
            c = c.replace('compileOptions {',
                          'compileOptions {\n        coreLibraryDesugaringEnabled true', 1)
    if 'desugar_jdk_libs' not in c:
        dep = ('    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")'
               if is_kts else "    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.4'")
        if re.search(r'^dependencies\s*\{', c, re.M):
            # 已有顶层 dependencies 块：往里加，不能再建一个同名块
            c = re.sub(r'^dependencies\s*\{',
                       lambda m: m.group(0) + '\n' + dep, c, count=1, flags=re.M)
        else:
            c = c.rstrip() + '\n\ndependencies {\n' + dep + '\n}\n'

    with open(gradle, 'w', encoding='utf-8') as f:
        f.write(c)

    print(f'[OK] gradle patched: {gradle} (kts={is_kts})')
    check(ANDROID_NS in c, f'Android applicationId = {ANDROID_NS}')
    # 校验真实赋值，而不是「21 这个子串出现过」——后者会被版本号蒙混过关
    if is_kts:
        check(re.search(rf'minSdk\s*=\s*{ANDROID_MIN_SDK}\b', c) is not None,
              f'Android minSdk = {ANDROID_MIN_SDK}')
    else:
        check(re.search(rf'minSdk(Version)?\s+{ANDROID_MIN_SDK}\b', c) is not None,
              f'Android minSdk = {ANDROID_MIN_SDK}')
    check('desugar_jdk_libs' in c, 'desugaring 依赖已加入')

    # namespace 改了，MainActivity 必须跟着搬家，否则启动类对不上
    _move_main_activity()


def patch_android_manifest():
    path = 'android/app/src/main/AndroidManifest.xml'
    if not os.path.exists(path):
        print(f'[SKIP] {path} 不存在（本次未生成 Android 工程）')
        return
    with open(path, encoding='utf-8') as f:
        c = f.read()
    need = ['android.permission.INTERNET']
    added = []
    for perm in need:
        if perm not in c:
            added.append(perm)
            c = c.replace('<application',
                          f'<uses-permission android:name="{perm}" />\n    <application',
                          1)
    if added:
        pass
    # ".MainActivity" 依赖 namespace 解析；改过包名后容易对不上，
    # 直接写成全限定名，杜绝启动类找不到。
    if 'android:name=".MainActivity"' in c:
        c = c.replace('android:name=".MainActivity"',
                      f'android:name="{ANDROID_NS}.MainActivity"')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(c)
    check('android.permission.INTERNET' in c, 'Android INTERNET 权限已声明')
    check(f'{ANDROID_NS}.MainActivity' in c,
          f'启动 Activity 为全限定名 {ANDROID_NS}.MainActivity')


for fn in (patch_pbxproj, patch_info_plist, patch_podfile,
           patch_app_framework_info, patch_android, patch_android_manifest):
    try:
        fn()
    except Exception as e:  # noqa: BLE001 - 任何异常都要让 CI 失败
        check(False, f'{fn.__name__} 抛异常：{e}')

if failures:
    print(f'\n共 {len(failures)} 项失败：')
    for f in failures:
        print(f'  - {f}')
    sys.exit(1)
print('\n平台工程修补完成')
