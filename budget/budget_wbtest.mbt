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
/// 词表计数器：`Counter::cl100k` 已上移门面包（`budget` 不再依赖 `vocab`），
/// 但预算层测试仍要「真实 token 数」，所以在这里本地包一层。
fn exact_counter(v : @vocab.Vocab) -> Counter {
  {
    name: "cl100k_base",
    exact: true,
    count_bytes: fn(bytes) { @vocab.Vocab::count_bytes(v, bytes) },
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
  let plan = assemble(FitConfig::new(exact_counter(v), 12L), segments)
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
  let plan = assemble(FitConfig::new(exact_counter(v), 4L), segments)
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
  let plan = assemble(FitConfig::new(exact_counter(v), 3L), segments)
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
  let plan = assemble(FitConfig::new(exact_counter(v), 100L), segments)
  let a = plan.render()
  let b = plan.render()
  assert_eq(a, b)
  assert_true(a.contains("tally-plan v2"))
  assert_true(a.contains("counter cl100k_base exact=true"))
  assert_false(plan.overflow)
  assert_eq(plan.dropped.length(), 0)
}

///|
/// 估算计数器：身份、精确性标注，以及**按字符而不是按字节**。
test "estimate counts characters, not bytes" {
  let est = Counter::estimate(4)
  assert_false(est.exact)
  assert_eq(est.name, "estimate@4")
  assert_eq(est.count(@utf8.encode("abcdefgh")), 2L)
  // 向上取整：5 个字符 / 4 = 2
  assert_eq(est.count(@utf8.encode("abcde")), 2L)
  // 「世界」= 2 个字符 / 6 个字节：按字符算是 1，按字节算会得 2
  assert_eq(est.count(@utf8.encode("世界")), 1L)
  assert_eq(Counter::estimate(1).count(@utf8.encode("世界")), 2L)
  // 非法参数回落默认值，不抛错
  assert_eq(Counter::estimate(0).name, "estimate@4")
}

///|
/// 估算计数器必须自曝：报告里 `exact=false`，不允许冒充精确。
test "estimate counter is marked inexact in report" {
  let segments = [Segment::text("payload", Newest, "abcdefgh")]
  let plan = fit_with(FitConfig::new(Counter::estimate(4), 4L), segments)
  assert_false(plan.exact)
  assert_true(plan.render().contains("counter estimate@4 exact=false"))
}

///|
/// 窗口模型：`window = reserve + input_limit`，预留不占输入预算。
test "reserve shrinks the input limit" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "sys"),
    Segment::text("payload", Newest, "abcdefghij"),
  ]
  let cfg = FitConfig::new(exact_counter(v), 8L).with_reserve(2L)
  let plan = fit_with(cfg, segments)
  assert_eq(plan.window, 8L)
  assert_eq(plan.reserve, 2L)
  assert_eq(plan.limit, 6L)
  // 默认策略是整段丢：10 token 的 payload 放不进 6，直接丢，只剩 Pinned 的 3
  assert_eq(plan.tokens_used, 3L)
  assert_eq(plan.dropped.length(), 1)
  assert_true(plan.render().contains("input_limit 6"))
}

///|
/// 预留吃掉整个窗口时显式报错，而不是把可用空间算成负数。
test "reserve that swallows the window is rejected" {
  let v = byte_vocab()
  let cfg = FitConfig::new(exact_counter(v), 8L).with_reserve(8L)
  let mut bad = true
  try {
    let _ = fit_with(cfg, [])
  } catch {
    ReserveExceedsWindow(r, w) => {
      assert_eq(r, 8L)
      assert_eq(w, 8L)
      bad = false
    }
  }
  assert_false(bad)
}

///|
/// 截断：保留段首，装到刚好等于预算；截断量与原量都写进报告。
test "truncate keeps the prefix and lands on the limit" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "sys"),
    Segment::text("payload", Newest, "0123456789"),
  ]
  let plan = fit_with(
    FitConfig::new(exact_counter(v), 8L).with_strategy(KeepPrefix),
    segments,
  )
  assert_eq(plan.tokens_used, 8L)
  assert_eq(plan.kept.length(), 1)
  assert_eq(plan.truncated.length(), 1)
  assert_eq(plan.dropped.length(), 0)
  let t = plan.truncated[0]
  assert_eq(t.original_tokens, 10L)
  assert_eq(t.tokens, 5L)
  assert_eq(t.strategy, KeepPrefix)
  assert_eq(t.bytes, @utf8.encode("01234"))
  assert_true(plan.render().contains("1 newest payload 10->5 prefix"))
}

