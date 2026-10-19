// Blackbox 测试：只 import 根包 `@tally`，模拟真实使用者。
//
// 背景：`pub using` 只能再导出类型，不能导出枚举构造器（`Pinned` 等）。
// 若门面不提供构造器，使用者拿到 `fit` 也建不出 `Segment`。
// 这个测试守住「单包 import 即可装配」这条线，防止再退化。

///|
test "facade constructors are reachable with a single import" {
  let pinned_seg = @tally.pinned("system", "sys")
  assert_eq(pinned_seg.role, "system")
  assert_eq(pinned_seg.priority.name(), "pinned")

  let newest_seg = @tally.newest("user", "hi")
  assert_eq(newest_seg.priority.name(), "newest")

  let middle_seg = @tally.middle("history", "mid")
  assert_eq(middle_seg.priority.name(), "middle")

  let oldest_seg = @tally.oldest("history", "old")
  assert_eq(oldest_seg.priority.name(), "oldest")
}

///|
/// 计数器、窗口、截断策略也必须在单 import 下可用：
/// 类型能经 `pub using` 导出，枚举构造器不行，所以策略只能靠门面函数给。
test "single import can configure window and truncation" {
  let segments = [
    @tally.pinned("system", "sys"),
    @tally.newest("payload", "0123456789"),
  ]
  // estimate(1)：每个字节算 1 token，便于手算期望值
  let cfg = @tally
    .fit_config(@tally.estimate(1), 8L)
    .with_reserve(2L)
    .with_strategy(@tally.truncate_tail())
  let plan = try {
    @tally.fit_with(cfg, segments)
  } catch {
    _ => panic()
  }
  assert_eq(plan.window, 8L)
  assert_eq(plan.reserve, 2L)
  assert_eq(plan.limit, 6L)
  assert_eq(plan.tokens_used, 6L)
  assert_eq(plan.truncated.length(), 1)
  assert_eq(plan.truncated[0].tokens, 3L)
  assert_false(plan.exact)
}
