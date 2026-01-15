# iCloud 同步配置指南

本文档说明如何为土拨鼠输入法配置 iCloud 同步功能。

## 前置条件

1. **Apple Developer Program 会员资格**（$99/年）
   - iCloud 容器需要开发者账号才能创建和使用
   - 访问 [developer.apple.com](https://developer.apple.com) 注册

2. **Xcode 15.0 或更高版本**

3. **macOS 13.0 或更高版本**

## 配置步骤

### 1. 登录 Apple Developer 账号

1. 打开 Xcode
2. 进入 **Xcode → Settings → Accounts**
3. 点击左下角 **"+"** 按钮
4. 选择 **Apple ID** 并登录你的开发者账号

### 2. 配置项目签名

1. 在 Xcode 中打开 `MarmotIM.xcodeproj`
2. 在左侧导航栏选择项目文件
3. 选择 **MarmotIM** target
4. 进入 **Signing & Capabilities** 标签页
5. 勾选 **Automatically manage signing**
6. 在 **Team** 下拉菜单中选择你的开发者团队

### 3. 添加 iCloud 功能

1. 在 **Signing & Capabilities** 标签页
2. 点击 **"+ Capability"** 按钮
3. 搜索并添加 **"iCloud"**
4. 在 iCloud 配置区域：
   - 勾选 **iCloud Documents**
   - 在 **Containers** 部分，点击 **"+"**
   - 添加容器标识符：`iCloud.com.marmotim.inputmethod.MarmotIM`

### 4. 验证配置

构建项目以验证配置是否正确：

```bash
xcodebuild -scheme MarmotIM -configuration Debug build
```

如果构建成功，说明 iCloud 配置完成。

### 5. 验证 Entitlements

检查构建后的应用是否包含正确的 entitlements：

```bash
codesign -d --entitlements - /path/to/MarmotIM.app
```

应该能看到以下内容：
```
com.apple.developer.icloud-container-identifiers
    iCloud.com.marmotim.inputmethod.MarmotIM
com.apple.developer.ubiquity-container-identifiers
    iCloud.com.marmotim.inputmethod.MarmotIM
```

## 配置文件说明

### MarmotIM.entitlements

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.marmotim.inputmethod.MarmotIM</string>
    </array>
    <key>com.apple.developer.ubiquity-container-identifiers</key>
    <array>
        <string>iCloud.com.marmotim.inputmethod.MarmotIM</string>
    </array>
</dict>
</plist>
```

### Info.plist 中的 iCloud 配置

```xml
<key>NSUbiquitousContainers</key>
<dict>
    <key>iCloud.com.marmotim.inputmethod.MarmotIM</key>
    <dict>
        <key>NSUbiquitousContainerIsDocumentScopePublic</key>
        <true/>
        <key>NSUbiquitousContainerName</key>
        <string>MarmotIM</string>
        <key>NSUbiquitousContainerSupportedFolderLevels</key>
        <string>None</string>
    </dict>
</dict>
```

## 同步机制

### 同步的数据

| 数据表 | 文件名 | 冲突解决策略 |
|--------|--------|--------------|
| user_learning | user_learning.json | 保留 accessCount 更大的记录 |
| user_favorites | user_favorites.json | 保留 addedTimestamp 更新的记录 |
| filter_user_freq | filter_user_freq.json | 保留 frequency 更大的记录 |

### 同步触发时机

1. **定时同步**：每 30 分钟自动同步一次
2. **文件变更**：检测到 iCloud 文件变更时自动下载并合并
3. **手动同步**：在输入法菜单中点击"立即同步"

### 同步状态查看

在输入法菜单的"土拨鼠输入法"部分可以看到：
- 上次同步时间
- 同步状态（成功/失败）
- 手动同步按钮

## 数据存储位置

### 本地数据
```
~/Library/Application Support/MarmotIM/
└── dictionary.db          # 主词库数据库（包含词条、索引、用户学习数据）
```

### iCloud 数据
```
~/Library/Mobile Documents/iCloud~com~marmotim~inputmethod~MarmotIM/Documents/
├── user_learning.json     # 学习记录
├── user_favorites.json    # 收藏词条
└── filter_user_freq.json  # 过滤模式使用频率
```

## 故障排除

### 同步不工作

1. **检查 iCloud 登录状态**
   - 打开系统设置 → Apple ID → iCloud
   - 确保已登录并启用 iCloud Drive

2. **检查网络连接**
   - 确保设备已连接到互联网

3. **检查容器权限**
   - 在 Apple Developer 后台确认容器已创建
   - 确保 App ID 已关联该容器

4. **查看日志**
   ```bash
   log show --predicate 'subsystem == "com.marmotim.inputmethod.MarmotIM"' --last 1h
   ```

### 数据冲突

同步采用"记录级别最新写入优先"策略：
- 不会丢失任何一方的数据
- 对于同一条记录，保留数值更大的版本
- 冲突解决完全自动，无需用户干预

### 重置同步

如需重置同步状态：

1. 删除 iCloud 中的同步文件：
   ```bash
   rm -rf ~/Library/Mobile\ Documents/iCloud~com~marmotim~inputmethod~MarmotIM/Documents/*.json
   ```

2. 重启输入法，将重新上传本地数据

## 多设备同步

1. 在所有设备上使用相同的 Apple ID 登录 iCloud
2. 在所有设备上安装土拨鼠输入法
3. 确保所有设备的 iCloud Drive 已启用
4. 同步将自动在设备间进行

## 隐私说明

- 所有同步数据存储在用户自己的 iCloud 账户中
- 数据传输使用 Apple 的端到端加密
- 开发者无法访问用户的同步数据
- 用户可随时在 iCloud Drive 中删除同步数据
