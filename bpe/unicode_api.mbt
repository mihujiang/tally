// 把 Unicode 表的元信息透出给上层，避免上层直接依赖 `bpe/unicode`。

///|
/// 生成表时所用的 Unicode 版本（写入 README 与报告，保证可复算）。
pub fn unicode_version() -> String {
  @unicode.unicode_version
}

///|
/// (字母, 数字, 空白) 三类区间表的条数。
pub fn unicode_table_sizes() -> (Int, Int, Int) {
  @unicode.table_sizes()
}
