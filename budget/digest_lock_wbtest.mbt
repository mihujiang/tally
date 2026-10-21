// 格式冻结（T6）：`tally-digest v1` 的输出逐字节钉死。
//
// 报告的形状在根包的 `format_lock_wbtest.mbt`；这里钉的是**侧车文件**：
// 头部两行（`report` / `plan`）、`[segments]` 节、每行 `<index> <action> <sha|- >`
// 的顺序（按段下标升序，与报告的 kept→truncated→dropped 分节无关）。
//
// 为什么两侧都钉：报告改了但摘要没跟上，`verify` 会报 `ReportHashMismatch`；
// 摘要自己漂了，这里的断言先红。两处断言合起来才是"两个文件描述同一件事"。
//
// 生成 `FORMAT.lock` 的脚本从本文件抽这三个常量。

///|
/// 混合场景：两段保留、两段丢弃；丢弃段的 sha 固定为 `-`，不参与段哈希。
let frozen_digest_mixed : String =
  "tally-digest v1\n" +
  "report 4bf0f9fe4a1fb76119008608f7ba3d04584c92804e3919b81e409d1499d57ffc\n" +
  "plan 1c34c7228212ecffb3551f8f8b2b4a42a6f07dca135a0d4dd1e95daa3eee2e25\n" +
  "[segments]\n" +
  "0 kept 518b67e652531c5fe7e25d6b2c3b4ef6224e7d90da2091967dd47eb082b26a19\n" +
  "1 dropped -\n" +
  "2 dropped -\n" +
  "3 kept fa3ba64f2053ed06fc34ef5d5888983ca6ee22c7bd7d3d67d48b3faf8eac3a89\n"

///|
/// 溢出场景：哨兵行 `index == -1` 也进摘要（否则"溢出这件事"无从核对），
/// 但它不是某一段，所以 sha 同样是 `-`。
let frozen_digest_overflow : String =
  "tally-digest v1\n" +
  "report 992d453390e1eb61c6131b15cc2a0ef82e2e179a0f123b147e5a354fd370d7c7\n" +
  "plan 0a0b071c8a36f05d88b9393cf00349de2572e3aa8c8243599975b2173a1b164d\n" +
  "[segments]\n" +
  "-1 dropped -\n" +
  "0 kept 518b67e652531c5fe7e25d6b2c3b4ef6224e7d90da2091967dd47eb082b26a19\n"

///|
/// 截断场景：段哈希覆盖的是**进窗口的那部分字节**（前缀 3 字节），不是原文。
let frozen_digest_truncated : String =
  "tally-digest v1\n" +
  "report 95864c2e02dc510e8de6f1e7881cd4e99ca66db6be88464522a46523c4070c3c\n" +
  "plan ef2ca2d7f5f354114d40886ebd8b19f79969333791a681e4f7462bf95c2c446e\n" +
  "[segments]\n" +
  "0 kept 518b67e652531c5fe7e25d6b2c3b4ef6224e7d90da2091967dd47eb082b26a19\n" +
  "1 truncated ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n"

///|
test "format lock: tally-digest v1 mixed keep/drop" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "sys"),
    Segment::text("old", Oldest, "abc"),
    Segment::text("mid", Middle, "defg"),
    Segment::text("new", Newest, "hijkl"),
  ]
  let cfg = FitConfig::new(exact_counter(v), 8L)
  assert_eq(assemble(cfg, segments).render_digest(), frozen_digest_mixed)
}

///|
test "format lock: tally-digest v1 pinned overflow" {
  let v = byte_vocab()
  let segments = [Segment::text("system", Pinned, "sys")]
  let cfg = FitConfig::new(exact_counter(v), 1L)
  assert_eq(assemble(cfg, segments).render_digest(), frozen_digest_overflow)
}

///|
test "format lock: tally-digest v1 truncation" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "sys"),
    Segment::text("payload", Newest, "abcdefghij"),
  ]
  let cfg = FitConfig::new(exact_counter(v), 8L)
    .with_reserve(2L)
    .with_strategy(KeepPrefix)
  assert_eq(fit_with(cfg, segments).render_digest(), frozen_digest_truncated)
}

///|
/// 摘要与报告必须同源：拿同一份计划渲染两次，摘要逐字节相同（不变量 V15 的侧车版）。
test "format lock: digest is deterministic" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "sys"),
    Segment::text("old", Oldest, "abc"),
  ]
  let cfg = FitConfig::new(exact_counter(v), 8L)
  let a = assemble(cfg, segments)
  let b = assemble(cfg, segments)
  assert_eq(a.render_digest(), b.render_digest())
}
