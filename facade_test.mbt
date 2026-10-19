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
/// README 承诺「外部 tokenizer 包一层闭包即可」：这里用字面量造一个自定义 Counter，
/// 验证它的身份进得了报告——接入方不需要 import `budget`。
test "single import can plug an external counter" {
  let counter : @tally.Counter = {
    name: "theirs/cl100k",
    exact: true,
    count_bytes: fn(bytes) { bytes.length().to_int64() },
  }
  let segments = [@tally.newest("payload", "abcdef")]
  let cfg = @tally
    .fit_config(counter, 4L)
    .with_strategy(@tally.truncate_tail())
  let plan = try {
    @tally.fit_with(cfg, segments)
  } catch {
    _ => panic()
  }
  assert_true(plan.render().contains("counter theirs/cl100k exact=true"))
  assert_eq(plan.tokens_used, 4L)
  assert_eq(plan.truncated.length(), 1)
  assert_eq(plan.truncated[0].tokens, 4L)
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

///|
/// `fit_with` 会 `raise`：错误类型必须能被单 import 的使用者写进签名。
fn propagate_error(
  cfg : @tally.FitConfig,
  segments : Array[@tally.Segment],
) -> @tally.Plan raise @tally.FitError {
  @tally.fit_with(cfg, segments)
}

///|
/// 但 `pub using` 导不出 suberror 构造器（`@tally.ReserveExceedsWindow` 报 4021），
/// 所以「显式报错」必须有一条不依赖错误类型名字的通道：`fit_with_result`。
test "single import can handle reserve errors via fit_with_result" {
  let bad = @tally.fit_config(@tally.estimate(1), 8L).with_reserve(8L)
  match @tally.fit_with_result(bad, []) {
    Ok(_) => panic()
    Err((reserve, window)) => {
      assert_eq(reserve, 8L)
      assert_eq(window, 8L)
    }
  }
  let good = @tally.fit_config(@tally.estimate(1), 4L)
  let segments = [@tally.newest("payload", "abcd")]
  match @tally.fit_with_result(good, segments) {
    Ok(plan) => {
      assert_eq(plan.tokens_used, 4L)
      assert_false(plan.overflow)
      assert_eq(plan.excess, 0L)
    }
    Err(_) => panic()
  }
}

///|
/// `raise @tally.FitError` 能写进签名（构造器仍不可命名，故 `catch` 用 `_` 兜底）。
test "single import can name FitError in a signature" {
  let cfg = @tally.fit_config(@tally.estimate(1), 8L).with_reserve(9L)
  let mut raised = false
  try {
    let _ = propagate_error(cfg, [])
  } catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
/// 截断策略的枚举构造器（`@tally.KeepSuffix` 报 4021）无法经 `pub using` 再导出，
/// 所以门面给了 `truncate_*` 函数——这条路径必须有黑盒测试钉住，
/// 否则「单 import 即可用截断」只是 ROADMAP 上的一句话。
test "single import can choose truncation strategy" {
  let segments = [
    @tally.pinned("system", "ab"),
    @tally.newest("user", "0123456789"),
  ]
  // truncate_head() = 保留段尾（KeepSuffix）：留下最近的内容
  let cfg = @tally.fit_config(@tally.estimate(1), 6L).with_strategy(
    @tally.truncate_head(),
  )
  match @tally.fit_with_result(cfg, segments) {
    Ok(plan) => {
      assert_eq(plan.kept.length(), 1)
      assert_eq(plan.truncated.length(), 1)
      assert_eq(plan.truncated[0].tokens, 4L)
      assert_eq(plan.tokens_used, 6L)
      assert_false(plan.overflow)
    }
    Err(_) => panic()
  }
  // 对照：不截断（默认）时该段整段丢弃
  match @tally.fit_with_result(
    @tally.fit_config(@tally.estimate(1), 6L).with_strategy(
      @tally.truncate_none(),
    ),
    segments,
  ) {
    Ok(plan) => {
      assert_eq(plan.truncated.length(), 0)
      assert_eq(plan.dropped.length(), 1)
    }
    Err(_) => panic()
  }
  // 三个构造器都能被单 import 的使用者命名
  let _ = @tally.truncate_tail()
  let _ = @tally.truncate_none()
  let _ = @tally.truncate_head()
}
