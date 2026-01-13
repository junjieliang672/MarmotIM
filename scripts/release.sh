#!/bin/bash
# Release build script - creates distributable package
#
# Usage:
#   bash scripts/release.sh              # Build with iCloud (requires Apple Developer account)
#   bash scripts/release.sh --no-icloud  # Build without iCloud (no developer account needed)

set -e
cd "$(dirname "$0")/.."

# Parse arguments
NO_ICLOUD=false
for arg in "$@"; do
    case $arg in
        --no-icloud)
            NO_ICLOUD=true
            shift
            ;;
    esac
done

VERSION=$(grep -A1 "CFBundleShortVersionString" MarmotIM/Info.plist | grep string | sed 's/.*<string>\(.*\)<\/string>/\1/' | tr -d '\t')
BUILD=$(grep -A1 "CFBundleVersion" MarmotIM/Info.plist | grep string | sed 's/.*<string>\(.*\)<\/string>/\1/' | tr -d '\t')

echo "Building MarmotIM v${VERSION} (Build ${BUILD})..."
if [ "$NO_ICLOUD" = true ]; then
    echo "Mode: No iCloud (ad-hoc signing)"
else
    echo "Mode: With iCloud (requires Apple Developer account)"
fi
echo ""

# Clean previous build
rm -rf build/
rm -rf release/

# Build Release version
if [ "$NO_ICLOUD" = true ]; then
    # Build without iCloud entitlements
    xcodebuild -project MarmotIM.xcodeproj \
        -scheme MarmotIM \
        -configuration Release \
        build \
        CONFIGURATION_BUILD_DIR="$(pwd)/build" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_ENTITLEMENTS="" \
        2>&1 | grep -E "(error:|warning:|BUILD)" | tail -10
else
    # Build with iCloud
    xcodebuild -project MarmotIM.xcodeproj \
        -scheme MarmotIM \
        -configuration Release \
        build \
        CONFIGURATION_BUILD_DIR="$(pwd)/build" \
        2>&1 | grep -E "(error:|warning:|BUILD)" | tail -10
fi

if [ ! -d "build/MarmotIM.app" ]; then
    echo "Build failed!"
    if [ "$NO_ICLOUD" = false ]; then
        echo ""
        echo "Hint: If you don't have an Apple Developer account, try:"
        echo "  bash scripts/release.sh --no-icloud"
    fi
    exit 1
fi

echo "Build succeeded!"

# Create release directory
mkdir -p release

# Copy app and install script
cp -r build/MarmotIM.app release/
cp scripts/install.sh release/

# Create README for the release
if [ "$NO_ICLOUD" = true ]; then
    ICLOUD_NOTE="注意：此版本不包含 iCloud 同步功能。
      如需 iCloud 同步，请使用 Apple Developer 账号自行构建。

"
else
    ICLOUD_NOTE=""
fi

cat > release/README.txt << RELEASE_EOF
土拨鼠输入法 (MarmotIM) 安装说明
================================
${ICLOUD_NOTE}
第一步：安装应用
--------------
方法一：运行安装脚本（推荐）
1. 打开终端 (Terminal)
2. cd 到此目录
3. 运行: bash install.sh
4. 输入密码完成安装

方法二：手动安装
1. 移除安全限制：
   xattr -cr MarmotIM.app

2. 将 MarmotIM.app 复制到 /Library/Input Methods/：
   sudo cp -r MarmotIM.app /Library/Input\ Methods/

3. 如果提示没有执行权限，运行：
   sudo chmod +x /Library/Input\ Methods/MarmotIM.app/Contents/MacOS/MarmotIM

4. 注销并重新登录

5. 打开「系统设置 → 键盘 → 输入源」
   点击「+」添加「土拨鼠输入法」

第二步：构建词库（必须）
--------------------
输入法需要词库才能正常工作。请按以下步骤构建：

1. 安装 Python 3.8+（如未安装）

2. 克隆或下载源码：
   git clone https://github.com/junjieliang672/MarmotIM.git
   cd MarmotIM

3. 运行词库构建脚本：
   python3 tools/build_dictionary.py \\
       --pinyin vocab/py_table.txt \\
       --wubi vocab/wb_table.txt \\
       --extra-pinyin-dir vocab \\
       --output dict \\
       --skip-json \\
       --install

4. 词库会自动安装到 ~/Library/Application Support/MarmotIM/

构建完成后即可正常使用输入法。

卸载方法
-------
删除 /Library/Input Methods/MarmotIM.app
删除 ~/Library/Application Support/MarmotIM/ (可选，保留用户数据)

RELEASE_EOF

# Create zip package with appropriate suffix
if [ "$NO_ICLOUD" = true ]; then
    ZIP_NAME="MarmotIM-v${VERSION}-no-icloud.zip"
else
    ZIP_NAME="MarmotIM-v${VERSION}.zip"
fi

cd release
zip -r "$ZIP_NAME" MarmotIM.app install.sh README.txt
cd ..

# Move zip to project root
mv "release/$ZIP_NAME" ./

echo ""
echo "=========================================="
echo "Release package created: $ZIP_NAME"
echo "=========================================="
echo ""
echo "Contents:"
unzip -l "$ZIP_NAME"
echo ""
if [ "$NO_ICLOUD" = true ]; then
    echo "Note: This build does NOT include iCloud sync."
    echo ""
fi
echo "To create a GitHub release:"
echo "  1. git tag v${VERSION}"
echo "  2. git push origin v${VERSION}"
echo "  3. Upload $ZIP_NAME to GitHub Releases"
