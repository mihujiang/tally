# tally

[English](./README.en.md) | 中文

> **MoonBit 的上下文预算引擎**——把任意长度的上下文精确压进 token 预算，并告诉你丢了什么、为什么。

上下文塞不进窗口是 agent 的必然事件，不是边界情况。常见做法是「字符数 ÷ 4」估算、再按长度硬切：切在半个 JSON 或半个工具调用中间，事后也无法解释为什么留下这一段、丢掉那一段。

`tally` 做三件事，每一件都可核对：

1. **精确计数**：cl100k 形状的 byte-level BPE，2,935 条语料与 `tiktoken 0.14.0` 逐 token 对齐，差异 0。
2. **可解释装配**：按 `Priority` 把段落装进窗口，`Pinned` 永不裁，输出「丢了哪段、多少 token、为什么」。
3. **可复现**：词表与报告都是规范文本，格式被 `FORMAT.lock` 逐字节钉死，改一个字节测试就红。

```moonbit
let segments = [
  @tally.pinned("system", "you are a helpful assistant."),   // 永不裁
  @tally.oldest("history", "...前 50 轮..."),                 // 最先牺牲
  @tally.newest("user", "现在的问题"),
]
// 窗口 8192，留 1024 给回复 → 输入预算 7168；超了先截段首（保留最近内容）
let cfg = @tally.fit_config(@tally.cl100k(v), 8192L)
  .with_reserve(1024L)
  .with_strategy(@tally.truncate_head())
let plan = @tally.fit_with(cfg, segments)
println(plan.render())   // kept / truncated / dropped 三段清单与原因
```

`fit_with` 在配置不成立（`reserve >= window`）时 `raise`。「装不下」不会抛错——那写进报告；
抛错只发生在配置本身矛盾。不想被错误类型绑住就用 `fit_with_result`：

```moonbit
match @tally.fit_with_result(cfg, segments) {
  Ok(plan) => println(plan.render())
  Err((reserve, window)) => println("reserve \{reserve} 吃掉了窗口 \{window}")
}
```

`fit(v, segments, limit)` 仍然可用：等价于「整窗可用、无预留、整段丢弃」，与旧版行为一致
（包括 `limit <= 0` 时全部丢弃 / Pinned 溢出上报，不抛错）。

分词（`encode` / `decode` / `count`）是这套东西的**底座**：它保证预算层拿到的是精确数，而不是估算。

## 六个问题，一个引擎

| # | 问题 | tally 的回答 |
|---|---|---|
| 1 | 这段输入到底多少 token？ | `Counter`：精确计数（`cl100k`）或明确标注的估算（`estimate`），报告里写着是谁算的 |
| 2 | 窗口 128k，能全给输入吗？ | `window = reserve_output + input_limit`；预留放不下时**显式报错**，不悄悄算成负数 |
| 3 | 装不下的部分，牺牲谁？ | `Priority`：`Oldest` → `Middle` → `Newest`；权重相同时丢更早的历史 |
| 4 | 整段丢太浪费，能截短吗？ | `TruncateStrategy`：`KeepPrefix` / `KeepSuffix`，按 `Counter` 二分出刚好够用的字节，切点回退到 UTF-8 边界 |
| 5 | 哪些绝对不能动？ | `Pinned`（system 提示、工具定义）优先保全；仍装不下时显式 `overflow` 并给可操作建议 |
| 6 | 为什么是这个结果？能复现吗？ | `Plan::render()`：`tally-plan v2` 规范文本，每段一行写明动作与量，进 `FORMAT.lock` 指纹 |

## 它是什么

四层结构，一层一个包，依赖方向单向：

| 层 | 包 | 职责 | 依赖 |
|---|---|---|---|
| 算法内核 | `bpe` | 词表无关的 byte-level BPE 编码/解码、预切分扫描器、Unicode 属性表 | 仅 `core` |
| 词表 | `vocab` | 词表模型、加载（含自写 base64）、规范文本导出、可复现 BPE 训练 | `bpe` + `core` |
| **预算（产品本体）** | `budget` | **`Counter` 可插拔计数、窗口模型、优先级装配与截断，输出可解释、可冻结的报告** | `bpe` |
| 门面 | `tally`（根包） | `fit_with` / `fit` / `encode` / `count` 的最短路径 | 以上三层 |
| 工具与示例 | `cmd/main`、`cmd/examples` | CLI 与可运行示例（唯一有 IO 的地方） | `x/fs` |

