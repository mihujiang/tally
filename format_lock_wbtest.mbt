// 格式冻结（T5）：`tally-plan v2` 的**输出格式**逐字节钉死。
//
// 这里冻结的是报告文本的形状：首行版本标识、计数器身份、窗口三行、字段顺序与分隔、
// 优先级名称、截断模式名、丢弃原因原文、行尾 `\n`。任何一处改动都会让 diff 变红，
// 逼人显式确认。
//
// 词表格式的冻结在 `vocab/format_lock_wbtest.mbt`（夹具在那里）。
// 随包分发：使用方可以自己复跑这些断言。

///|
/// 混合场景：Pinned 保底、Oldest 先丢、Middle 次之、Newest 最后才牺牲。
let frozen_plan_mixed : String =
  "tally-plan v2\n" +
  "counter cl100k_base exact=true\n" +
  "window 8\n" +
  "reserve 0\n" +
  "input_limit 8\n" +
  "used 8\n" +
  "pinned 3\n" +
  "overflow false\n" +
  "[kept]\n" +
  "0 pinned system 3\n" +
  "3 newest new 5\n" +
  "[truncated]\n" +
  "[dropped]\n" +
  "1 oldest old 3 为满足预算而丢弃（最早的历史，最先牺牲）\n" +
  "2 middle mid 4 为满足预算而丢弃（优先级低于 Newest）\n"

///|
/// 溢出场景：只剩 Pinned 还装不下，必须显式上报而不是悄悄超限。
let frozen_plan_overflow : String =
  "tally-plan v2\n" +
  "counter cl100k_base exact=true\n" +
  "window 1\n" +
  "reserve 0\n" +
  "input_limit 1\n" +
  "used 3\n" +
  "pinned 3\n" +
  "overflow true\n" +
  "[kept]\n" +
  "0 pinned system 3\n" +
  "[truncated]\n" +
  "[dropped]\n" +
  "-1 pinned *overflow* 2 Pinned 段本身超过 limit；请增大窗口或缩短 system 提示/工具定义\n"

///|
/// 截断场景：窗口 8、预留 2，输入预算 6；10 token 的段被截到 3 token（保留段首）。
let frozen_plan_truncated : String =
  "tally-plan v2\n" +
  "counter cl100k_base exact=true\n" +
  "window 8\n" +
  "reserve 2\n" +
  "input_limit 6\n" +
  "used 6\n" +
  "pinned 3\n" +
  "overflow false\n" +
  "[kept]\n" +
  "0 pinned system 3\n" +
  "[truncated]\n" +
  "1 newest payload 10->3 prefix\n" +
  "[dropped]\n"

///|
test "format lock: tally-plan v2 mixed keep/drop" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "sys"),
    Segment::text("old", Oldest, "abc"),
    Segment::text("mid", Middle, "defg"),
    Segment::text("new", Newest, "hijkl"),
  ]
  assert_eq(fit(v, segments, 8L).render(), frozen_plan_mixed)
}

///|
test "format lock: tally-plan v2 pinned overflow" {
  let v = byte_vocab()
  let segments = [Segment::text("system", Pinned, "sys")]
  assert_eq(fit(v, segments, 1L).render(), frozen_plan_overflow)
}

///|
test "format lock: tally-plan v2 truncation" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "sys"),
    Segment::text("payload", Newest, "abcdefghij"),
  ]
  let cfg = FitConfig::new(cl100k(v), 8L)
    .with_reserve(2L)
    .with_strategy(KeepPrefix)
  assert_eq(fit_with(cfg, segments).render(), frozen_plan_truncated)
}

///|
/// 渲染必须稳定：同样的输入两次渲染逐字节相同（不变量 V15）。
test "format lock: render is deterministic" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "sys"),
    Segment::text("old", Oldest, "abc"),
  ]
  assert_eq(fit(v, segments, 8L).render(), fit(v, segments, 8L).render())
}
