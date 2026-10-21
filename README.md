# tally

[English](./README.en.md) | 中文

> **MoonBit 的上下文预算引擎**——把任意长度的上下文精确压进 token 预算，并告诉你丢了什么、为什么。

上下文塞不进窗口是 agent 的必然事件，不是边界情况。常见做法是「字符数 ÷ 4」估算、再按长度硬切：切在半个 JSON 或半个工具调用中间，事后也无法解释为什么留下这一段、丢掉那一段。

`tally` 做四件事，每一件都可核对：

1. **精确计数**：cl100k 形状的 byte-level BPE，2,935 条语料与 `tiktoken 0.14.0` 逐 token 对齐，差异 0。
2. **可解释装配**：按 `Priority` 把段落装进窗口，`Pinned` 永不裁，输出「丢了哪段、多少 token、为什么」。
3. **可复现**：词表与报告都是规范文本，格式被 `FORMAT.lock` 逐字节钉死，改一个字节测试就红。
4. **可验证**：报告旁可附 `tally-digest v1` 侧车——报告字节、逐段字节各留一个 sha256；
   `verify` 先查两份文件是否自洽，给齐词表与输入再**重新装配一遍**做逐字节复算。
   「报告说装了这些」因此可以被别人验，而不是只能相信。
5. **可认账**（0.6.1）：摘要还能被一把共享密钥盖成 `tally-seal v1`，`verify --seal --key`
   一次验完「摘要没被换」和「有人认过」。它证明持有密钥的人签过，**不证明谁写的**——
   对称密钥没有身份，这一点写进格式而不是藏进文档。
6. **预算不够时还有三件细活**（1.0）：**多池配额**（工具定义、多轮历史各有一份额度，
   不够按声明顺序借用，逐池记 `borrowed` / `lent`）、**同优先级内按分数取舍**
   （检索分数不再被硬映射成优先级，而是同优先级里的次序）、**占位压缩**
   （被裁的尾部换成固定标记并写明省了多少 token，模型知道「这里还有内容」）。

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

## 七个问题，一个引擎

| # | 问题 | tally 的回答 |
|---|---|---|
| 1 | 这段输入到底多少 token？ | `Counter`：精确计数（`cl100k`）或明确标注的估算（`estimate`），报告里写着是谁算的 |
| 2 | 窗口 128k，能全给输入吗？ | `window = reserve_output + input_limit`；预留放不下时**显式报错**，不悄悄算成负数 |
| 3 | 装不下的部分，牺牲谁？ | `Priority`：`Oldest` → `Middle` → `Newest`；权重相同时比 `score`（大者留），再相同时丢下标更小的 |
| 4 | 整段丢太浪费，能截短吗？ | `TruncateStrategy`：`KeepPrefix` / `KeepSuffix` / `Compress`，按 `Counter` 二分出刚好够用的字节，切点回退到 UTF-8 边界 |
| 5 | 哪些绝对不能动？ | `Pinned`（system 提示、工具定义）优先保全；仍装不下时显式 `overflow` 并给可操作建议 |
| 6 | 工具定义和历史各有一份额度吗？ | `PoolQuota`：逐池配额 + 池间借用（按声明顺序），报告里逐池记配额/需求/占用/借入/借出 |
| 7 | 为什么是这个结果？能复现吗？ | `Plan::render()`：`tally-plan v3` 规范文本，每段一行写明动作与量，进 `FORMAT.lock` 指纹 |

## 1.0：预算不够时的三种细活

### 多池配额与借用

`PoolQuota` 给每类内容一份独立额度（工具定义、多轮历史、检索片段各有各的），
`Segment::with_pool(name)` 把段归入池。装配是**两轮**：

1. 第一轮照旧按全局预算装，`Pinned` 先占；
2. 第二轮逐池核对：某池超配额时，先按**声明顺序**向还有余额的池借
   （`spare = 配额 − 占用 − 已借出`），借完仍超就在池内继续裁/丢。