**核心包零第三方依赖**；`moonbitlang/x` 只被 `cmd/main` 用于读写文件。

## 与 `tokenizers-moonbit` 的分工

两者不是替代关系，轴不同：

| | `tokenizers-moonbit` | tally |
|---|---|---|
| 轴 | 广度：5 种算法、39 个模型、对接 HF | 收口：固定 cl100k，把预算做透 |
| 与参考实现对齐 | Python `tokenizers` 0.22.2 | `tiktoken` 0.14.0 |
| 训练 | BPE / WordPiece / Unigram（跟随 HF 语义） | 只用 BPE，全序 tie-break，两次训练逐字节一致 |
| 预算层 | 无 | `Priority` / `Pinned` / 丢弃报告 / 格式冻结 |
| 适合 | 要多模型、WordPiece、Unigram、native | 要「装进窗口并解释」 |

需要通用分词器时用它；需要把上下文压进预算并留下可审计记录时用 tally。

0.4.0 起 `budget` 只依赖 `Counter` 接口（`name` + `exact` + `count_bytes: (Bytes) -> Int64`）。
0.4.1 把 `cl100k` 适配器也移到门面包，`budget` 的包级依赖只剩 `core`
（`moon info` 里 `budget` 的 import 表不含 `vocab`）——`import weopqrst/tally/budget`
不会把词表一起拖进来。
把外部 tokenizer 的分词结果包成一个 `Counter`，就能用它计数、用我们的预算层裁剪：

```moonbit
// 示意：适配外部 tokenizer，不需要给外部类型写 impl
let counter : @tally.Counter = {
  name: "tokenizers-moonbit/cl100k",
  exact: true,
  count_bytes: fn(bytes) { their_tokenizer.count(bytes) },
}
let plan = @tally.fit_with(@tally.fit_config(counter, 8192L), segments)
```

（`Counter` 不允许 `derive`、不能序列化——它只需要「能数」。）

## 快速开始

### 作为库

```powershell
moon add weopqrst/tally
```

```moonbit
fn demo(vocab_text : String) -> Unit raise {
  // 加载词表（自有规范文本格式，见下）；加载后不可变
  let v = @tally.load(vocab_text)

  // 1) 预算装配：主路径。按优先级装进 4096，给出丢弃报告
  //    四个构造器都在门面包里，只 import `weopqrst/tally` 就够
  let segments = [
    @tally.pinned("system", "you are a helpful assistant."),
    @tally.oldest("history", "hello world hello world"),
    @tally.newest("user", "hello there token"),
  ]
  let plan = @tally.fit(v, segments, 4096L)
  println(plan.render())

  // 2) 窗口 + 预留 + 截断：留 1024 给回复，超预算的段保留段尾
  //    策略同样有门面构造器：truncate_none / truncate_tail / truncate_head
  let cfg = @tally.fit_config(@tally.cl100k(v), 8192L)
    .with_reserve(1024L)
    .with_strategy(@tally.truncate_head())
  println(@tally.fit_with(cfg, segments).render())

  // 3) 精确计数
  println(@tally.count(v, "it's a test"))

  // 4) 编码 / 解码：任意字节序列都可编码，解码后逐字节还原
  let ids = @tally.encode(v, @utf8.encode("hello world"))
  println(@tally.decode(v, ids))

  // 5) 逐片明细：哪一段在吃 token
  for piece in @tally.piece_counts(v, @utf8.encode("hello there token")) {
    println(piece)
  }
}
```

还可以自己训练词表（**能力证明，不是主线**；同输入两次训练结果逐字节一致）：

```moonbit
fn train_demo() -> Unit raise {
  let corpus = [@utf8.encode("hello world"), @utf8.encode("hello 世界")]
  let result = @tally.train(corpus, 280, 1, ["<|endoftext|>"])
  println(result.to_text())          // tally-train v1 配方，可 diff、可冻结
  let back = @tally.load_train(result.to_text())
  println(@tally.count(back.vocab, "hello world"))
}
```

### CLI

