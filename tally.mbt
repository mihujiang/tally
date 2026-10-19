// tally —— 门面 API 的最短路径。
//
// 四层结构（见计划 §0）：`bpe`（内核）-> `vocab`（词表）-> `budget`（预算）-> `tally`（门面）。
// 本包只做转发与再导出，不含任何算法与 IO。

///|
/// 再导出核心类型，让使用者只 import 一个包。
pub using @vocab {
  type Vocab,
  type VocabError,
  type Merge,
  type TrainResult,
}

///|
pub using @budget {
  type Priority,
  type Segment,
  type KeptSegment,
  type TruncatedSegment,
  type DroppedSegment,
  type Plan,
  type Counter,
  type FitConfig,
  type TruncateStrategy,
  type FitError,
}

///|
/// 一段不可裁的上下文（system 提示、工具定义）。
///
/// 门面包提供这四个构造器，是为了让「只 import `weopqrst/tally`」也能装段：
/// 枚举构造器 `Pinned` / `Newest` / `Middle` / `Oldest` 无法经 `pub using` 再导出，
/// 而 `fit` 是主路径，不该逼使用者再依赖 `weopqrst/tally/budget`。
pub fn pinned(role : String, text : String) -> @budget.Segment {
  @budget.Segment::text(role, @budget.Pinned, text)
}

///|
/// 最近若干轮：对下一步生成影响最大，优先保留。
pub fn newest(role : String, text : String) -> @budget.Segment {
  @budget.Segment::text(role, @budget.Newest, text)
}

///|
/// 中间历史：第一批牺牲品之一。
pub fn middle(role : String, text : String) -> @budget.Segment {
  @budget.Segment::text(role, @budget.Middle, text)
}

///|
/// 最早的历史：最先被丢，权重相同时下标更小者先丢。
pub fn oldest(role : String, text : String) -> @budget.Segment {
  @budget.Segment::text(role, @budget.Oldest, text)
}

///|
/// 编码任意字节序列为 token id。
pub fn encode(v : @vocab.Vocab, bytes : Bytes) -> Array[Int] {
  @vocab.Vocab::encode_bytes(v, bytes)
}

///|
/// 编码一段文本。
pub fn encode_string(v : @vocab.Vocab, text : String) -> Array[Int] {
  @vocab.Vocab::encode_string(v, text)
}

///|
/// token id 序列 -> 原始字节。
pub fn decode(v : @vocab.Vocab, tokens : Array[Int]) -> Bytes {
  @vocab.Vocab::decode_ids(v, tokens)
}

///|
/// 字节序列的 token 数。
pub fn count_bytes(v : @vocab.Vocab, bytes : Bytes) -> Int64 {
  @vocab.Vocab::count_bytes(v, bytes)
}

///|
/// 文本的 token 数。
pub fn count(v : @vocab.Vocab, text : String) -> Int64 {
  @vocab.Vocab::count(v, text)
}

///|
/// 逐片明细：`(片文本, 该片的 token 数)`。
pub fn piece_counts(v : @vocab.Vocab, bytes : Bytes) -> Array[(String, Int64)] {
  @vocab.Vocab::piece_counts(v, bytes)
}

///|
/// 精确计数器：给定词表时逐 token 计数。
///
/// 适配器住在门面包：`budget` 只认 `Counter`，包级不依赖词表——所以
/// `import weopqrst/tally/budget` 不会把整份 vocab 拖进来。
pub fn cl100k(v : @vocab.Vocab) -> @budget.Counter {
  {
    name: "cl100k_base",
    exact: true,
    count_bytes: fn(bytes) { @vocab.Vocab::count_bytes(v, bytes) },
  }
}

///|
/// 估算计数器：`chars_per_token` 个字符当 1 token。报告里会标 `exact=false`。
pub fn estimate(chars_per_token : Int) -> @budget.Counter {
  @budget.Counter::estimate(chars_per_token)
}

///|
/// 装配配置：整窗可用、整段丢弃。用 `.with_reserve(..)` / `.with_strategy(..)` 调整。
pub fn fit_config(counter : @budget.Counter, window : Int64) -> @budget.FitConfig {
  @budget.FitConfig::new(counter, window)
}

