#!/bin/bash
# Release build script - creates distributable package
# Usage: bash scripts/release.sh

set -e
cd "$(dirname "$0")/.."

VERSION=$(grep -A1 "CFBundleShortVersionString" MarmotIM/Info.plist | grep string | sed 's/.*<string>\(.*\)<\/string>/\1/' | tr -d '\t')
BUILD=$(grep -A1 "CFBundleVersion" MarmotIM/Info.plist | grep string | sed 's/.*<string>\(.*\)<\/string>/\1/' | tr -d '\t')

echo "Building MarmotIM v${VERSION} (Build ${BUILD})..."

# Clean previous build
rm -rf build/
rm -rf release/

# Build Release version
xcodebuild -project MarmotIM.xcodeproj \
    -scheme MarmotIM \
    -configuration Release \
    build \
    CONFIGURATION_BUILD_DIR="$(pwd)/build" \
    2>&1 | grep -E "(error:|warning:|BUILD)" | tail -10

if [ ! -d "build/MarmotIM.app" ]; then
    echo "Build failed!"
    exit 1
fi

echo "Build succeeded!"

# Create release directory
mkdir -p release

# Copy app and install script
cp -r build/MarmotIM.app release/
cp scripts/install.sh release/

# Create README for the release
cat > release/README.txt << 'RELEASE_EOF'
土拨鼠输入法 (MarmotIM) 安装说明
================================

第一步：安装应用
--------------
方法一：运行安装脚本（推荐）
1. 打开终端 (Terminal)
2. cd 到此目录
3. 运行: bash install.sh
4. 输入密码完成安装

方法二：手动安装
1. 将 MarmotIM.app 复制到 /Library/Input Methods/
2. 注销并重新登录
3. 打开「系统设置 → 键盘 → 输入源」
4. 点击「+」添加「土拨鼠输入法」

第二步：构建词库（必须）
--------------------
输入法需要词库才能正常工作。请按以下步骤构建：

1. 安装 Python 3.8+（如未安装）

2. 克隆或下载源码：
   git clone https://github.com/junjieliang672/MarmotIM.git
   cd MarmotIM

3. 运行词库构建脚本：
   python3 tools/build_dictionary.py \
       --pinyin vocab/py_table.txt \
       --wubi vocab/wb_table.txt \
       --extra-pinyin-dir vocab \
       --output dict \
       --skip-json \
       --install

4. 词库会自动安装到 ~/Library/Application Support/MarmotIM/

构建完成后即可正常使用输入法。

卸载方法
-------
删除 /Library/Input Methods/MarmotIM.app
删除 ~/Library/Application Support/MarmotIM/ (可选，保留用户数据)

RELEASE_EOF

# Create zip package
cd release
zip -r "MarmotIM-v${VERSION}.zip" MarmotIM.app install.sh README.txt
cd ..

# Move zip to project root
mv release/MarmotIM-v${VERSION}.zip ./

echo ""
echo "=========================================="
echo "Release package created: MarmotIM-v${VERSION}.zip"
echo "=========================================="
echo ""
echo "Contents:"
unzip -l "MarmotIM-v${VERSION}.zip"
echo ""
echo "To create a GitHub release:"
echo "  1. git tag v${VERSION}"
echo "  2. git push origin v${VERSION}"
echo "  3. Upload MarmotIM-v${VERSION}.zip to GitHub Releases"