```powershell
# 预算装配（Pinned 段保护 + 丢弃报告）——最常用
# 输出：system 段 kept 26 token，payload 段 dropped 5 token 并给出原因
moon run cmd/main --target js -- fit --vocab tests/golden/sample-vocab.txt --limit 28 --text "hello world hello world"

# 窗口 34、留 4 给回复 → 输入预算 30；payload 段保留段首截到 4 token
moon run cmd/main --target js -- fit --vocab tests/golden/sample-vocab.txt --limit 30 --reserve 4 --truncate tail --text "hello world hello world"

# 同理，但保留段尾（最近内容）：--truncate head

# 计数
moon run cmd/main --target js -- count --vocab tests/golden/sample-vocab.txt --text "hello world"

# 逐片明细（哪段在吃 token）
moon run cmd/main --target js -- count --vocab tests/golden/sample-vocab.txt --text "hello there token" --explain

# 编码为 id 序列
moon run cmd/main --target js -- encode --vocab tests/golden/sample-vocab.txt --text "hello world"
```

`--file <f>` 可替代 `--text <s>`（按字节读取，不假设 UTF-8 合法）。

## 示例（可运行、可 diff）

四个场景在 `cmd/examples/`，输出是 `tally-plan v2` 规范文本，**逐字节入库**
（`examples/expected/`），由 `python tools/check_examples.py` 复核——示例不是文档里的伪代码。

```powershell
moon run cmd/examples --target js -- all          # 全部跑一遍
moon run cmd/examples --target js -- big-input    # 也可以单跑
```

| 示例 | 场景 | 关注点 |
|---|---|---|
| `big-input` | 十万 token 级日志 → 8192 窗口（留 1024 给回复） | 日志段被**保留段尾**截到 7085 token，`used` 正好 7168 |
| `multi-turn` | 12 轮历史 + `Pinned` system 提示，360 窗口 / 40 预留 | 最早 4 轮先丢、中间 5 轮后丢，最近 3 轮与 system 全保留 |
| `rag` | 6 个检索片段 + 问题，按分数映射 `Priority` | 低分片段整段丢（默认策略），高分片段与问题保留 |
| `foreign-counter` | 外部 tokenizer（按空白切词）包成 `Counter` | 不引入任何依赖，照样计数并把 31 词的段截到 11 词 |

示例默认读夹具词表 `tests/golden/sample-vocab.txt`；换成真实词表只需
`--vocab data/cl100k_base.tiktoken`（`python tools/fetch_vocab.py` 下载；`data/` 不入库）。

## 词表格式

自有规范文本格式 `tally-vocab v1`，可 diff、可指纹，`id` 与 `rank` 显式分开且 `id` 必须稠密升序：

```text
# tally-vocab v1
# unicode 17.0.0
# tokens 277
[specials]
276 PHxlbmRvZnRleHR8Pg==
[tokens]
0 0 AA==
...
```

`load` / `to_text` 满足：`load(to_text(v))` 与 `v` 内容等价，且同一个 `v` 的导出**逐字节稳定**。

### 训练产物格式

训练产物用自有格式 `tally-train v1` 存**配方**（参数 + 合并序列），词表格式存**展开结果**。
256 个单字节是隐含基座不落盘；合并按 rank 稠密升序，`id` 一路升序（先 `[merges]` 再 `[specials]`），
token 表可完全重建：

```text
# tally-train v1
# unicode 17.0.0
# corpus_bytes 180
# corpus_words 43
# vocab_size 280
# min_frequency 2
# tokens 280
[merges]
256 MTI= MQ== Mg==
...
[specials]
279 PHxlbmRvZnRleHR8Pg==
```

`train -> to_text -> load_train` 是**不动点**：回读出的词表还能编码，且与原词表编码结果一致。
同一份语料和参数训练两次，产物**逐字节相同**（tie-break 全序：pair 频次降序 → `left` 字节序升序 → `right` 字节序升序）。

## 格式冻结（`FORMAT.lock`）

三种对外文本格式都被逐字节钉死：

| 格式 | 内容 | 冻结在哪 |
|---|---|---|
| `tally-vocab v1` | 词表规范文本（`vocab/export.mbt`） | `vocab/format_lock_wbtest.mbt` + `tests/golden/sample-vocab.txt` |
| `tally-plan v2` | 预算计划报告（`budget/report.mbt`） | `format_lock_wbtest.mbt` + `tests/golden/sample-plan{,-overflow,-truncated}.txt` |
| `tally-train v1` | 训练产物配方（`vocab/train_format.mbt`） | `vocab/train_lock_wbtest.mbt` + `tests/golden/sample-train.txt` |

`FORMAT.lock` 记录每个样本的**字节数与 sha256**；`python tools/gen_format_lock.py --check`
在样本或指纹对不上时失败。改格式实现会先让 MoonBit 测试变红，改样本会先让 `--check` 变红
——两条路都不允许「悄悄漂移」。