///|
/// 整段丢弃（默认）。
pub fn truncate_none() -> @budget.TruncateStrategy {
  @budget.NoTruncate
}

///|
/// 保留段首、截掉段尾（`system` 提示这类开头最重要的内容）。
pub fn truncate_tail() -> @budget.TruncateStrategy {
  @budget.KeepPrefix
}

///|
/// 保留段尾、截掉段首（历史/日志这类最近内容最重要的段）。
pub fn truncate_head() -> @budget.TruncateStrategy {
  @budget.KeepSuffix
}

///|
/// 装配上下文：按优先级丢段/截短，并给出可解释的报告。
pub fn fit_with(
  cfg : @budget.FitConfig,
  segments : Array[@budget.Segment],
) -> @budget.Plan raise @budget.FitError {
  @budget.fit_with(cfg, segments)
}

///|
/// 同 `fit_with`，但不 `raise`：配置不成立时返回 `Err((reserve, window))`。
///
/// 为什么需要它：`pub using` 能再导出 `FitError` **类型**，却导不出 suberror
/// 构造器，只 import 门面包的使用者无法把 `ReserveExceedsWindow` 写进 `catch`。
/// 「显式报错」得有一条不依赖错误类型名字的通道。
pub fn fit_with_result(
  cfg : @budget.FitConfig,
  segments : Array[@budget.Segment],
) -> Result[@budget.Plan, (Int64, Int64)] {
  try {
    Ok(@budget.fit_with(cfg, segments))
  } catch {
    @budget.ReserveExceedsWindow(reserve, window) => Err((reserve, window))
  }
}

///|
/// 装配上下文：按优先级整段丢弃（0.3 的兼容入口）。
///
/// 与 `fit_with(fit_config(cl100k(v), limit), segments)` 输出逐字节相同；
/// 不校验 `limit > 0`（旧语义：预算为 0 时全部丢弃、Pinned 溢出上报）。
pub fn fit(
  v : @vocab.Vocab,
  segments : Array[@budget.Segment],
  limit : Int64,
) -> @budget.Plan {
  @budget.assemble(@budget.FitConfig::new(cl100k(v), limit), segments)
}

///|
/// 由三块数据构造一个经过校验的词表（`specials` 为 `(字面量, id)`）。
pub fn build_vocab(
  tokens : Array[Bytes],
  ranks : Map[Bytes, Int],
  specials : Array[(String, Int)],
) -> @vocab.Vocab raise @vocab.VocabError {
  @vocab.build_vocab(tokens, ranks, specials)
}

///|
/// 加载自有规范文本格式的词表。
pub fn load(text : String) -> @vocab.Vocab raise @vocab.VocabError {
  @vocab.load(text)
}

///|
/// 加载 `.tiktoken` 风格词表。
pub fn load_tiktoken(
  text : String,
  specials : Array[(String, Int)],
) -> @vocab.Vocab raise @vocab.VocabError {
  @vocab.load_tiktoken(text, specials)
}

///|
/// 导出为自有规范文本格式。
pub fn to_text(v : @vocab.Vocab) -> String {
  @vocab.Vocab::to_text(v)
}

///|
/// 生成表所用的 Unicode 版本（用于报告与 README 的可复算声明）。
pub fn unicode_version() -> String {
  @bpe.unicode_version()
}

///|
/// 用 byte-level BPE 训练一份词表：给定语料与参数，两次训练**逐字节一致**。
///
/// tie-break 规则（全序，无并列）：pair 频次降序 -> `left` 字节序升序 ->
/// `right` 字节序升序。规则与实现在 `vocab/train.mbt`。
pub fn train(
  corpus : Array[Bytes],
  vocab_size : Int,
  min_frequency : Int,
  specials : Array[String],
) -> @vocab.TrainResult raise @vocab.VocabError {
  @vocab.train(corpus, vocab_size, min_frequency, specials)
}

///|
/// 回读 `tally-train v1` 训练产物（词表一并重建）。
pub fn load_train(text : String) -> @vocab.TrainResult raise @vocab.VocabError {
  @vocab.load_train(text)
}
