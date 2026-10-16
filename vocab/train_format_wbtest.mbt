// 训练产物的格式稳定性。
//
// 「导出 -> 回读 -> 再导出」必须是**不动点**，否则冻结下来的就不是格式，
// 而是某一次运行的偶然输出。负面用例都配了正面对照，免得拒绝逻辑空转。

///|
/// 手写产物的头部。
///
/// `# unicode` 行必须跟上真实版本，否则"导出即原文"就不成立——
/// 这一行是真实的格式依赖，不是装饰。
let minimal_train_header : String =
  "# tally-train v1\n" +
  "# unicode " +
  @bpe.unicode_version() +
  "\n" +
  "# corpus_bytes 2\n" +
  "# corpus_words 1\n" +
  "# vocab_size 257\n" +
  "# min_frequency 1\n" +
  "# tokens 257\n"

///|
/// 一份手写的最小合法产物：256 个基座 + 一次合并 `("a","b") -> "ab"`。
/// 段顺序按 id 升序：先 `[merges]`（256 起），再 `[specials]`。
let minimal_train_artifact : String =
  minimal_train_header + "[merges]\n256 YWI= YQ== Yg==\n[specials]\n"

///|
/// 正面对照：手写产物能回读，且再导出与原文逐字节相同。
test "train artifact: a hand-written artifact round-trips byte for byte" {
  let r = load_train(minimal_train_artifact)
  assert_eq(r.merges.length(), 1)
  assert_eq(r.vocab.token_count(), 257)
  assert_eq(r.corpus_bytes, 2)
  assert_eq(r.corpus_words, 1)
  assert_eq(r.vocab_size, 257)
  assert_eq(r.min_frequency, 1)
  assert_eq(r.to_text(), minimal_train_artifact)
}

///|
/// 训练出来的产物同样是回读不动点，且参数、合并、词表都原样带回来。
test "train artifact: train -> export -> load -> export is a fixed point" {
  let r = train(train_corpus, 320, 2, ["<|endoftext|>"])
  let text = r.to_text()
  assert_true(text.has_prefix(train_format_header))
  let back = load_train(text)
  assert_eq(back.to_text(), text)
  assert_eq(back.vocab.to_text(), r.vocab.to_text())
  assert_eq(back.merges.length(), r.merges.length())
  assert_eq(back.corpus_bytes, r.corpus_bytes)
  assert_eq(back.corpus_words, r.corpus_words)
  assert_eq(back.vocab_size, r.vocab_size)
  assert_eq(back.min_frequency, r.min_frequency)
  assert_eq(back.vocab.encode_bytes(@utf8.encode("hello 中文")),
    r.vocab.encode_bytes(@utf8.encode("hello 中文")))
}

///|
/// `merged` 必须真的等于 `left ++ right`：手改成 `bz` 就该被拒。
test "train artifact: rejects a merge whose merged != left + right" {
  let text = minimal_train_header + "[merges]\n256 Yno= YQ== Yg==\n"
  let mut raised = false
  try {
    ignore(load_train(text))
  } catch {
    MalformedLine(_, _) => raised = true
    _ => raised = false
  }
  assert_true(raised)
}

///|
/// 合并的 rank 必须从 256 起稠密升序：跳过一位就是坏掉的产物。
test "train artifact: rejects a non-dense merge rank" {
  let text = minimal_train_header + "[merges]\n257 YWI= YQ== Yg==\n"
  let mut raised = false
  try {
    ignore(load_train(text))
  } catch {
    MalformedLine(_, _) => raised = true
    _ => raised = false
  }
  assert_true(raised)
}

///|
/// `# tokens` 是冗余字段，回读时要拿重建结果核对：谎报 token 数必须被抓住。
test "train artifact: rejects a lying token count" {
  let text = minimal_train_artifact.replace(old="# tokens 257", new="# tokens 300")
  let mut raised = false
  try {
    ignore(load_train(text))
  } catch {
    MalformedLine(_, _) => raised = true
    _ => raised = false
  }
  assert_true(raised)
}