借用只抬高借用方**可用额度**，不改变任何段的占用：报告里 `borrowed` 与对方的 `lent`
是同一次转移的两侧，`used` 不变——账目因此自洽（一个池的 `borrowed` 总和等于别的池的
`lent` 总和）。借不到才裁，裁剪仍先按优先级、再按分数、最后按下标。

### 同优先级内按分数取舍

`Segment::with_score(s)` 给段一个分数。受害者选择是三级全序：
**优先级权重最小 → 分数最小 → 下标最小**，对同一优先级内的段也成立。
于是「检索分数 92 的片段该留、分数 41 的该走」不用把分数硬映射成优先级——
映射会抹掉分数之间的次序，只剩三档。

### 占位压缩

`TruncateStrategy::Compress`（门面 `truncate_compress()`）保留段首，把被裁掉的尾部换成
**确定性标记**：

```text
…[tally: 1491 tokens omitted]…
```

标记本身也占 token 并计入预算，所以「留下来的内容 + 标记」一定不超目标；最多三轮收敛
（标记长度影响剩余额度，再算一次计数）。报告里 `omitted=1491` 与正文标记里的数字是同一个数：
说了省多少，正文里就写着多少。

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

这条路径不是想当然：本版发布前用一个空的临时工程 `moon add weopqrst/tally`（线上 `0.7.0`），
写了一段只用门面 API 的程序，`js` 与 `wasm-gc` 双后端都跑出了报告；
发布制品（`weopqrst-tally-0.8.0.zip`）也由 `moon publish --dry-run` 在服务器侧解包后
`moon check` 通过。所以"能被别人依赖"是验过的，不是声明的。

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

  // 6) 1.0：池配额 + 借用 + 占位压缩 + 同优先级按分数取舍
  let pooled = [
    @tally.pinned("system", "you are a coding agent."),
    // 工具定义归 tools 池，分数 9：池内超额时分数低的先走
    @tally.with_score(@tally.with_pool(@tally.newest("tool", "read_file(path)"), "tools"), 9L),
    @tally.with_score(@tally.with_pool(@tally.newest("tool", "run_tests(args)"), "tools"), 4L),
    @tally.with_pool(@tally.oldest("history", "...前 6 轮..."), "history"),
  ]
  // tools 只给 20，history 有余额：按声明顺序借用，报告里记 borrowed/lent
  let cfg2 = @tally.fit_config_pools(
    @tally.fit_config(@tally.cl100k(v), 1024L).with_strategy(@tally.truncate_compress()),
    [("tools", 20L), ("history", 512L)],
  )
  println(@tally.fit_with(cfg2, pooled).render())
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

# 占位压缩：保留段首，被裁的尾部换成固定标记（写明省略量），标记本身也计入预算
moon run cmd/main --target js -- fit --vocab tests/golden/sample-vocab.txt --limit 60 --truncate compress --text "hello world hello world"

# 多段 + 多池：--segment <role>:<priority>:<path>、--pool <name>=<limit>、
# --segment-pool <role>=<name>（把该 role 的所有段归入池）、--segment-score <role>=<n>
moon run cmd/main --target js -- fit --vocab tests/golden/sample-vocab.txt --limit 400 `
  --segment system:pinned:system.txt --segment tools:newest:tools.txt --segment history:oldest:history.txt `
  --pool tools=10 --pool history=300 --segment-pool tools=tools --segment-pool history=history

# 计数
moon run cmd/main --target js -- count --vocab tests/golden/sample-vocab.txt --text "hello world"

# 逐片明细（哪段在吃 token）
moon run cmd/main --target js -- count --vocab tests/golden/sample-vocab.txt --text "hello there token" --explain

# 编码为 id 序列
moon run cmd/main --target js -- encode --vocab tests/golden/sample-vocab.txt --text "hello world"

