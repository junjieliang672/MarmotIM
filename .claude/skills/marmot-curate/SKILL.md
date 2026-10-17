---
name: marmot-curate
description: 整理 MarmotIM 输入法的用户词库、英文置顶词和相对排序。根据输入法记录的打字和选词习惯，提出加词、英文置顶、排序规则以及移除它们的建议，由用户确认后生效。当用户说「整理词库」「整理一下我的词库」「看看有什么词该加」「词库有什么建议」或输入 /marmot-curate 时使用。
---

# 整理 MarmotIM 词库

你要根据用户的打字习惯，对三个库提出建议，并在用户确认后写回：

- **用户词库**：用户常打、但词库里没有的词（含英文）。
- **英文置顶词**：用户经常完整打出来的英文单词。平时英文候选固定在每页最后一位，空格上屏的是中文；进了这个名单的词，在被完整打出时排第一位，空格直接上屏它。例如名单里有 `agent`，打 `agent` 按空格得到 agent，而不是排在它前面的「阿根图」。只打了 `agen` 时不受影响。
- **相对排序**：两个词同时出现在候选里时，固定 A 排在 B 前面。

统计由工具算，判断由你做，决定由用户做。

## 工具

所有读写都通过 `tools/marmot_curate.py`，在仓库根目录运行。输出都是 JSON。

```
python3 tools/marmot_curate.py status
python3 tools/marmot_curate.py candidates user-dict
python3 tools/marmot_curate.py candidates english
python3 tools/marmot_curate.py candidates order
python3 tools/marmot_curate.py candidates exit
python3 tools/marmot_curate.py current
python3 tools/marmot_curate.py decide --file <decisions.json>
python3 tools/marmot_curate.py history
```

`candidates` 的常用参数：`--days N`（统计窗口，默认 30）、`--limit N`（每类最多几个，默认 50）、`--no-context`（不带前后文）。

边界：
- 不要直接读写 `behavior.db` 或 `dictionary.db`，也不要用 `sqlite3` 去查原始事件。原始事件是用户的打字流水，工具只输出汇总后的结果，这是有意的。
- 用户问起隐私时如实说明：工具的输出（候选、数字、每个候选最多 3 条短的前后文）会进入这次对话。如果用户不想带前后文，所有 `candidates` 命令都加 `--no-context`。
- 工具不改三个库。`decide` 只记录用户的决定，由正在运行的输入法去生效。

## 步骤

### 1. 看状态

运行 `status`。

- `recording` 为 false 或 `events` 为 0：告诉用户还没有记录，需要在 MarmotIM 设置 → 词库管理 → 整理 里打开「记录打字和选词习惯」，用一段时间后再来。到此为止。
- `days` 少于 7：告诉用户记录只有几天，结论可能不稳，问是否继续。
- `hours_since_last_event` 很大：提醒用户记录可能已经关了。

### 2. 取数据

运行四个 `candidates` 命令和 `current`。`current` 是三个库现在的内容，用来避免重复建议。

### 3. 判断

工具的门槛很低，只保证「有最基本的证据」。输出里的每一条是否值得建议，由你结合数字、前后文和常识判断。**误收的代价比漏收大：拿不准就不建议，留到下次，等证据更多。**

#### 加词（`phrases`）

候选是用户连续上屏的几个词拼起来的。字段：
- `count` / `days` / `apps`：出现次数，分布在多少天、多少个 App。
- `typed_as`：用户实际是分成哪几段打的。
- `cohesion`：凝固度。一起出现的次数除以其中较少见那一段的次数。接近 1 表示那一段几乎只在这个组合里出现。
- `left_entropy` / `right_entropy`：前面、后面接的词有多不固定。高表示它是独立的词；接近 0 表示前后总是同一个词，多半是某个固定句子的碎片。
- `keys_saved_per_use`：合成一个词之后，每次能少按几个键。
- `wubi` / `pinyin`：工具生成的编码。拼音对多音字可能不准，展示给用户时请顺带检查。

