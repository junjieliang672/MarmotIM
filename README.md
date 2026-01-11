# MarmotIM - 土拨鼠输入法

macOS 平台的高性能统一智能输入法。**核心理念：不区分五笔或拼音，一切以词库为准**。

## 特性

- **统一编码空间** - 五笔码和拼音码共存于同一索引，无需切换模式
- **Frecency 智能排序** - 基于使用频率 + 最近使用的综合评分
- **前缀快速匹配** - 无歧义时可用最短前缀快速输入
- **用户自适应** - 持续学习用户习惯，动态调整排序
- **划词入库** - Control+= 快速添加选中文字到用户词库
- **数据库导入导出** - 支持备份和迁移用户数据

## 安装

### 前置要求
- macOS 13.0+
- Xcode 15.0+
- Python 3.8+ (用于构建词库)

### 安装步骤

```bash
# 1. 克隆仓库
git clone https://github.com/marmotim/MarmotIM.git
cd MarmotIM

# 2. 构建词库
python3 tools/build_dictionary.py \
    --pinyin vocab/py_table.txt \
    --wubi vocab/wb_table.txt \
    --extra-pinyin-dir vocab \
    --output dict \
    --skip-json \
    --install

# 3. 构建并安装（需要输入密码）
./scripts/build.sh
```

安装完成后：
1. 打开「系统设置 → 键盘 → 输入源」
2. 点击「+」添加「土拨鼠输入法」(在中文分类下)
3. 从菜单栏选择土拨鼠输入法开始使用

如果输入法没有出现在列表中，请注销并重新登录。

### 快速更新（开发用）

```bash
# 无需注销的快速更新
./scripts/quick_update.sh
```

## 使用方法

### 基本操作

| 操作 | 按键 |
|------|------|
| 输入编码 | 直接输入拼音或五笔码 |
| 选择第一个候选 | 空格 |
| 选择候选 | 数字键 1-9 |
| 翻页 | [ 和 ] 或 - 和 = |
| 取消输入 | Escape |
| 删除编码 | Backspace |
| 中英文切换 | Shift |

### 高级功能

| 功能 | 按键 | 说明 |
|------|------|------|
| 划词入库 | Control+= | 将选中的文字添加到用户词库 |
| 划词删除 | Control+- | 将选中的文字从用户词库删除 |

### 设置

点击菜单栏的输入法图标，选择「设置...」打开设置窗口。

- **基本设置** - 候选词数量、编码提示等
- **用户词库** - 管理用户添加的词条
- **标点符号** - 自定义标点映射
- **主题** - 候选窗口外观
- **导入导出** - 数据库备份与恢复

## 配置文件

配置文件位于 `~/Library/Application Support/MarmotIM/config.json`：

```json
{
  "enableAutoCommit": false,
  "showCodeHint": true,
  "candidateCount": 5,
  "frecencyMaxScore": 10000,
  "frecencyAgingFactor": 0.9,
  "theme": "system"
}
```

数据库文件位于 `~/Library/Application Support/MarmotIM/dictionary.db`

## 项目结构

```
MarmotIM/
├── MarmotIM/               # 主应用源码
│   ├── main.swift           # 入口点
│   ├── AppDelegate.swift    # 应用代理
│   ├── InputController.swift # 输入控制器
│   ├── Dictionary/          # 词库引擎 (Trie + SQLite)
│   ├── Ranking/             # Frecency 排序
│   ├── Storage/             # 用户数据存储
│   ├── UI/                  # 候选窗口
│   ├── Settings/            # 设置界面
│   └── Config/              # 配置管理
├── vocab/                   # 词库源文件
│   ├── py_table.txt          # 拼音词库
│   ├── wb_table.txt          # 五笔词库
│   ├── cn_en_table.txt       # 中英混合词库
│   ├── en_table.txt          # 英文词库
│   └── emoji_table.txt       # Emoji 词库
├── tools/                   # 构建工具
│   ├── build_dictionary.py   # 词库构建脚本
│   └── generate_icon.py      # 图标生成
├── scripts/                 # 构建脚本
│   ├── build.sh              # 构建并安装
│   ├── quick_update.sh       # 快速更新（开发用）
│   └── clean_install.sh      # 全新安装（清理旧版本）
├── logo/                    # Logo 资源
└── .github/workflows/       # CI/CD
```

## 词库说明

### 词库优先级
1. **五笔词库** (wb_table.txt) - 简码优先，短码高权重
2. **拼音词库** (py_table.txt) - 按词频排序
3. **扩展词库** (cn_en, en, emoji) - 补充词条

### 自定义词库
可以在用户词库设置页面添加自定义词条，或使用 Control+= 快速添加。

## 技术栈

- **语言**: Swift 5.9+
- **UI**: SwiftUI + AppKit
- **输入框架**: InputMethodKit
- **词库索引**: SQLite + 内存 Trie
- **用户数据**: SQLite WAL 模式
- **排序算法**: Frecency

## 许可证

GPL-3.0 License

## 致谢

- [清歌输入法](https://qingg.im) - 词库来源和功能参考
- [zoxide](https://github.com/ajeetdsouza/zoxide) - Frecency 算法灵感
- [Rime](https://github.com/rime) - 开源输入法参考

### 词库来源

- [雾凇拼音](https://github.com/iDvel/rime-ice) - 长期维护的简体拼音词库
- [CustomPinyinDictionary](https://github.com/wuhgit/CustomPinyinDictionary) - 自定义拼音词库
