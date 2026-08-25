# 📦 项目封存说明（2026-08-25）

> 本项目暂停开发。重启条件：拿到微信 8.0.76 的 class-dump 头文件。
> 重启时把本文档喂给 AI 助手即可无缝继续。

## 当前状态

- **v0.3.0 已编译成功**（GitHub Actions 全自动），但**语音仍无法真正送达**
- 症状：本地气泡正常、入库正常、文件写入正常，但上传环节不生效
  （此前症状为“一直发送中”转圈；AddNewPart 登记后仍未解决）

## ✅ 已经跑通的部分

| 模块 | 状态 |
|---|---|
| 注入/悬浮球/UI | ✅ Dopamine 无根可用 |
| MMContext 服务入口探测 | ✅ 运行时自动发现 |
| Fish Audio TTS（含免费模型 s2.1-pro-free） | ✅ |
| SILK 编码（官方 SDK，sipdroid 版源码） | ✅ 本地+真机验证 |
| mp3→PCM→SILK 全流程 | ✅ |
| AddLocalMsg 入库拿 LocalID | ✅ |
| extendInfo(CExtendInfoOfVoiceMsg) 设置 | ✅ |
| XML 内容构造 | ✅ |

## ❌ 卡住的最后一环

**语音上传出网**。已尝试并失败：
- `AudioSender ResendVoiceMsg:MsgWrap:` → 调用成功但内部静默失败/无限转圈
- `MMNewUploadVoiceMgr AddNewPart:...` 队列登记 → 无效
- 推测根因：手动构造的消息缺少**合法的上传会话上下文**
  （原生录音会话由 SilkAudioRecorder/AudioSender 内部建立）

## 🔑 关键知识库（踩坑全记录）

### 微信 8.0.76 变化
- `+[MMServiceCenter defaultCenter]` **已被移除**（调用即崩）
  → 新入口疑似 `MMContext`，需头文件确认真实单例方法名
- 原生语音消息插入时的字段模板（真机捕获）：
```
m_uiMesLocalID = 5 (自动分配)
m_uiStatus = 1
m_uiDownloadStatus = 1
m_nsMsgSource = "" (空)
m_nsContent = <msg><voicemsg voicelength="0" voiceformat="4" forwardflag="0" /></msg>
m_dtVoice/m_uiVoiceTime/m_nTotalLen = nil (插入时不设置！后续DB更新)
extendInfo = CExtendInfoOfVoiceMsg 实例存在
```

### 发送管线（来自 iWeChat 6.6.1 头文件 + WCVoice 插件逆向）
```
录音分片回调 onSilkPart → MMNewUploadVoiceMgr AddNewPart:LocalID:n64SvrID:
  Offset:Len:VoiceTime:CreateTime:EndFlag:CancelFlag:VoiceFormat:ForwardFlag:msgSource:
结束 → PrepareForUpload(Ex) → TimerCheckUploadQueue → uploadOnePacket
音频数据来源：loadDataFromAudioFile: 从 getAudioFileName:LocalID: 路径读取
```

### 待验证假设（拿到头文件后第一件事）
1. 8.0.76 的 `AudioSender`/`MMNewUploadVoiceMgr` 方法签名是否变化
2. 是否存在新的统一发送入口（如 MessageService/MMSendMgr）
3. 上传是否要求先有 `StartRecordFrom:ToUser:` 建立的会话状态
   （2017 开源代码注释：“首次发送需要调用一个奇怪的函数”——CanStartRecordFrom 系列）
4. WCRefine 客户端的实际发送实现（闭源，勿逆向，仅参考其行为特征）

### 其他重要坑
- SILK 编码器：kn007/silk-v3-decoder 的编码器源码**有缺陷会段错误**，
  必须用 sipdroid 内置的官方 SDK（已 vendored 在 src/silk/）
- clang -Werror 下老 C 代码需加：
  `-Wno-shift-negative-value -Wno-constant-conversion -Wno-sometimes-uninitialized`
- Logos %hook 类需手动声明 @interface 及所有 %new 方法
- `@catch (_)` 不合法，必须 `@catch (NSException *e)`
- iOS 禁用 `system()`，用 POSIX chmod/chown
- voicelength 单位：文档说法是秒，原生模板插值是 0——需头文件确认

## 📁 相关资产

- GitHub 仓库：Nanmai333/wc-voiceclone（CI 自动编译，命名规范）
- Python 测试工具：workspace/fish-voice-wechat/（克隆声音/TTS 可独立使用 ✓）
- 参考仓库：
  - lefex/iWeChat（6.6.1 头文件）
  - yangzhenglun/hookPro（旧版发送实现）
  - Wkkyy00.github.io（WCVoice 语音包插件 deb）
  - plumblossom26/WCRefine-VoiceGateway/VoiceHub（服务端架构参考）

## 🔄 重启清单

1. 提供 8.0.76 class-dump 头文件
2. 对照确认：服务中心入口 / AudioSender / MMNewUploadVoiceMgr / 新发送管理器签名
3. 用真实签名重写 WCVTrySendVoice 四步流程
4. CI 会自动出新包（命名：WCVoiceClone_版本_iphoneos-arm64.deb）