该建议的：独立、有意义的词、专有名词、术语、固定短语。
- 「输入法」「百感交集」「相对排序」

不该建议的：
- 句子碎片：「的时候我」「然后我们就」「是不是可以」。特征是凝固度低，或者一侧的自由度接近 0。
- 能省的键很少（`keys_saved_per_use` ≤ 1）而且不常用的。
- 只是某一天、某一个 App 里集中出现的（比如写某篇文档时反复打的一句话）。
- 看起来像错字的组合。
- 一个候选是另一个更长候选的一部分，而且两者次数几乎相同时，只建议更完整的那个。

#### 加词（`candidates user-dict` 的 `english`）

候选是用户在中文模式下打出字母后直接上屏的英文。接受后，它会以「自己的小写字母」作为编码存入用户词库，在中文模式下打这串字母时作为候选出现。

该建议的：产品名、技术术语、用户常用的专有词，写法固定（`forms` 里只有一种大小写）。

不该建议的：拼错的普通单词；只是某个编码打错后被直接上屏的字母串（比如 `uqwy` 这种看起来像五笔码的）；`forms` 里大小写很乱的。

#### 英文置顶（`candidates english` 的 `english`）

候选是用户完整打出、然后从后面的位置选出来的英文单词。字段：
- `count` / `days`：这样选的次数，分布在多少天。
- `picked_with`：用什么键选的（`tab` 是「上屏英文候选」键，`number` 是数字键）。
- `shown_first_instead`：当时排在第一位的是什么。
- `other_picks_at_this_code` / `other_picks`：同样这串字母，用户选了别的词（通常是中文）的次数和具体是哪些词。

该建议的：次数多、分布在多天，而且 `other_picks_at_this_code` 是 0 或者远少于 `count`。用户打这串字母几乎总是要这个英文词。

不该建议、而是把数字摆给用户让他决定的：`other_picks_at_this_code` 和 `count` 差不多。这串字母同时是用户常用的五笔或拼音编码（比如 `host` 四个键也是一个五笔全码），置顶之后空格不再上屏那个中文词，要按数字键选。展示时写清楚「置顶后，打这串字母想要『某词』时得按 2」。

`other_picks` 里那一两次如果看起来是误选（比如 `agent` 下选了一次「阿根图」），不算撞码，照常建议。

#### 相对排序（`order`）

字段：`a`、`b`（建议 a 排在 b 前面）、`shown_together`、`picked_a` / `picked_b`、`a_share`（两者同时出现时选 a 的比例）、`picked_a_past_b`（b 排在上面时用户越过它选了 a 的次数）、`order_flips`（两个词的先后来回换了几次）、`contexts`（选 a 时和选 b 时各自的前文）。

最重要的判断：**这个偏好是稳定的，还是取决于上下文。**

- 稳定偏好，该建议：`a_share` 高（大致 ≥ 0.85），`picked_a_past_b` 不少，选 b 的那几次看不出规律。`order_flips` 高说明两个词的名次一直在来回跳，固定规则能解决这个问题。
- 取决于上下文，不该建议：比如 `ta` 下的「他 / 她」，选哪个取决于在说谁。即使某段时间「她」选得多，固定「她在他前面」也是错的。看 `contexts`：如果选 a 和选 b 的前文明显是两类情况，就是取决于上下文。同音或同码、意思不同、都常用的词，默认按「取决于上下文」处理。
- `reverse_rule_exists` 为 true 表示已经有一条相反的规则。这时不要建议加新规则，而是指出现有规则可能需要移除。

#### 准出（`exit`）

只包含以前通过这个流程接受的条目，用户手动加的不在其中。

