//! 基准：只记录「未优化的真实数字」，不设优化目标。
//!
//! 两项对应 ROADMAP V0.7 的完成标准：
//! 1. `count` 吞吐（4KB 混合文本）；
//! 2. 100k → 8k 端到端装配耗时。
//!
//! 运行：`moon bench -p cmd/perf --release --target wasm-gc`。
//! 数字写进 README 时标注机器与「未优化」。

///|
/// 基准用词表：仓库内的 283 词样例词表，随发布包分发，消费端可复现。
const PERF_VOCAB : String = "tests/golden/sample-vocab.txt"

///|
/// 目标输入规模（token）。
const LONG_INPUT_TOKENS : Int64 = 100_000

///|
/// 目标窗口（token）。
const LONG_INPUT_WINDOW : Int64 = 8_192

///|
/// `@tally.load` 接的是词表文本（CLI 里也是先读文件再喂进去）。
fn perf_vocab() -> @tally.Vocab {
  try {
    @tally.load(@fs.read_file_to_string(PERF_VOCAB))
  } catch {
    _ => abort("perf: 无法加载 \{PERF_VOCAB}")
  }
}

///|
/// 中英混合文本，接近真实上下文（标点、数字、ASCII 与汉字都有）。
fn mixed_text(lines : Int) -> String {
  let mut s = ""
  for i in 0..<lines {
    s = s +
      "第 \{i} 轮：上下文预算要可声明、可复算、可被第三方核对。the quick brown fox jumps over the lazy dog 0123456789.\n"
  }
  s
}

///|
/// 按 token 数拼出约 10 万 token 的多段输入；段数固定，
/// 构造开销不计入基准（只测装配本身）。
fn long_input(vocab : @tally.Vocab) -> (Array[@tally.Segment], Int64) {
  let block = mixed_text(8)
  let block_tokens = @tally.count(vocab, block)
  let blocks = if block_tokens <= 0L {
    1
  } else {
    (LONG_INPUT_TOKENS / block_tokens).to_int()
  }
  let segs : Array[@tally.Segment] = []
  for i in 0..<blocks {
    segs.push(@tally.newest("user", "turn \{i}: " + block))
  }
  (segs, block_tokens * blocks.to_int64())
}

///|
test "perf: count" (b : @bench.T) {
  let vocab = perf_vocab()
  let text = mixed_text(40)
  let tokens = @tally.count(vocab, text)
  println("perf: count 输入 \{text.length()} 字符 / \{tokens} token")
  b.bench(fn () { ignore(@tally.count(vocab, text)) }, name="count-4kb", count=10)
}

///|
test "perf: fit" (b : @bench.T) {
  let vocab = perf_vocab()
  let pair = long_input(vocab)
  let segs = pair.0
  let total = pair.1
  println("perf: fit 输入 \{segs.length()} 段 / \{total} token，窗口 \{LONG_INPUT_WINDOW} / 预留 256")
  let cfg = @tally.fit_config(@tally.cl100k(vocab), LONG_INPUT_WINDOW).with_reserve(256L)
  b.bench(fn () { ignore(@tally.fit_with_result(cfg, segs)) }, name="fit-100k-8k", count=3)
}