# 报告 + 摘要侧车：报告给人读（tally-plan v2），摘要给机器验（tally-digest v1）
moon run cmd/main --target js -- digest --vocab tests/golden/sample-vocab.txt --limit 30 --reserve 4 --truncate tail --text "hello world hello world"

# 校验：先查两份文件是否自洽；给齐 --vocab + 输入则再复算一遍并逐字节比对
moon run cmd/main --target js -- verify --report report.txt --digest digest.txt --vocab tests/golden/sample-vocab.txt --limit 30 --reserve 4 --truncate tail --text "hello world hello world"

# 印记：用共享密钥把摘要认一遍（密钥不进输出；生产环境用 --key-file 而不是 --key）
moon run cmd/main --target js -- seal --digest digest.txt --key ci-key --key-id ci

# 带印记校验：自洽 + 印记 +（给齐输入时）端到端复算，三层一次走完
moon run cmd/main --target js -- verify --report report.txt --digest digest.txt --seal seal.txt --key ci-key
```

`--file <f>` 可替代 `--text <s>`（按字节读取，不假设 UTF-8 合法）。
`--segment` / `--pool` / `--segment-pool` / `--segment-score` 都是可重复参数，
`fit` / `digest` / `verify` 三处接受同一组口径——所以带池的计划也能端到端复算。
给了 `--segment` 就不再自动造默认的 `system` + `payload` 两段；role 与池名不得含空白
（它们直接进报告）。三种"静默不生效"都被拦成错误：拼错的 role、拼错的优先级名、
以及 `--segment-pool` 指向一个**没有 `--pool` 声明**的池名。

校验失败只输出一行 `error: ...` 并**点名位置**（哪一行、哪个文件、两个 sha256 各是什么），
例如拿两份真实但不配对的样本：

```text
error: report sha256 mismatch: digest says 317c0e78…, file is d7dd9d5b…
```

**退出码是契约**（0.6.1 起）：成功 `0`，任何失败 `1`。所以 `tally verify` 可以直接放进
CI，不必再 grep 输出。0.6.0 及以前只打印 `error: ...` 却仍然 `exit 0`，那条路子已经
被 `tools/check_examples.py` 与 CI 的 `verify (failure exits non-zero)` 步骤盯住。

## 示例（可运行、可 diff）

六个场景在 `cmd/examples/`，输出是 `tally-plan v3` 规范文本，**逐字节入库**
（`examples/expected/`），由 `python tools/check_examples.py` 复核——示例不是文档里的伪代码。

| 示例 | 场景 | 关注点 |
|---|---|---|
| `big-input` | 十万 token 级日志 → 8192 窗口（留 1024 给回复） | 日志段被**保留段尾**截到 7085 token，`used` 正好 7168 |
| `multi-turn` | 12 轮历史 + `Pinned` system 提示，360 窗口 / 40 预留 | 最早 4 轮先丢、中间 5 轮后丢，最近 3 轮与 system 全保留 |
| `rag` | 6 个检索片段**同一优先级**、只靠 `score` 区分 | 分数最低的 4 个片段先走，前两个与问题保留——分数不再被压成优先级 |
| `foreign-counter` | 外部 tokenizer（按空白切词）包成 `Counter` | 不引入任何依赖，照样计数并把 31 词的段截到 11 词 |
| `pools` | 同一组段、两次池配额：A 有余额可借，B 两池都紧 | A：`tools` 借 50、`history` 借出 50，两池都不裁；B：`tools` 池内按分数裁掉低分工具，`history` 截到配额 |
| `compress` | 1520 token 构建日志 → 60 token 负载 | 段首 + 占位标记，`omitted=1491`；标记里的数字与报告里的 `omitted=` 一致 |

示例默认读夹具词表 `tests/golden/sample-vocab.txt`；换成真实词表只需
`--vocab data/cl100k_base.tiktoken`（`python tools/fetch_vocab.py` 下载；`data/` 不入库）。

```powershell
moon run cmd/examples --target js -- all          # 全部跑一遍
moon run cmd/examples --target js -- big-input    # 也可以单跑
```

除了 6 个示例，还有 9 条 CLI 用例同样逐字节入库：

| 用例 | 关注点 |
|---|---|
| `examples-all` | 6 个示例合并输出仍可 diff |
| `cli-fit` | `fit` 的报告形状 |
| `cli-verify-ok` | `fit` → `digest` → `verify` 全链：先自洽通过，再带词表与输入**复算出同样的两个文件** |
| `cli-compress` | `--truncate compress`：截断行带 `omitted=`，报告仍可被解析 |
| `cli-pools` | `--segment` + `--pool` + `--segment-pool`：`[pools]` 节逐池记借用 |
| `cli-verify-pools` | **带池的计划**也能端到端复算：新参数在 fit / digest / verify 三处同一口径 |
| `cli-verify-mismatch` | 两份都真实但不配对的样本 → 必须失败，并打印两个 sha256 |
| `cli-seal` / `cli-verify-seal` | 摘要被密钥认过：自洽 + 印记一次走完 |
| `cli-verify-seal-mismatch` | 换一把密钥 → 必须失败并指出 `seal` 对不上 |

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

五种对外文本格式都被逐字节钉死：

| 格式 | 内容 | 冻结在哪 |
|---|---|---|
| `tally-vocab v1` | 词表规范文本（`vocab/export.mbt`） | `vocab/format_lock_wbtest.mbt` + `tests/golden/sample-vocab.txt` |
| `tally-plan v3` | 预算计划报告，含 `[pools]` 池台账与 `omitted=`（`budget/report.mbt`） | `format_lock_wbtest.mbt` + `tests/golden/sample-plan{,-overflow,-truncated,-pools,-compressed}.txt` |
| `tally-train v1` | 训练产物配方（`vocab/train_format.mbt`） | `vocab/train_lock_wbtest.mbt` + `tests/golden/sample-train.txt` |
| `tally-digest v1` | 报告摘要侧车（`budget/digest.mbt`） | `budget/digest_lock_wbtest.mbt` + `tests/golden/sample-digest{,-overflow,-truncated}.txt` |
| `tally-seal v1` | 摘要的密钥印记（`budget/seal.mbt`） | `budget/seal_lock_wbtest.mbt` + `tests/golden/sample-seal.txt` |

`FORMAT.lock` 记录每个样本的**字节数与 sha256**；`python tools/gen_format_lock.py --check`
在样本或指纹对不上时失败。改格式实现会先让 MoonBit 测试变红，改样本会先让 `--check` 变红
——两条路都不允许「悄悄漂移」。

`tally-plan v3` 有三条**格式约束**（不引入转义，保证行结构可被空格切分）：

- `counter` 名字、段 `role`、池名、丢弃原因都不得含空格或换行——它们直接进行内
  （CLI 的 `--segment` / `--pool` / `--segment-pool` 会先校验，不合规直接报错）；
- `overflow = true` 时 `[dropped]` 末尾多一行**哨兵**：`-1 pinned *overflow* <excess> <原因>`。
  它不对应任何段，`tokens` 是超出量；按段对账时按 `index == -1` 跳过（`Plan.excess` 是同一数值）；
- `[truncated]` 行尾恒有 `omitted=<n>`（`n` 是被丢掉的原 token 数），`[pools]` 行的六个字段
  `<池名> <配额> <需求> <占用> <借入> <借出>` 后五个恒为整数。

`[pools]` 只在 1.0 的 v3 里出现；空池列表就是一个空节（`[pools]` 紧跟 `[kept]`），
所以 v2 里没有池的计划升上来只多一行标题。`parse_report` 同时认 v2 与 v3——
旧报告仍可被 `verify` 读取，新报告不会把旧的摘要变成废纸。

### 报告摘要格式 `tally-digest v1`

报告给人读，摘要给机器验。摘要是**独立文件**，不嵌进报告——报告格式因此保持"只描述计划"，
摘要则可以单独传、单独替换、单独被拒绝：

```text
tally-digest v1
report <报告文件的 sha256>
plan <[segments] 正文的 sha256>
[segments]
0 kept <该段实际字节的 sha256>
1 dropped -
```

规矩（全部由测试与 `FORMAT.lock` 钉死）：

- 段行按 `index` **升序**排列，与报告里 kept→truncated→dropped 的分节无关（对账前两侧各自排序）；
- `dropped` 段的 sha 固定为 `-`：它没进窗口，没有"进了窗口的字节"可言；
- 溢出哨兵 `-1` 也列进摘要且参与 `plan` 哈希（"溢出过"要可核对），但段对账时两侧都跳过它；
- 换行先归一（UTF-8 BOM 去掉、CRLF→LF、尾部空行折叠），所以 Windows 控制台重定向与
  编辑器写出的文件同样可验；UTF-16（PowerShell 5.1 的默认重定向编码）会被拒绝并提示另存为 UTF-8。

### 印记格式 `tally-seal v1`

摘要证明"内容没变"，印记证明"有人认过这份摘要"。五行，行序固定，`FORMAT.lock` 钉死：

```text
tally-seal v1
scheme hmac-sha256
key_id ci
digest <摘要文件的 sha256>
seal <HMAC-SHA256 hex>
```

规矩：

- `seal` 覆盖**前四行（含头部）**，不覆盖自己——签名不可能覆盖自身；
- `key_id` 也在这四行里：只改标识不重算 mac 就会失败（轮换密钥必须重新盖）；
- 只认 `hmac-sha256`，别的 `scheme` 直接拒绝，不做"猜一个"的兼容；
- 空密钥被拒：空密钥等于人人可签，印记就失去意义；
- 它是**对称**的：证明持有同一把密钥的人认过，**不证明谁写的**。要证明身份需要非对称
  签名与公钥分发，那是另一件事（见「非目标」）；
- 密钥不进任何输出：印记文件可以入库、可以贴进工单，密钥只从 `--key-file`（或调用方
  自己的密钥管理）注入，不走 `--key` 落进 shell 历史。

`verify` 分两级，第二级才是"端到端"：

| 级别 | 输入 | 能证明什么 |
|---|---|---|
| 自洽 | 报告 + 摘要 | 两份文件互相一致：报告字节未改、段数/动作/用了多少 token 对得上、`input_limit == window - reserve` |
| 印记 | 再加 `--seal` + `--key`/`--key-file` | 这份摘要被某把共享密钥认过：摘要被换、`key_id` 被改、印记行被改、密钥不对，都失败 |
| 端到端复算 | 再加 `--vocab` + 输入 | 拿同一份词表和输入**重新装配**，新报告与新摘要与旧文件**逐字节相同** |

只有端到端那级能排除"两份文件一起被改得很自洽"。自洽抓不到的，复算才抓得到；
印记则是另一维度：它不检查内容对不对，只检查"有没有人认过这份内容"。
三层 CI 都跑。

## 1.0：API 冻结

从这一版起，下面这些签名与格式**不再做不兼容改动**；要加东西只能加新函数、新字段的
`with_*` 构造器，或升格式版本号：

> **版本号说明**：mooncakes 现阶段只接受 `0.x.y`（`moon package` 会直接拒绝主版本不为 0 的
> `moon.mod`），所以这次以 **`0.8.0`** 发布。"1.0" 指的是这里的**语义承诺**（API 与五个格式
> 冻结），不是版本号字面；等平台放开主版本再落 `1.0.0`。

| 面 | 冻结内容 |
|---|---|
| 计数 | `Counter`（`name` / `exact` / `count_bytes`）、`cl100k`、`estimate` |
| 词表 | `load` / `to_text` / `encode` / `decode` / `count` / `piece_counts` / `train` / `load_train` |
| 装配 | `fit` / `fit_with` / `fit_with_result`、`FitConfig`（含 `with_reserve` / `with_strategy` / `with_pools`）、`Segment`（含 `with_pool` / `with_score`）、`Priority`、`TruncateStrategy`（`none` / `tail` / `head` / `compress`）、`PoolQuota` |
| 报告 | `Plan`（`kept` / `truncated` / `dropped` / `pools` / `excess`）、`PoolUsage`、`render` |
| 格式 | `tally-vocab v1`、`tally-plan v3`、`tally-train v1`、`tally-digest v1`、`tally-seal v1`，全部进 `FORMAT.lock` |
| CLI | `fit` / `count` / `encode` / `digest` / `verify` / `seal` 六个子命令与退出码契约（成功 0、失败 1） |

向后兼容的承诺只有两条，但都实测过：`parse_report` 同时读 `v2` 与 `v3`；
新增的 `pool` / `score` 字段有默认值，所以 0.x 那种只写 `Segment::new(role, priority, bytes)`
的代码不改一行也能编译、且行为不变（无池、分数 0）。

## 非目标

- 不做通用分词器：不提供 `o200k` 等第二编码，不做 BPE 之外的算法（WordPiece / Unigram）。
- 不做公钥签名与身份体系：`tally-seal v1` 只有 HMAC-SHA256（对称），没有 Ed25519、
  没有证书链、没有"谁签的"。它回答"有没有人认过"，不回答"是谁"。
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
| 占位压缩的粒度 | 只保留**段首**并接固定标记，不做「首尾各留一段」或按语义摘要；标记文案是格式的一部分（要改就得升 v4） |
| 池借用 | 只借额度，不搬段：借入方的段仍归原池记 `used`；借不到的池按优先级/分数/下标自行裁，且池配额**只能收紧不能放宽**全局预算 |
| 截断与字符边界 | 切点会回退到 UTF-8 字符边界，避免半个字符；若边界回退后一个 token 都不剩，则退化为整段丢 |
| 窗口模型 | `window = reserve_output + input_limit`；`reserve >= window` 时显式报错（`fit_with_result` 给出 `Err((reserve, window))`），不支持「预留随内容变化」的自适应策略 |
| 估算计数器 | `estimate(n)` 按**字符**（Unicode 码点）向上取整，不按字节——中文一字 3 字节，按字节会放大 3 倍；它仍只是估算，报告里恒标 `exact=false` |
| 后端 | 只保证 `wasm-gc` 与 `js`；不保证 native |
| 训练 | 已实现（`vocab/train.mbt`），定位为**能力证明**，不再扩展；测试夹具词表仍由 `tools/gen_sample_vocab.py` 确定性生成 |

## 性能（未优化）

只记录数字，不设优化目标：`count` 与端到端装配都不做缓存或增量优化。基准可复跑：

```bash
moon bench -p cmd/perf --release --target wasm-gc   # 两项基准
python tools/check_bench.py                        # 与基线比，同 OS 超 2× / 跨 OS 超 3× 即失败
```

| 基准 | 输入 | 未优化 | 第一轮 | 第二轮（当前） |
|---|---|---|---|---|
| `count-4kb` | 3,390 字符 / 5,230 token | 0.399 ms | 0.257 ms | **0.101 ms**（约 52 M token/s） |
| `fit-100k-8k` | 96 段 / 99,840 token → 8,192 窗口（预留 256） | 7.08 ms | 4.90 ms | **1.89 ms** |

第一轮做的是"少算"：合并时缓存相邻 rank（每轮只重算两个位置）、`count` 走免分配计数路径、
特殊 token 用首字节集合过滤、截断时复用二分里最后一次计数。

第二轮做的是"少分配"：预切分改成单遍解码、每个码点只分类一次（ASCII 直接判、命中一类即短路）；
1–3 字节的短片走不建数组的快路径；词表构建期就备好 ≤ 7 字节 token 的 `Int64` 短键表，
合并时不再为每个候选拼一个 `Bytes` 出来。

两轮下来 `count` 3.9×、端到端 3.7×，**输出逐字节不变**——corpus 2,935 例、160 项测试双后端、
10 条示例全部一致；优化只改"怎么算"，不改"算出什么"。第二轮的三条快路径另有独立守门：
与 0.6.1 原算法做 300 轮随机词表对比、ASCII 分类与生成表逐点核对、全部 1.1M 码点的三类互斥扫描。

机器与时间记在 `tests/bench/baseline.json`（Windows 10 / Intel64 / Python 3.11）。CI 跑同一组基准，
断言只有「不超过基线的 2 倍」——防退化，不是性能承诺。但 CI 是 Linux、基线是 Windows，
跨系统比绝对毫秒本来就不稳：0.8.0 的端到端只慢了 4%，就把 2× 的余量吃掉了（两台机器各自的
0.7.0/0.8.0 对照跑出来是 2.10 → 2.19 ms）。所以**跨 OS 时阈值放到 3×**，那一刻它只抓数量级退化；
脚本会把基线与本机的机器信息、每一项的实测比例都打印出来，CI 里还发一条注解，失败原因不必登录翻日志。
样例词表只有 277 个 token，长文本会更多落到字节级 token，接真实 cl100k 词表后吞吐会不同；
这一栏只代表本仓库自己的基线。

## 开发

```powershell
# 双后端检查与测试（两侧必须全绿且结果一致）
moon check --target wasm-gc
moon check --target js
moon test  --target wasm-gc
moon test  --target js

