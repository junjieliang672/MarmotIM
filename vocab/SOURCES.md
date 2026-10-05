# 词库来源与署名

`vocab/` 下每个数据文件的来源、许可证和处理方式。土拨鼠输入法本身以 GPL-3.0 发布；
下面列出的数据保留各自的许可证条款。

如果你发现这里漏列了来源或署名有误，请提 issue。

## 拼音与五笔

| 文件 | 来源 | 许可证 | 处理 |
|---|---|---|---|
| `py_table.txt` | [雾凇拼音 rime-ice](https://github.com/iDvel/rime-ice)（基础、扩展、腾讯词库）；[CustomPinyinDictionary](https://github.com/wuhgit/CustomPinyinDictionary) | 雾凇拼音为 GPL-3.0；CustomPinyinDictionary 见其仓库 | 转成「拼音 + 按顺序排列的词」的行格式，行内顺序即默认排序 |
| `wb_table.txt`、`jianma.txt` | README 的致谢把 [清歌输入法](https://qingg.im) 记为词库来源 | 仓库里没有记录 | 行内顺序即重码的默认排序，见下 |
| `cn_en_table.txt` | 仓库里没有记录 | 仓库里没有记录 | |

### 五笔重码的顺序调整（2026-10-04）

`wb_table.txt` 中 2,194 行的行内顺序在这一天调整过，每行的词没有增删：

- 886 行：不在 GB2312 字符集里的单字（生僻字、繁体字）移到行尾。
- 1,346 行：首选是词组的重码行由大语言模型（Claude）逐行审阅，把明显比后面的词
  少用的首选词后移。其中 47 行有本项目作者个人选词统计的支持；另有 35 条建议因
  与该统计相反而没有采用。

这部分顺序是模型和个人统计的判断，不来自任何公开词频数据。

## 英文

`en_table.txt` 由 [`tools/build_en_table.py`](../tools/build_en_table.py) 生成，
合并了下面几个来源。格式是「键、显示形式、词频名次」，制表符分隔。

| 来源 | 提供了什么 | 许可证 |
|---|---|---|
| 原有的英文词表，约 2.1 万词。README 把 [雾凇拼音 rime-ice](https://github.com/iDvel/rime-ice) 记为词库来源，其英文词库（`en`、`en_ext`）的规模和内容与之相符 | 这些词及其大小写写法（`GitHub`、`iPhone`） | 雾凇拼音为 GPL-3.0 |
| [wordfreq](https://github.com/rspeer/wordfreq) 3.1.1，Robyn Speer | 英文词频名次；5 个字母以上取前 8 万名内的词，4 个字母以内只取前 1 万名内且系统词典收录的词 | 代码 Apache-2.0；数据 CC BY-SA 4.0 |
| macOS 自带的 `/usr/share/dict/words`（Webster's Second International，1934） | 判断短词是否为正式单词；为专有名词恢复首字母大写（`london` → `London`） | 公有领域 |
| `en_supplement.txt` | 极常用的短词、月份缩写、常见缩写和单位，以及编程、机器学习、互联网和职场词汇，共 571 条 | 本项目手写，随项目以 GPL-3.0 发布 |

wordfreq 的数据于 2026-10-04 通过 `pip install wordfreq` 获取。

### wordfreq 的上游数据

按 wordfreq 的要求，这里转列它所汇总的数据来源。英文词频由其中多个来源综合而成。

- **Google Books Ngrams**（<http://books.google.com/ngrams>）与 Google Books Syntactic Ngrams。
- **Leeds Internet Corpus**，利兹大学翻译研究中心（<http://corpus.leeds.ac.uk/list.html>）。
- **Wikipedia**（<http://www.wikipedia.org>）。
- **ParaCrawl** 多语言网页语料（<https://paracrawl.eu>）。
- **OPUS OpenSubtitles 2018**（<http://opus.nlpl.eu/OpenSubtitles.php>），数据来自
  OpenSubtitles 项目（<http://www.opensubtitles.org/>）。
- **SUBTLEX** 词频表（SUBTLEX-US、SUBTLEX-UK 等），Marc Brysbaert 等人编制，
  可在 <http://crr.ugent.be/programs-data/subtitle-frequencies> 免费获取。
- 通过 Twitter 流式 API 统计的词频（只含统计数字，不含推文内容）。

引用：

- Robyn Speer. (2022). rspeer/wordfreq: v3.0 (v3.0.2). Zenodo.
  <https://doi.org/10.5281/zenodo.7199437>
- Brysbaert, M. & New, B. (2009). Moving beyond Kucera and Francis: A Critical
  Evaluation of Current Word Frequency Norms and the Introduction of a New and
  Improved Word Frequency Measure for American English. Behavior Research
  Methods, 41 (4), 977-990.
- van Heuven, W. J., Mandera, P., Keuleers, E., & Brysbaert, M. (2014).
  SUBTLEX-UK: A new and improved word frequency database for British English.
  The Quarterly Journal of Experimental Psychology, 67(6), 1176-1190.
- Lison, P. and Tiedemann, J. (2016). OpenSubtitles2016: Extracting Large
  Parallel Corpora from Movie and TV Subtitles. LREC 2016.
- Lin, Y., Michel, J.-B., Aiden, E. L., Orwant, J., Brockman, W., and Petrov, S.
  (2012). Syntactic annotations for the Google Books Ngram Corpus. ACL 2012
  system demonstrations, 169-174.

wordfreq 完整的许可说明和引用列表见它的
[README](https://github.com/rspeer/wordfreq#license)。

### CC BY-SA 4.0 说明

`en_table.txt` 中的词频名次派生自 wordfreq 的数据，按
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) 使用；该许可证允许
把改编作品以 GPL-3.0 发布。

## Emoji 与符号

| 文件 | 来源 |
|---|---|
| `emoji_table.txt`、`emoji_index.txt`、`symbol_index.txt`、`symbols.yaml` | 仓库里没有记录 |
| `emoji_en_table.txt` | 由 [`tools/generate_emoji_en.py`](../tools/generate_emoji_en.py) 从 `emoji_table.txt` 生成 |

标着「仓库里没有记录」的几项，是整理这份文件时（2026-10-04）无法从仓库历史确认的。
知道出处的话请补上。

## 设计上的借鉴

- **英文候选放在固定位置**：有五笔或拼音候选时，英文候选只排在每页最后一位。
  这个做法借鉴自雾凇拼音的 `reduce_english_filter`，它把与拼音撞码的短英文词降到
  固定的候选位置。