- `remove_word`：`picked_since_all_macs` 是加入之后在所有 Mac 上被选的次数。生效超过 30 天而它是 0，可以建议移除。`shown_but_skipped_this_mac` 高是另一个信号。生效时间短的不要建议。
- `unpin_english`：置顶之后，用户打这串字母时多数是在选别的词（`other_picks_since` 不少，`share_at_its_code` 不到一半），建议移出英文置顶词。`other_picks` 列出他选的是什么。
- `remove_rule`：规则建立之后，用户反过来选 b 的比例很高（`b_share_since` ≥ 0.5 而且次数不少），建议移除规则。

### 4. 向用户展示

按类型分组列成表。每一条写明依据和你的理由，用用户能直接看懂的话。例：

| 建议 | 依据 | 理由 |
|---|---|---|
| 加词「输入法」，五笔 `ltif`，拼音 `shurufa` | 30 天内连续上屏 23 次，分 9 天；每次能省 3 个键 | 常用名词，前后接的词很多样 |

准出的建议单独列一组，说明它是之前什么时候加的。

也简要列出你**没有**建议的、但证据比较多的候选和原因（比如「『的时候我』出现 15 次，但它是句子碎片」），让用户有机会纠正你。数量多时只列最靠前的几条。

没有任何值得建议的内容时，直接告诉用户，不要硬凑。

### 5. 等用户确认

问用户哪些要、哪些不要。用户可以改编码，也可以把你没建议的条目加进来。

不要替用户决定。没有得到明确答复的条目不要写入，既不算接受也不算拒绝。

### 6. 写回

把用户**明确表态**的条目写成一个 JSON 文件（放在临时目录），然后运行 `decide --file`。格式是一个列表：

```json
[
  {"kind": "add_word", "decision": "accept", "text": "输入法", "wubi": "ltif", "pinyin": "shurufa",
   "reason": "常用名词", "stats": {"count": 23}},
  {"kind": "add_word", "decision": "accept", "text": "GitHub", "english": true,
   "reason": "常用产品名", "stats": {"count": 7}},
  {"kind": "add_word", "decision": "reject", "text": "的时候我", "stats": {"count": 15}},
  {"kind": "pin_english", "decision": "accept", "text": "agent", "stats": {"count": 12}},
  {"kind": "add_rule", "decision": "accept", "a": "交集", "b": "效仿", "stats": {"count": 22}},
  {"kind": "remove_word", "decision": "accept", "text": "某个旧词"},
  {"kind": "unpin_english", "decision": "accept", "text": "host"},
  {"kind": "remove_rule", "decision": "accept", "a": "次", "b": "交集"}
]
```

- `kind`：`add_word`、`remove_word`、`pin_english`、`unpin_english`、`add_rule`、`remove_rule`。
- `decision`：`accept` 或 `reject`。
- `stats.count`：这条候选的 `count` 字段，原样带上。被拒绝的条目要等证据翻倍才会再次出现，这个数就是依据。
- 中文加词需要 `wubi` 或 `pinyin` 至少一个（五笔 1–4 个小写字母，拼音只含小写字母）。英文加词写 `"english": true`，不需要编码，只能是纯字母。
- `pin_english` / `unpin_english` 的 `text` 是那个英文单词，只能是纯字母，必须是英文词表里已有的词（`candidates english` 给出的都是）。
- 用户拒绝的条目也要写进去（`reject`），这样下次不会再提。

任何一条格式不对，工具会整批拒绝并指出是哪几条，修正后重试。

### 7. 报告结果

`decide` 的输出里，每条有 `status`：
- `applied`：已经生效。
- `failed`：没能生效，`error` 里有原因（比如规则会和现有规则形成环）。把原因告诉用户。
- `accepted`：已记录但还没生效，通常是输入法没在运行。告诉用户它会在输入法下次启动时生效。
- `rejected`：已记入「不再建议」。

生效的条目在 MarmotIM 设置 → 词库管理的三个页面里能看到，也能在那里手动删除。它们会通过 iCloud 同步到用户的其他 Mac。