///|
/// 截断：保留段尾，适合「最近最重要」的历史。
test "truncate keeps the suffix" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "sys"),
    Segment::text("payload", Newest, "0123456789"),
  ]
  let plan = fit_with(
    FitConfig::new(exact_counter(v), 8L).with_strategy(KeepSuffix),
    segments,
  )
  assert_eq(plan.tokens_used, 8L)
  let t = plan.truncated[0]
  assert_eq(t.tokens, 5L)
  assert_eq(t.strategy, KeepSuffix)
  assert_eq(t.bytes, @utf8.encode("56789"))
  assert_true(plan.render().contains("1 newest payload 10->5 suffix"))
}

///|
/// 截断不切半个字符：中文 3 字节一个，切点回退到字符边界。
test "truncation respects UTF-8 boundaries" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "sys"),
    Segment::text("payload", Newest, "世界"),
  ]
  let plan = fit_with(
    FitConfig::new(exact_counter(v), 6L).with_strategy(KeepPrefix),
    segments,
  )
  let t = plan.truncated[0]
  assert_eq(t.tokens, 3L)
  assert_eq(t.bytes, @utf8.encode("世"))
  assert_eq(plan.tokens_used, 6L)
}

///|
/// 截不动（目标为 0）时退化为整段丢：只要「丢弃」这一种解释。
test "truncation falls back to dropping when nothing fits" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "sys"),
    Segment::text("payload", Newest, "abcdefghij"),
  ]
  let plan = fit_with(
    FitConfig::new(exact_counter(v), 3L).with_strategy(KeepPrefix),
    segments,
  )
  assert_eq(plan.truncated.length(), 0)
  assert_eq(plan.dropped.length(), 1)
  assert_eq(plan.dropped[0].tokens, 10L)
  assert_eq(plan.tokens_used, 3L)
}

///|
/// 矩阵 G：任意 limit × 任意策略 × 若干段落形状，不变量都必须成立。
///
/// 覆盖：`used` 恒等于 kept+truncated 之和；不溢出时 `used <= limit`；
/// Pinned 段永不截断；渲染可重复。
test "matrix G: invariants hold across limits and strategies" {
  let v = byte_vocab()
  let counter = exact_counter(v)
  let strategies = [NoTruncate, KeepPrefix, KeepSuffix]
  let shapes = [
    [
      Segment::text("system", Pinned, "sys"),
      Segment::text("old", Oldest, "abc"),
      Segment::text("new", Newest, "defgh"),
    ],
    [
      Segment::text("system", Pinned, "sys"),
      Segment::text("user", Newest, "0123456789abcdef"),
    ],
    [Segment::text("only", Middle, "abcdef")],
    [
      Segment::text("system", Pinned, "sys"),
      Segment::text("tools", Pinned, "ab"),
      Segment::text("user", Newest, "世界你好"),
    ],
  ]
  let mut cases = 0
  for shape in shapes {
    for strategy in strategies {
      for limit = 1; limit <= 14; limit = limit + 1 {
        let cfg = FitConfig::new(counter, limit.to_int64()).with_strategy(
          strategy,
        )
        let plan = fit_with(cfg, shape)
        cases = cases + 1
        let mut used : Int64 = 0
        for k in plan.kept {
          used = used + k.tokens
        }
        for t in plan.truncated {
          used = used + t.tokens
        }
        assert_eq(plan.tokens_used, used)
        if !plan.overflow {
          assert_true(plan.tokens_used <= plan.limit)
          assert_eq(plan.excess, 0L)
        } else {
          // 溢出量必须与「用超了多少」对得上，且只有 Pinned 能撑爆窗口
          assert_eq(plan.excess, plan.tokens_used - plan.limit)
          assert_eq(plan.pinned_tokens, plan.tokens_used)
        }
        // Pinned 段只可能整段保留，绝不截断
        for k in plan.kept {
          if k.priority == Pinned {
            assert_eq(k.tokens, counter.count(k.bytes))
          }
        }
        for t in plan.truncated {
          assert_true(t.priority != Pinned)
          assert_true(t.tokens < t.original_tokens)
          assert_true(t.tokens > 0L)
        }
        assert_eq(plan.render(), plan.render())
      }
    }
  }
  assert_true(cases >= 40)
}