`tally-plan v2` 有两条**格式约束**（不引入转义，保证行结构可被空格切分）：

- `counter` 名字与段 `role` 不得含空格或换行——它们直接进行内；
- `overflow = true` 时 `[dropped]` 末尾多一行**哨兵**：`-1 pinned *overflow* <excess> <原因>`。
  它不对应任何段，`tokens` 是超出量；按段对账时按 `index == -1` 跳过（`Plan.excess` 是同一数值）。

## 非目标

- 不做通用分词器：不提供 `o200k` 等第二编码，不做 BPE 之外的算法（WordPiece / Unigram）。
- 不做通用正则引擎——只为**固定的一条**预切分模式手写扫描器。
- 不做性能优化：缓存与吞吐只给诚实数字，不设优化目标。
- 不是某个库的 MoonBit 版。公开词表文件只作**验证语料与兼容性输入**。
- 不做 LLM 客户端、向量检索、GUI / 文档站、服务端。

## 已知边界

| 边界 | 说明 |
|---|---|
| 预切分模式 | 只实现 cl100k 形状的 7 分支模式；换模式需改扫描器 |
| Unicode 版本 | 属性表基于 **17.0.0**（`unicode_version()` 可查）。表由 `tools/gen_unicode.py` 从 `regex` 模块的属性表导出，**与参考实现同一引擎**，因此不是"近似"，而是逐码点一致 |
| `o200k` 类编码 | 不提供。需要额外的 Unicode 类别与属性表，且不构成差异化 |
| 截断粒度 | 要么整段丢，要么截到「不超预算」为止；切点由 `Counter` 二分得到，**BPE 计数对长度不严格单调**（追加字节可能触发合并），因此不保证是理论最长的可容纳切片，但保证不超预算且可复现 |
| 截断与字符边界 | 切点会回退到 UTF-8 字符边界，避免半个字符；若边界回退后一个 token 都不剩，则退化为整段丢 |
| 窗口模型 | `window = reserve_output + input_limit`；`reserve >= window` 时显式报错（`fit_with_result` 给出 `Err((reserve, window))`），不支持「预留随内容变化」的自适应策略 |
| 估算计数器 | `estimate(n)` 按**字符**（Unicode 码点）向上取整，不按字节——中文一字 3 字节，按字节会放大 3 倍；它仍只是估算，报告里恒标 `exact=false` |
| 后端 | 只保证 `wasm-gc` 与 `js`；不保证 native |
| 训练 | 已实现（`vocab/train.mbt`），定位为**能力证明**，不再扩展；测试夹具词表仍由 `tools/gen_sample_vocab.py` 确定性生成 |

## 开发

```powershell
# 双后端检查与测试（两侧必须全绿且结果一致）
moon check --target wasm-gc
moon check --target js
moon test  --target wasm-gc
moon test  --target js

# 生成物：改动后重新生成并提交
python tools/gen_unicode.py            # Unicode 属性表
python tools/gen_sample_vocab.py       # 测试夹具词表
python tools/gen_pretoken_golden.py    # 预切分 golden
python tools/gen_alignment_golden.py   # 逐 token 对齐 golden
python tools/gen_format_lock.py        # FORMAT.lock 指纹（含 sample-train.txt）

# 示例输出（改了报告格式或示例，需要 --update 并 review diff）
python tools/check_examples.py
python tools/check_examples.py --update

# CI：生成物 / 指纹 / 示例输出对不上就失败（手动跑同一组命令）
python tools/gen_unicode.py --check
python tools/gen_sample_vocab.py --check
python tools/gen_pretoken_golden.py --check
python tools/gen_alignment_golden.py --check
python tools/gen_format_lock.py --check
python tools/check_examples.py
```

当前规模：**7 个包、87 项测试**（含 6 项黑盒，只用公开 API），`wasm-gc` 与 `js` 双后端全绿；
矩阵 A 与参考实现逐 token 对齐 **2,935 条语料**（16,273 个 token，差异 0）；
矩阵 D（可复现训练）5 组参数下同输入两次训练**逐字节一致**；
**4 个示例 + 1 条 CLI 用例**的真实输出逐字节入库（`examples/expected/`）。
上述检查全部在 `.github/workflows/ci.yml` 里自动跑。

## 许可

Apache-2.0，见 [LICENSE](./LICENSE)。第三方依赖、参考实现声明与 Unicode 数据许可见 [NOTICE](./NOTICE)。
