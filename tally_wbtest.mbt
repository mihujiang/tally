// 门面端到端测试：只依赖根包，验证四层拼起来是通的。

///|
fn byte_vocab() -> Vocab {
  let tokens : Array[Bytes] = []
  let ranks : Map[Bytes, Int] = Map([])
  for b = 0; b < 256; b = b + 1 {
    let one = Bytes::make(1, b.to_byte())
    tokens.push(one)
    ranks.set(one, b)
  }
  try build_vocab(tokens, ranks, []) catch {
    _ => panic()
  }
}

///|
test "facade end to end" {
  let v = byte_vocab()
  let text = "hello 世界"
  let bytes = @utf8.encode(text)
  assert_eq(count(v, text), bytes.length().to_int64())
  assert_true(decode(v, encode_string(v, text)) == bytes)
  assert_eq(count_bytes(v, bytes), bytes.length().to_int64())
}

///|
test "facade budget flow" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "sys"),
    Segment::text("history", Oldest, "0123456789"),
  ]
  let plan = fit(v, segments, 5L)
  assert_eq(plan.tokens_used, 3L)
  assert_false(plan.overflow)
  assert_eq(plan.dropped.length(), 1)
  assert_true(unicode_version().length() > 0)
}
