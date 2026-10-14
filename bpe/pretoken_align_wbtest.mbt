// 与参考实现（tiktoken 0.14.0 / cl100k_base）的一致性对照。
//
// golden 由 tools/gen_pretoken_golden.py 生成，这里只做比对。
// 与 pretoken_wbtest.mbt 的分工：
//   * pretoken_wbtest.mbt —— 实现是否符合「我们自己写的模式」
//   * 本文件               —— 那个模式是否符合「参考实现的原文」
test "pretoken matches reference" {
  let mut bad = 0
  let mut first = ""
  for entry in pretoken_golden {
    let (text, expect) = entry
    if pieces_text(text) != expect {
      bad = bad + 1
      if bad == 1 {
        first = text
      }
    }
  }
  if bad > 0 {
    println("pretoken mismatch on: " + first)
  }
  assert_eq(bad, 0)
}
