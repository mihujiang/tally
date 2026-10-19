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
