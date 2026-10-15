// 矩阵 A：逐 token 对齐参考实现。
//
// 语料与期望 id 由 `tools/gen_alignment_golden.py` 从参考实现
// （tiktoken 0.14.0，cl100k_base）生成，其中**包含参考实现自带测试
// （tests/test_encoding.py）里的每一个字面量**，另加覆盖性用例与交叉拼接。
//
// 词表是 cl100k_base 的「语料切片」：只保留语料可能查到的条目。
// 之所以成立：byte-level BPE 只合并输入中**相邻**的片段，所以它查的每个键
// 都是输入的子串；含全部语料子串的切片与完整词表行为一致。生成器在写出
// 切片之前已逐条验证过这个等价性（2,935 条语料、16,273 个 token 全部一致）。
//
// 切片内嵌时用**紧凑 id**（参考 id 稀疏，而 `load_tiktoken` 要求 id 连续），
// 所以这里先把 `encode` 的结果经 `cl100k_slice_real_id` 映回参考 id 再比对。
// 这一步由生成器验证过：映射后的序列与参考逐 token 一致。

///|
/// 把切片本地 id 序列映回参考实现的 id 序列。
fn to_reference(ids : Array[Int]) -> Array[Int] {
  ids.map(fn(id) { cl100k_slice_real_id[id] })
}

///|
test "matrix A: encode reproduces the reference token-for-token" {
  let vocab = load_tiktoken(cl100k_slice_text, [])
  assert_eq(alignment_corpus.length(), alignment_golden.length())
  let mut bad = 0
  let mut first = -1
  for i = 0; i < alignment_corpus.length(); i = i + 1 {
    if to_reference(encode(vocab, alignment_corpus[i])) != alignment_golden[i] {
      bad = bad + 1
      if first < 0 {
        first = i
      }
    }
  }
  if bad > 0 {
    println("matrix A mismatches: " + bad.to_string() + ", first index " + first.to_string())
  }
  assert_eq(bad, 0)
}

///|
test "matrix A: decode round-trips every corpus entry" {
  let vocab = load_tiktoken(cl100k_slice_text, [])
  for i = 0; i < alignment_corpus.length(); i = i + 1 {
    let ids = encode(vocab, alignment_corpus[i])
    assert_eq(decode(vocab, ids), alignment_corpus[i])
  }
}

///|
test "matrix A: count matches the reference token counts" {
  let vocab = load_tiktoken(cl100k_slice_text, [])
  for i = 0; i < alignment_corpus.length(); i = i + 1 {
    let expected = Int64::from_int(alignment_golden[i].length())
    assert_eq(count_bytes(vocab, alignment_corpus[i]), expected)
  }
}

///|
test "matrix A: the corpus is the size the plan asked for" {
  // V0.2 要求矩阵 A **全量** ≥ 2000 条；这里连切片的规模一起钉住，
  // 免得有人悄悄缩小语料让测试变绿。
  assert_eq(alignment_corpus.length(), 2935)
  assert_true(alignment_corpus.length() >= 2000)
  assert_eq(cl100k_slice_real_id.length(), 1329)
  assert_true(cl100k_slice_text.length() > 16000)
}
