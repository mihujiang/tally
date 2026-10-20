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
  "report d7dd9d5b3be1ca3b079fa999cabbf0b613e5a14c8514fea856dbbc329ba9acbe\n" +
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
  "report 317c0e78e5a7d403982f7bc1d39594b489db6da04cbea75ab88a21f498d66662\n" +
  "plan 0a0b071c8a36f05d88b9393cf00349de2572e3aa8c8243599975b2173a1b164d\n" +
  "[segments]\n" +
  "-1 dropped -\n" +
  "0 kept 518b67e652531c5fe7e25d6b2c3b4ef6224e7d90da2091967dd47eb082b26a19\n"

///|
/// 截断场景：段哈希覆盖的是**进窗口的那部分字节**（前缀 3 字节），不是原文。
let frozen_digest_truncated : String =
  "tally-digest v1\n" +
  "report 78b45e9a03b4464202decb31cc4ccbcb551312ec8a12db6a1f4050c3127efadf\n" +
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
