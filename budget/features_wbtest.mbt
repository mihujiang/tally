// 1.0 三项增量的行为测试（不止冻结格式，还要冻结语义）。

///|
/// 借用：tools 需求 4 / 配额 3，history 需求 2 / 配额 5 ⇒ tools 借 1，
/// 两池都不裁段，台账逐项对得上。
test "pool: shortfall borrows from a declared pool in declaration order" {
  let v = byte_vocab()
  let segments = [
    Segment::text("tools", Newest, "abcd").with_pool("tools"),
    Segment::text("history", Oldest, "ef").with_pool("history"),
  ]
  let cfg = FitConfig::new(exact_counter(v), 8L).with_pools([
    PoolQuota::new("tools", 3L),
    PoolQuota::new("history", 5L),
  ])
  let plan = fit_with(cfg, segments)
  assert_eq(plan.tokens_used, 6L)
  assert_eq(plan.pools.length(), 2)
  assert_eq(plan.pools[0].quota, 3L)
  assert_eq(plan.pools[0].demand, 4L)
  assert_eq(plan.pools[0].used, 4L)
  assert_eq(plan.pools[0].borrowed, 1L)
  assert_eq(plan.pools[0].lent, 0L)
  assert_eq(plan.pools[1].used, 2L)
  assert_eq(plan.pools[1].lent, 1L)
  // 借用不改变总占用：仍是 6。
  assert_eq(plan.dropped.length(), 0)
  assert_eq(plan.truncated.length(), 0)
}

///|
/// 无可借余额时，池内自己裁：整体预算够（10），但 tools 只有 2，
/// 于是把 6 token 的段截到 2，并给出「池配额不足」的原因。
test "pool: without spare the pool is cut internally, with a pool reason" {
  let v = byte_vocab()
  let segments = [Segment::text("tools", Newest, "abcdef").with_pool("tools")]
  let cfg = FitConfig::new(exact_counter(v), 10L)
    .with_strategy(KeepPrefix)
    .with_pools([PoolQuota::new("tools", 2L)])
  let plan = fit_with(cfg, segments)
  assert_eq(plan.truncated.length(), 1)
  assert_eq(plan.truncated[0].tokens, 2L)
  assert_eq(plan.truncated[0].omitted, 4L)
  assert_eq(plan.pools[0].used, 2L)
  assert_eq(plan.tokens_used, 2L)
}

///|
/// 池配额花光且策略是整段丢时，丢弃原因要指向池，而不是笼统地说"预算不够"。
test "pool: exhausted quota drops with a pool-specific reason" {
  let v = byte_vocab()
  let segments = [
    Segment::text("tools", Newest, "abcdef").with_pool("tools"),
    Segment::text("history", Oldest, "gh").with_pool("history"),
  ]
  let cfg = FitConfig::new(exact_counter(v), 10L).with_pools([
    PoolQuota::new("tools", 2L),
    PoolQuota::new("history", 0L),
  ])
  let plan = fit_with(cfg, segments)
  // tools 超额、history 配额 0：先按声明顺序裁 tools（原因指明池名），
  // tools 让出的额度随后被 history 借走（借用规则透明）。
  assert_eq(plan.dropped.length(), 1)
  assert_eq(plan.dropped[0].role, "tools")
  assert_true(plan.dropped[0].reason.contains("池 tools"))
  assert_eq(plan.pools[0].lent, 2L)
  assert_eq(plan.pools[1].borrowed, 2L)
  assert_eq(plan.pools[1].used, 2L)
}

///|
/// 同优先级内，分数低的先走；分数高的留下。
test "score: the lower score is sacrificed first within a priority" {
  let v = byte_vocab()
  let segments = [
    Segment::text("low", Newest, "aaaa").with_score(1L),
    Segment::text("high", Newest, "bbbb").with_score(9L),
  ]
  let plan = fit_with(FitConfig::new(exact_counter(v), 4L), segments)
  assert_eq(plan.kept.length(), 1)
  assert_eq(plan.kept[0].role, "high")
  assert_eq(plan.dropped.length(), 1)
  assert_eq(plan.dropped[0].role, "low")
}

///|
/// 压缩：标记带省略量、总量不越界、报告与正文对得上。
test "compress: marker carries the omitted count and respects the budget" {
  let v = byte_vocab()
  let payload = "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij"
  let segments = [
    Segment::text("system", Pinned, "sys"),
    Segment::text("payload", Newest, payload),
  ]
  let plan = fit_with(
    FitConfig::new(exact_counter(v), 60L).with_strategy(Compress),
    segments,
  )
  assert_eq(plan.tokens_used, 60L)
  assert_eq(plan.truncated.length(), 1)
  let t = plan.truncated[0]
  assert_eq(t.tokens, 57L)
  // 80 字节里保留了 23 字节 ⇒ 省略 57。
  assert_eq(t.omitted, 57L)
  assert_eq(t.bytes.length(), 57)
  // 标记以换行收尾，说明尾部被标记占据。
  assert_eq(t.bytes.unsafe_get(t.bytes.length() - 1).to_int(), 10)
}

///|
/// 兼容：`parse_report` 仍然读得懂 0.x 的 `tally-plan v2` 文本。
test "digest: tally-plan v2 reports still parse" {
  let v2 = "tally-plan v2\ncounter cl100k_base exact=true\nwindow 8\n" +
    "reserve 0\ninput_limit 8\nused 3\npinned 3\noverflow false\n" +
    "[kept]\n0 pinned system 3\n[truncated]\n1 newest payload 10->3 prefix\n" +
    "[dropped]\n"
  let facts = parse_report(v2) catch {
    _ => abort("tally-plan v2 must stay readable")
  }
  assert_eq(facts.segments.length(), 2)
}
