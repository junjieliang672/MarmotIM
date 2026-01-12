#!/bin/bash
# Create DMG installer for MarmotIM
# Usage: ./scripts/create-dmg.sh [version]
#
# This script creates a DMG file containing:
# - MarmotIM.app
# - install.sh
# - README.txt

set -e

# Get version from argument or extract from Info.plist
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION=$(grep -A1 "CFBundleShortVersionString" MarmotIM/Info.plist | grep string | sed 's/.*<string>\(.*\)<\/string>/\1/' | tr -d '\t')
fi

echo "Creating DMG for MarmotIM v${VERSION}..."

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/Release"
DIST_DIR="$PROJECT_DIR/dist"
DMG_NAME="MarmotIM-v${VERSION}.dmg"
VOLUME_NAME="MarmotIM v${VERSION}"
STAGING_DIR="$PROJECT_DIR/build/dmg-staging"

# Check if app exists
APP_PATH="$BUILD_DIR/MarmotIM.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: MarmotIM.app not found at $APP_PATH"
    echo "Please run build first."
    exit 1
fi

# Clean up
rm -rf "$STAGING_DIR"
rm -rf "$DIST_DIR"
mkdir -p "$STAGING_DIR"
mkdir -p "$DIST_DIR"

echo "Preparing DMG contents..."

# Copy app
cp -R "$APP_PATH" "$STAGING_DIR/"

# Create install script
cat > "$STAGING_DIR/install.sh" << 'INSTALL_EOF'
#!/bin/bash
# MarmotIM Install Script - No Xcode required
# Usage: bash install.sh

set -e
cd "$(dirname "$0")"

echo "=================================="
echo "  土拨鼠输入法 (MarmotIM) 安装程序"
echo "=================================="
echo ""

# Check if MarmotIM.app exists
if [ ! -d "MarmotIM.app" ]; then
    echo "错误: 找不到 MarmotIM.app"
    echo "请确保此脚本与 MarmotIM.app 在同一目录下"
    exit 1
fi

# Remove quarantine attribute (macOS security)
echo "正在移除安全限制..."
xattr -cr MarmotIM.app 2>/dev/null || true

# Ensure executable has correct permissions
chmod +x MarmotIM.app/Contents/MacOS/MarmotIM

# Stop existing process if running
echo "正在停止旧版本..."
if pgrep -f MarmotIM > /dev/null 2>&1; then
    killall -TERM MarmotIM 2>/dev/null || true
    sleep 1
    if pgrep -f MarmotIM > /dev/null 2>&1; then
        killall -KILL MarmotIM 2>/dev/null || true
        sleep 0.5
    fi
fi

# Install to /Library/Input Methods/
echo "正在安装到 /Library/Input Methods/ ..."
echo "(需要输入管理员密码)"
sudo rm -rf "/Library/Input Methods/MarmotIM.app"
sudo cp -r MarmotIM.app "/Library/Input Methods/"
sudo chmod +x "/Library/Input Methods/MarmotIM.app/Contents/MacOS/MarmotIM"
sudo codesign --force --deep --sign - "/Library/Input Methods/MarmotIM.app"

# Check if dictionary exists
DICT_PATH="$HOME/Library/Application Support/MarmotIM/dictionary.db"
if [ ! -f "$DICT_PATH" ]; then
    echo ""
    echo "⚠️  警告: 未找到词库文件"
    echo "   输入法需要词库才能正常工作。"
    echo "   请参考 README.txt 中的「构建词库」部分。"
    echo ""
fi

# Start the input method
echo "正在启动输入法..."
open "/Library/Input Methods/MarmotIM.app"

echo ""
echo "=================================="
echo "  安装完成！"
echo "=================================="
echo ""
echo "下一步："
echo "  1. 打开「系统设置 → 键盘 → 输入源」"
echo "  2. 点击「+」添加「土拨鼠输入法」(在中文分类下)"
echo "  3. 从菜单栏选择土拨鼠输入法开始使用"
echo ""
echo "如果输入法没有出现在列表中，请注销并重新登录。"
echo ""
echo "如果输入法无法输入中文，请先构建词库（见 README.txt）。"
INSTALL_EOF

chmod +x "$STAGING_DIR/install.sh"

# Create README
cat > "$STAGING_DIR/README.txt" << 'README_EOF'
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
README_EOF

echo "Creating DMG..."

# Create DMG using hdiutil
hdiutil create -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov -format UDZO \
    "$DIST_DIR/$DMG_NAME"

# Clean up staging
rm -rf "$STAGING_DIR"

echo ""
echo "=========================================="
echo "DMG created: dist/$DMG_NAME"
echo "=========================================="
ls -lh "$DIST_DIR/$DMG_NAME"
