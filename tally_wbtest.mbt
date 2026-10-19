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

///|
/// 只走门面构造器（`pinned` / `oldest`）也应完成装配：
/// 外部使用者只有一个 import 时，必须能自己把段建出来。
test "facade segment constructors" {
  let v = byte_vocab()
  let segments = [
    pinned("system", "sys"),
    oldest("history", "0123456789"),
  ]
  let plan = fit(v, segments, 5L)
  assert_eq(plan.tokens_used, 3L)
  assert_false(plan.overflow)
  assert_eq(plan.dropped.length(), 1)
}

///|
/// 门面窗口模型与截断：`window = reserve + input_limit`，超出的段按策略截短。
test "facade window and truncation" {
  let v = byte_vocab()
  let segments = [
    pinned("system", "sys"),
    newest("payload", "0123456789"),
  ]
  let cfg = fit_config(cl100k(v), 8L)
    .with_reserve(2L)
    .with_strategy(truncate_tail())
  let plan = try {
    fit_with(cfg, segments)
  } catch {
    _ => panic()
  }
  assert_eq(plan.window, 8L)
  assert_eq(plan.reserve, 2L)
  assert_eq(plan.limit, 6L)
  assert_eq(plan.tokens_used, 6L)
  assert_eq(plan.truncated.length(), 1)
  assert_eq(plan.truncated[0].original_tokens, 10L)
  assert_eq(plan.truncated[0].tokens, 3L)
  assert_eq(plan.truncated[0].bytes, @utf8.encode("012"))
}

///|
/// `cl100k` 适配器住在门面包：身份、精确性、计数都必须与词表直算一致。
test "facade cl100k counter matches direct counting" {
  let v = byte_vocab()
  let counter = cl100k(v)
  assert_eq(counter.name, "cl100k_base")
  assert_true(counter.exact)
  let bytes = @utf8.encode("hello 世界")
  assert_eq(counter.count(bytes), count_bytes(v, bytes))
  assert_eq(counter.count(bytes), bytes.length().to_int64())
}

///|
/// 0.3 入口与新入口同语义：除调用方式外输出逐字节相同。
test "compat fit equals explicit config" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "sys"),
    Segment::text("old", Oldest, "abc"),
    Segment::text("new", Newest, "defgh"),
  ]
  let a = fit(v, segments, 6L)
  let b = try {
    fit_with(fit_config(cl100k(v), 6L), segments)
  } catch {
    _ => panic()
  }
  assert_eq(a.render(), b.render())
}

///|
/// 0.3 入口不校验预算：`limit = 0` 时保持「全部丢弃、Pinned 溢出上报」，
/// 而不是让 `reserve >= window` 的校验把它变成一次报错。
test "compat fit keeps zero-budget semantics" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "sys"),
    Segment::text("old", Oldest, "abc"),
  ]
  let plan = fit(v, segments, 0L)
  assert_true(plan.overflow)
  assert_eq(plan.limit, 0L)
  assert_eq(plan.tokens_used, 3L)
  assert_eq(plan.excess, 3L)
  assert_eq(plan.dropped.length(), 2)
  assert_eq(plan.dropped[1].index, -1)
}

///|
/// 估算计数器经门面同样自曝：`exact=false` 进报告。
test "facade estimate counter is honest" {
  let segments = [newest("payload", "abcdefgh")]
  let plan = try {
    fit_with(fit_config(estimate(4), 4L), segments)
  } catch {
    _ => panic()
  }
  assert_false(plan.exact)
  assert_true(plan.render().contains("counter estimate@4 exact=false"))
}

///|
/// 门面训练闭环：训练 -> 导出产物 -> 回读 -> 词表还能编码，且两次训练一致。
test "facade reproducible training" {
  let corpus = [@utf8.encode("hello world"), @utf8.encode("hello 世界")]
  let a = train(corpus, 280, 1, ["<|endoftext|>"])
  let b = train(corpus, 280, 1, ["<|endoftext|>"])
  assert_eq(a.to_text(), b.to_text())
  let back = load_train(a.to_text())
  assert_eq(back.vocab.to_text(), a.vocab.to_text())
  assert_eq(back.merges.length(), a.merges.length())
  let bytes = @utf8.encode("hello world")
  assert_eq(back.vocab.encode_bytes(bytes), a.vocab.encode_bytes(bytes))
}
