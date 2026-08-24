# WCVoiceClone — 微信语音克隆插件（iOS 越狱）

在越狱 iPhone 的微信里，用 [Fish Audio](https://fish.audio) 克隆的声音发送语音消息。
架构与 WCRefine 同类：**Theos + MobileSubstrate dylib 注入微信**。

## 功能

- 聊天窗口右侧悬浮 🎤 按钮
  - **🎤 输入文字 → 用克隆声音合成 → 直接以语音消息发出**
  - 🧪 测试 Fish Audio 连接（查余额）
  - ⚙️ 设置 API Key / 声音模型 ID（存在本地 CFPreferences）
  - 🐞 调试探测：列出当前微信版本的语音消息相关方法名并复制到剪贴板，方便适配
- 内置 SILK v3 编码器（微信语音格式），mp3 自动转码后发送
- 多版本兼容的发送逻辑（自动尝试多个候选 API），适配微信 8.0.x

## 目录结构

```
wcvoiceclone/
├── Makefile               # Theos 构建（含 silk C 源码编译）
├── control                # deb 包信息
├── WCVoiceClone.plist     # 注入过滤器：只注入 com.tencent.xin
├── Tweak.x                # Logos hook 主逻辑
└── src/
    ├── FAVoiceAPI.h/.m    # Fish Audio 客户端 (TTS / 克隆 / 余额)
    ├── PrefsManager.h/.m  # 配置读写
    ├── SilkBridge.h/.m    # mp3 → PCM(24kHz) → SILK 转码
    └── silk/              # SILK v3 编解码源码（来自 kn007/silk-v3-decoder）
```

## 构建步骤（需要一台 Mac 或 Linux 电脑）

### 1. 安装 Theos

```bash
brew install ldid xz    # Mac；Linux 用 apt 装 ldid
git clone --recursive https://github.com/theos/theos.git ~/theos
export THEOS=~/theos
```

### 2. 把本项目拷到电脑上

```bash
# 从手机上把这个目录拷走（scp / AirDrop / 文件 App 均可）
```

### 3. 编译打包

```bash
cd wcvoiceclone
make package FINALVERSION=1
# 生成 packages/com.local.wcvoiceclone_0.1.0_iphoneos-arm.deb
```

### 4. 安装到手机

```bash
# 手机需开启 OpenSSH（有根越狱，root 密码默认 alpine）
scp packages/*.deb root@<手机IP>:/var/root/
ssh root@<手机IP> "dpkg -i /var/root/com.local.wcvoiceclone*.deb"
# 然后杀掉微信重开（或注销）
```

也可以把 deb 丢进 Cydia/Sileo 本地源安装。

## 使用流程

1. **先克隆声音**（二选一）：
   - 网页：https://fish.audio/zh-CN/app/my-voices/ 上传一段干净人声（10s~5min）
   - 或用配套命令行工具 `../fish-voice-wechat/cli.py clone`
2. 拿到声音模型 ID（形如 `672a5f1cxxxxxxxx`）
3. 微信里随便打开一个聊天 → 点 🎤 → ⚙️ 设置：
   - 填 API Key（fish.audio 后台 → API 页面生成）
   - 填声音模型 ID
4. 🧪 测试连接 → 显示余额即成功
5. 🎤 输入文字 → 发送 → 对方收到你的克隆声音语音 🎉

## 版本适配说明

微信每个大版本的消息接口可能变化。若发送失败：

1. 点悬浮球 → 🐞调试 → 会列出当前版本 `CMessageMgr` / `CMessageWrap` 里所有 voice/msg/local 相关方法
2. 把真实的方法名补进 `Tweak.x` 里 `WCVTrySendVoice` 的 `candidates` 数组即可

## 风险提示

- 使用插件属于修改微信客户端行为，**违反微信用户协议，有小概率封号风险**，建议小号测试
- 仅限个人自用，请勿分发或用于冒充他人等违法用途（克隆声音须为你本人授权的声音）
- API Key 存在本机偏好里，注意设备安全
