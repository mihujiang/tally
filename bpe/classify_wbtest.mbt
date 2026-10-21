// 分类快速路径的等价性。
//
// `pretokenize` 现在把每个码点只分类一次，并且
// * 在 ASCII 上直接判，不查 Unicode 表；
// * 命中一类就短路（不再查另外两类）。
//
// 这两条都必须成立，否则预切分会和参考实现分叉：
// * ASCII 快速路径必须与生成表在 0x00..0x7F 上逐点一致；
// * 短路的前提是 `\p{L}` / `\p{N}` / `\s` 三类在全部码点上互斥。

///|
test "ascii classification matches the unicode tables" {
  for b = 0; b < 0x80; b = b + 1 {
    let u = b.reinterpret_as_uint()
    let fast_l = (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    let fast_n = b >= 0x30 && b <= 0x39
    let fast_s = b == 0x20 || (b >= 0x09 && b <= 0x0D)
    assert_eq(fast_l, @unicode.is_letter(u))
    assert_eq(fast_n, @unicode.is_number(u))
    assert_eq(fast_s, @unicode.is_whitespace(u))
  }
}

///|
test "letter, number and whitespace classes are pairwise disjoint" {
  // 短路的前提：三类没有交集。全码点扫一遍（1.1M 个码点）。
  for cp = 0; cp <= 0x10FFFF; cp = cp + 1 {
    let u = cp.reinterpret_as_uint()
    let l = @unicode.is_letter(u)
    let n = @unicode.is_number(u)
    let s = @unicode.is_whitespace(u)
    let cats = (if l { 1 } else { 0 }) +
      (if n { 1 } else { 0 }) +
      (if s { 1 } else { 0 })
    if cats > 1 {
      abort("码点 U+\{cp} 同时属于多个类别：L=\{l} N=\{n} S=\{s}")
    }
  }
}
