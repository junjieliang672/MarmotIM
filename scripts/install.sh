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
# ad-hoc 签名。这里**只能**这样，但代价必须写明（2026-08-13）：
#
#   · 发布包里的 app 是用开发证书构建的，那个证书在别人的机器上过不了 Gatekeeper，
#     所以这里重签成 ad-hoc。真正的解法是 Developer ID 证书 + 公证，目前没有。
#   · ad-hoc 会丢掉全部 entitlements，其中包括 com.apple.application-identifier ——
#     没有它 iCloud Drive 会直接拒绝这个进程，也就是说**通过发布包安装的用户，
#     iCloud 同步从来就没有工作过**。界面上看不出来：文件照常写进本地容器目录。
#   · ad-hoc 没有稳定身份，TCC 只能把授权钉在这次构建的 cdhash 上，所以麦克风、
#     辅助功能的授权在下次安装后就会失效（系统设置里还打着勾）。
#
# 想要同步和稳定授权，目前只有从源码装：bash scripts/build_and_install.sh
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
