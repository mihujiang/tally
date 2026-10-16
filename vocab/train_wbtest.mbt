// 训练的**可复现性**与**规则正确性**。
//
// 可复现性要是假的，训练就是个随机数发生器：同一份语料跑两次得到两份词表，
// 谁也没法复算。所以这里先把 tie-break 用手算得出的例子钉死，
// 再做「同输入两次逐字节一致」的矩阵 D。

///|
/// 把合并序列渲染成 `左|右>合并`，便于断言与阅读。
fn show_merges(merges : Array[Merge]) -> String {
  let out : Array[String] = []
  for m in merges {
    out.push(
      @utf8.decode_lossy(m.left) +
      "|" +
      @utf8.decode_lossy(m.right) +
      ">" +
      @utf8.decode_lossy(m.merged),
    )
  }
  out.join(",")
}

///|
/// 由字符串语料构造字节语料。
fn corpus_of(texts : Array[String]) -> Array[Bytes] {
  let out : Array[Bytes] = []
  for t in texts {
    out.push(@utf8.encode(t))
  }
  out
}

///|
/// 训练用的语料：够杂，才有足够多的合并步可以比对。
let train_corpus : Array[Bytes] = corpus_of([
  "hello world hello world",
  "it's a test, isn't it?",
  "中文分词测试 中文分词",
  "1234567890 12 123 1234",
  "   leading and trailing   ",
  "emoji 👍🏽 and café",
  "fn main() { println(1) }",
  "a\nb\r\nc\r\n",
])

///|
/// 最小用例：只有一处可合并，结果唯一。
test "train: single merge on a one-word corpus" {
  let r = train(corpus_of(["aa"]), 257, 1, [])
  assert_eq(r.merges.length(), 1)
  assert_eq(show_merges(r.merges), "a|a>aa")
  assert_eq(r.vocab.token_count(), 257)
  assert_eq(r.corpus_words, 1)
}

///|
/// **tie-break 判别用例**：`"abc"` 的两处相邻 pair 频次完全相同（都是 1）。
///
/// 若按 `left` 字节序升序先取（本项目规则），第一步合并 `("a","b")`；
/// 若规则写成按 `right` 升序或"先遇到的先赢"，第一步会变成 `("b","c")`。
/// 这条测试因此能真正区分规则，而不只是复述实现。
test "train: equal frequency is broken by byte order, not by encounter order" {
  let r = train(corpus_of(["abc"]), 258, 1, [])
  assert_eq(show_merges(r.merges), "a|b>ab,ab|c>abc")
}

///|
/// **频次优先于字节序**：`("b","x")` 的 left 比 `("a","b")` 大，
/// 但频次 2 > 1，所以它必须先合并。
test "train: frequency outranks byte order" {
  let r = train(corpus_of(["bx", "bx", "ab"]), 258, 1, [])
  assert_eq(show_merges(r.merges), "b|x>bx,a|b>ab")
}

///|
/// `min_frequency` 是硬门槛：频次够不上就停下，宁可词表小于目标。
test "train: min_frequency stops early instead of padding" {
  let r = train(corpus_of(["abc"]), 4096, 2, [])
  // 两个 pair 的频次都是 1，低于 2 -> 一步都不合并，只剩 256 个单字节。
  assert_eq(r.merges.length(), 0)
  assert_eq(r.vocab.token_count(), 256)
  assert_eq(r.vocab_size, 4096)
  assert_eq(r.min_frequency, 2)
}

///|
/// **矩阵 D**：同一输入训练两次，词表必须逐字节一致。
///
/// 覆盖 5 组参数（含特殊 token、含 `min_frequency` 取 0 与取大值）。
test "train: matrix D - same input twice, byte-identical vocab (5 parameter sets)" {
  let cases : Array[(Int, Int, Array[String])] = [
    (300, 2, []),
    (512, 1, []),
    (257, 0, []),
    (1024, 5, []),
    (320, 2, ["<|endoftext|>"]),
  ]
  for entry in cases {
    let (size, min_freq, specials) = entry
    let a = train(train_corpus, size, min_freq, specials)
    let b = train(train_corpus, size, min_freq, specials)
    assert_eq(a.vocab.to_text(), b.vocab.to_text())
    assert_eq(a.merges.length(), b.merges.length())
    assert_eq(show_merges(a.merges), show_merges(b.merges))
  }
}

///|
/// 参数确实起了作用（否则上面的矩阵 D 可能只是在比对两个空词表）：
/// 目标越大合并越多，频次门槛越高合并越少。
test "train: the parameters actually shape the output" {
  let small = train(train_corpus, 257, 0, [])
  let large = train(train_corpus, 512, 0, [])
  assert_true(large.merges.length() > small.merges.length())
  let strict = train(train_corpus, 512, 4, [])
  let loose = train(train_corpus, 512, 1, [])
  assert_true(loose.merges.length() > strict.merges.length())
}

///|
/// 三段闭环：训练 -> 导出 -> 回读。回读出来的词表必须**还能编码**，
/// 而且和原词表编码结果一致——只验"能存能读"是不够的。
test "train: train -> export -> reload closes the loop" {
  let r = train(train_corpus, 512, 2, ["<|endoftext|>"])
  let text = r.vocab.to_text()
  let back = load(text)
  assert_eq(back.to_text(), text)
  assert_eq(back.token_count(), r.vocab.token_count())
  assert_eq(back.special_id("<|endoftext|>"), r.vocab.special_id("<|endoftext|>"))
  let sample = @utf8.encode("hello world 中文 123")
  let ids = r.vocab.encode_bytes(sample)
  assert_eq(back.encode_bytes(sample), ids)
  assert_eq(back.decode_ids(ids), sample)
}

///|
/// 目标大小连基座都放不下 -> 明确报错，而不是悄悄给个残缺词表。
test "train: refuses a vocab_size that cannot hold the base" {
  let empty : Array[Bytes] = []
  let mut raised = false
  try {
    ignore(train(empty, 255, 2, []))
  } catch {
    TrainSizeTooSmall(_, _) => raised = true
    _ => raised = false
  }
  assert_true(raised)
}