# 生成器的参考实现依赖（版本与 golden 绑定，见 requirements-dev.txt）
python -m pip install -r requirements-dev.txt
python tools/fetch_vocab.py           # 对齐 golden 的参考词表（不入库）

# 生成物：改动后重新生成并提交
python tools/gen_unicode.py            # Unicode 属性表
python tools/gen_sample_vocab.py       # 测试夹具词表
python tools/gen_pretoken_golden.py    # 预切分 golden
python tools/gen_alignment_golden.py   # 逐 token 对齐 golden
python tools/gen_format_lock.py        # FORMAT.lock 指纹（含 sample-train / sample-digest / sample-seal）

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

当前规模：**8 个包、160 项测试**（含 8 项黑盒，只用公开 API），`wasm-gc` 与 `js` 双后端全绿；
矩阵 A 与参考实现逐 token 对齐 **2,935 条语料**（16,273 个 token，差异 0）；
矩阵 D（可复现训练）5 组参数下同输入两次训练**逐字节一致**；
矩阵 I（垃圾输入只能是成功或**可命名错误**）与矩阵 J（改一字节必须失败且带位置）在
`vocab/robustness_wbtest.mbt`、`budget/digest_wbtest.mbt`；HMAC 用 RFC 4231 的 6 组向量
（`budget/hmac_wbtest.mbt`），印记的参考值由 Python `hmac` 独立算出后交叉验证；
**10 条示例用例**的真实输出逐字节入库（`examples/expected/`），其中 2 条专测"必须失败"，
并顺带断言退出码非零；**2 项基准**（`cmd/perf`）有入库基线，CI 只断「不退化超 2 倍（跨 OS 3 倍）」。
上述检查全部在 `.github/workflows/ci.yml` 里自动跑：`verify` 的自洽、印记、端到端复算，
外加"篡改后必须 exit 非零"的回归步骤与基准守卫。

## 许可

Apache-2.0，见 [LICENSE](./LICENSE)。第三方依赖、参考实现声明与 Unicode 数据许可见 [NOTICE](./NOTICE)。
