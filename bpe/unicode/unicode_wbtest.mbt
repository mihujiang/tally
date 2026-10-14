// Unicode 表的抽查与"冻结"测试。
//
// 冻结断言（版本 + 区间条数）是为了让**表数据漂移一定会红**：
// 一旦数据源（参考实现所用的 `regex` 引擎，见 tools/gen_unicode.py）升级，
// 或生成配方变了，这里必须显式更新，而不是悄悄通过。

///|
test "letter class" {
  assert_true(is_letter(0x41)) // 'A'
  assert_true(is_letter(0x7A)) // 'z'
  assert_true(is_letter(0x4E2D)) // '中'
  assert_true(is_letter(0x03B1)) // 'α'
  assert_false(is_letter(0x31)) // '1'
  assert_false(is_letter(0x20)) // ' '
  assert_false(is_letter(0x1F600)) // 表情符号
  assert_false(is_letter(0x110000)) // 超出码点范围
}

///|
test "number class" {
  assert_true(is_number(0x31)) // '1'
  assert_true(is_number(0x0663)) // 阿拉伯-印度数字 3 (Nd)
  assert_true(is_number(0x2160)) // 罗马数字 I (Nl)
  assert_true(is_number(0x00B2)) // 上标 2 (No)
  assert_false(is_number(0x41))
}

///|
test "whitespace class follows the White_Space property" {
  assert_true(is_whitespace(0x20))
  assert_true(is_whitespace(0x09))
  assert_true(is_whitespace(0x0A))
  assert_true(is_whitespace(0x0D))
  assert_true(is_whitespace(0xA0)) // NBSP
  assert_true(is_whitespace(0x3000)) // 全角空格
  // 不是 White_Space 属性：
  assert_false(is_whitespace(0x200B)) // 零宽空格
  assert_false(is_whitespace(0x1C)) // 文件分隔符（Python 的 isspace 认为是，属性不是）
}

///|
test "tables are frozen" {
  // 数据源是参考实现所用的 `regex` 引擎，所以这里的版本与条数
  // 就是「参考实现实际看到的 Unicode 类别」的指纹。
  assert_eq(unicode_version, "17.0.0")
  assert_eq(source_engine, "regex 2026.9.29")
  let (letters, numbers, spaces) = table_sizes()
  assert_eq(letters, 694)
  assert_eq(numbers, 148)
  assert_eq(spaces, 10)
}
