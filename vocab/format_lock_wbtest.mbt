// 格式冻结（T5）：`tally-vocab v1` 的**输出格式**逐字节钉死。
//
// 冻结的是格式，不是行为：多一个空格、换行方式变化、字段顺序变化、
// `# unicode` 行漏写，都会在这里失败。
//
// 夹具 `sample_vocab_text` 由 `tools/gen_sample_vocab.py` 生成，
// 它写的 `# unicode` 行必须和 `Vocab::to_text()` 读到的实际版本一致。
// 随包分发：使用方可以自己复跑这些断言。

///|
test "format lock: tally-vocab v1 header is frozen" {
  assert_eq(format_header, "# tally-vocab v1")
  let v = load(sample_vocab_text)
  assert_eq(v.token_count(), 277)
  assert_eq(v.special_literals().length(), 1)
}

///|
/// 导出必须逐字节回到夹具本身（不变量 V10 + 格式冻结）。
/// 这条一旦失败就说明「格式漂移」或「导出不稳定」，两者都要停下查。
test "format lock: to_text round-trips the fixture byte for byte" {
  let v = load(sample_vocab_text)
  assert_eq(v.to_text(), sample_vocab_text)
}

///|
/// 再走一轮：导出 -> 加载 -> 再导出，仍逐字节相同。
/// 单轮相等可能是巧合（比如两边都漏了同一行），两轮才能排除。
test "format lock: to_text is a fixed point" {
  let once = load(sample_vocab_text).to_text()
  let twice = load(once).to_text()
  assert_eq(twice, once)
}
