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
  type DroppedSegment,
  type Plan,
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
/// 装配上下文：按优先级截断，并给出可解释的丢弃报告。
pub fn fit(
  v : @vocab.Vocab,
  segments : Array[@budget.Segment],
  limit : Int64,
) -> @budget.Plan {
  @budget.fit(v, segments, limit)
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
