# MarmotIMTests/Fixtures

测试资源目录，由 `Package.swift` 的 `resources: [.copy("Fixtures")]` 整目录拷进测试 bundle，
用 `Bundle.module.url(forResource: "Fixtures", withExtension: nil)` 取到。

本 README 同时让这个目录在 git 里可见：声明的 resource 路径不存在时 SwiftPM 会直接报错。

---

## 待录制：转写端到端 fixture（人工环节）

`TranscribeE2ETests` 已经写好并在跑，但它的两条真链路用例目前**跳过**，因为下面两段录音
还不在仓库里。录音必须是**真人对着麦克风说的**：合成语音（`say`）能证明链路通，
但证明不了识别质量，而识别质量正是这两条用例存在的理由。请不要用 TTS 顶替。

### 需要两段

| 文件名 | 语种 | 内容 | 时长 |
|---|---|---|---|
| `zh-short.wav` | 中文（普通话） | 一句日常短句，10–15 字，**不含专名、生僻词、数字**（热词与数字规范化会引入本测试不想断言的变量）。例：`今天下午三点我们在公司门口见` 里去掉数字，改成 `今天下午我们在公司门口见面` | 2–4 秒 |
| `en-short.wav` | 英文 | 一句日常短句，6–10 词，同样避开专名与数字。例：`the weather is really nice this afternoon` | 2–4 秒 |

英文那一段不是"再测一遍"：请求里 `language` 字段被整个省略（auto），
所以两个语种一起跑才说明服务端判的是音频本身而不是某个默认值。

### 格式（硬性）

- WAV，**16000 Hz，单声道，16-bit PCM**（float32 也可，解析器两种都收）
- 其它采样率或声道数会被 `WAVFixtureDecoder.decodeStrict` 当场拒绝并说明原因 ——
  这是刻意的：服务端 `decode_pcm()` 只收 16 kHz 单声道，让它以 400 回绝的话，
  在客户端看起来会像一次传输故障而不是"fixture 录错了"
- 安静环境，正常语速，不要贴着麦克风
- 每段几秒就够。这是 git 仓库，不是语音语料库

怎么录：用「QuickTime Player → 文件 → 新建音频录制」，停止后存成 `.m4a`；
或用「语音备忘录」录完后「分享 → 存储到文件」。两者都不需要装任何东西，
采样率也不用管 —— 下一步的 `afconvert` 会统一转成 16 kHz 单声道。

再用系统自带工具转格式：

```bash
# 任意录音（.m4a / .aiff / .caf 都行）→ 16 kHz 单声道 16-bit WAV
/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 输入文件 zh-short.wav
# 核对
/usr/bin/afinfo zh-short.wav   # 应显示 16000 Hz, 1 channel, 16-bit
```

### 每段各配一个 sidecar

`zh-short.expected.json` / `en-short.expected.json`，与 wav 同目录同名：

```json
{
  "text": "今天下午我们在公司门口见面",
  "language": "zh",
  "source": "microphone",
  "note": "2026-08-12 录于安静房间，说话人 kingjj"
}
```

- `text`：**人工核对过的**期望转写。不是模型返回的东西 —— 那样就成了拿模型的输出
  去断言模型的输出。写你实际说的那句话
- `language`：`zh` 或 `en`。仅用于校验语种自动识别的结果。
  服务端回的**不是** ISO 码而是模型生成的语种名（`"Chinese"` / `"English"`），
  测试里有一张映射表负责换算，sidecar 这边照旧填两位码即可。
  顺带一提：底层库在模型没吐出语种前缀时会**默认填 "English"**，
  所以英文那段回 `"English"` 并不单独构成自动识别的证据，中文那段回 `"Chinese"` 才是
- `source`：`microphone`（真人录音）或 `tts`（合成）。读到测试通过的人不该把后者
  误读成关于真人麦克风识别率的证据
- `note`：随手记录录制条件，可为 null

wav 在而 sidecar 不在时，测试会**报错**而不是跳过 —— 那是坏掉的 fixture，静默跳过会把它藏起来。

### 录完之后怎么验

```bash
# 1. 装并起 ASR 服务（无需 sudo）
bash scripts/install_asr.sh
launchctl list | grep com.marmotim.asr
curl -s http://127.0.0.1:58471/health

# 2. 跑真链路用例（默认关闭，见下）
MARMOT_TRANSCRIBE_E2E=1 swift test --filter TranscribeE2ETests
```

预期：8 条用例（2 条真链路 + 6 条控制用例）全部执行、0 跳过、0 失败。
若模型把某个字认错导致相似度低于 0.85，
**换一段更清楚的录音，不要调低通过线** —— 一个被调松到能通过的归一化器，
是唯一一种永远绿着的失败。

---

## 为什么真链路用例默认是关的

`MARMOT_TRANSCRIBE_E2E=1` 才会跑。没有这个变量、fixture 缺失、或服务不可达时，
两条真链路用例分别跳过并说明该怎么补，其余六条（归一化器、语种映射表与 WAV 解码器的正/负控）
照常执行 —— 它们不碰网络也不碰 fixture，因此在一台没装模型的机器上，
本文件仍然真的验了点东西，而不是整体跳过后显示为绿。

闸门用环境变量而不是 `MarmotIM.xctestplan`，是因为本仓库的测试**只经 SwiftPM 运行**：
Xcode 工程里没有测试 target。测试计划一侧也登记了跳过项，但那是备而不用的。
