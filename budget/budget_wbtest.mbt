// 预算层测试：丢弃顺序、Pinned 保护、溢出上报、报告稳定性。

///|
fn byte_vocab() -> @vocab.Vocab {
  let tokens : Array[Bytes] = []
  let ranks : Map[Bytes, Int] = Map([])
  for b = 0; b < 256; b = b + 1 {
    let one = Bytes::make(1, b.to_byte())
    tokens.push(one)
    ranks.set(one, b)
  }
  try @vocab.build_vocab(tokens, ranks, []) catch {
    _ => panic()
  }
}

///|
test "lowest priority is dropped first, pinned survives (V14)" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "aaaa"),
    Segment::text("old", Oldest, "bbbb"),
    Segment::text("mid", Middle, "cccc"),
    Segment::text("new", Newest, "dddd"),
  ]
  let plan = fit(v, segments, 12L)
  assert_eq(plan.tokens_used, 12L)
  assert_false(plan.overflow)
  assert_eq(plan.kept.length(), 3)
  assert_eq(plan.dropped.length(), 1)
  assert_eq(plan.dropped[0].role, "old")
  // 保留下来的段按原始顺序出现
  assert_eq(plan.kept[0].role, "system")
  assert_eq(plan.kept[1].role, "mid")
  assert_eq(plan.kept[2].role, "new")
}

///|
test "drop order is deterministic when weights tie" {
  let v = byte_vocab()
  let segments = [
    Segment::text("a", Oldest, "aaaa"),
    Segment::text("b", Oldest, "bbbb"),
    Segment::text("c", Oldest, "cccc"),
  ]
  let plan = fit(v, segments, 4L)
  assert_eq(plan.tokens_used, 4L)
  // 并列时丢下标最小的（更早的历史）
  assert_eq(plan.dropped[0].role, "a")
  assert_eq(plan.dropped[1].role, "b")
}

///|
test "pinned overflow is reported, not silently over budget (V13)" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "aaaaaaaa"),
    Segment::text("new", Newest, "bbbb"),
  ]
  let plan = fit(v, segments, 3L)
  assert_true(plan.overflow)
  // 只剩 Pinned，仍然超限：必须显式说明
  assert_eq(plan.tokens_used, 8L)
  assert_true(plan.render().contains("Pinned"))
  assert_eq(plan.kept.length(), 1)
  assert_eq(plan.kept[0].role, "system")
}

///|
test "report is canonical and stable (V15)" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "hi"),
    Segment::text("old", Oldest, "bye"),
  ]
  let plan = fit(v, segments, 100L)
  let a = plan.render()
  let b = plan.render()
  assert_eq(a, b)
  assert_true(a.contains("tally-plan v1"))
  assert_false(plan.overflow)
  assert_eq(plan.dropped.length(), 0)
}
