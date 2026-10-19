# tally

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
let plan = @tally.fit(v, segments, 8192L)   // 装进 8k 窗口
println(plan.render())                       // 逐段列出 kept / dropped 与原因
```

分词（`encode` / `decode` / `count`）是这套东西的**底座**：它保证预算层拿到的是精确数，而不是估算。

## 五个问题，一个引擎

| # | 问题 | tally 的回答 |
|---|---|---|
| 1 | 这段输入到底多少 token？ | `count` / `piece_counts`，精确计数而非估算 |
| 2 | 装不下的部分，牺牲谁？ | `Priority`：`Oldest` → `Middle` → `Newest`；权重相同时丢更早的历史 |
| 3 | 哪些绝对不能动？ | `Pinned`（system 提示、工具定义）优先保全；仍装不下时显式 `overflow` 并给可操作建议 |
| 4 | 为什么是这个结果？ | `Plan::render()`：每段一行，`kept` / `dropped` + 原因 |
| 5 | 能复现、能 diff 吗？ | `tally-plan v1` 规范文本，进 `FORMAT.lock` 指纹 |

## 它是什么

四层结构，一层一个包，依赖方向单向：

| 层 | 包 | 职责 | 依赖 |
|---|---|---|---|
| 算法内核 | `bpe` | 词表无关的 byte-level BPE 编码/解码、预切分扫描器、Unicode 属性表 | 仅 `core` |
| 词表 | `vocab` | 词表模型、加载（含自写 base64）、规范文本导出、可复现 BPE 训练 | `bpe` + `core` |
| **预算（产品本体）** | `budget` | **上下文装配与截断，输出可解释、可冻结的丢弃报告** | `bpe` |
| 门面 | `tally`（根包） | `fit` / `encode` / `count` 的最短路径 | 以上三层 |
| 工具 | `cmd/main` | CLI（唯一有 IO 的地方） | `x/fs` |

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
0.4.0 起 `budget` 将改为依赖 `Counter` 接口而非具体词表，届时可以直接用它的分词结果驱动本包的装配（计划，尚未实现）。

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

  // 2) 精确计数
  println(@tally.count(v, "it's a test"))

  // 3) 编码 / 解码：任意字节序列都可编码，解码后逐字节还原
  let ids = @tally.encode(v, @utf8.encode("hello world"))
  println(@tally.decode(v, ids))

  // 4) 逐片明细：哪一段在吃 token
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

# 计数
moon run cmd/main --target js -- count --vocab tests/golden/sample-vocab.txt --text "hello world"

# 逐片明细（哪段在吃 token）
moon run cmd/main --target js -- count --vocab tests/golden/sample-vocab.txt --text "hello there token" --explain

# 编码为 id 序列
moon run cmd/main --target js -- encode --vocab tests/golden/sample-vocab.txt --text "hello world"
```

`--file <f>` 可替代 `--text <s>`（按字节读取，不假设 UTF-8 合法）。

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
| `tally-plan v1` | 预算计划报告（`budget/report.mbt`） | `format_lock_wbtest.mbt` + `tests/golden/sample-plan*.txt` |
| `tally-train v1` | 训练产物配方（`vocab/train_format.mbt`） | `vocab/train_lock_wbtest.mbt` + `tests/golden/sample-train.txt` |

`FORMAT.lock` 记录每个样本的**字节数与 sha256**；`python tools/gen_format_lock.py --check`
在样本或指纹对不上时失败。改格式实现会先让 MoonBit 测试变红，改样本会先让 `--check` 变红
——两条路都不允许「悄悄漂移」。

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
| 截断粒度 | 当前按**整段**丢弃，不支持把一段截短（计划在 0.4.0） |
| 窗口模型 | 当前 `limit` 是单值，不含「给回复预留多少」（计划在 0.4.0） |
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

# CI：生成物 / 指纹对不上就失败
python tools/gen_unicode.py --check
python tools/gen_sample_vocab.py --check
python tools/gen_pretoken_golden.py --check
python tools/gen_alignment_golden.py --check
python tools/gen_format_lock.py --check
```

当前规模：**6 个包、67 项测试**（含 1 项黑盒，只用公开 API），`wasm-gc` 与 `js` 双后端全绿；
矩阵 A 与参考实现逐 token 对齐 **2,935 条语料**（16,273 个 token，差异 0）；
矩阵 D（可复现训练）5 组参数下同输入两次训练**逐字节一致**。

## 许可

Apache-2.0，见 [LICENSE](./LICENSE)。第三方依赖、参考实现声明与 Unicode 数据许可见 [NOTICE](./NOTICE)。
