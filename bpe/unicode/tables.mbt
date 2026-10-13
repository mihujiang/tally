// Unicode 类别查询：区间表 + 二分查找。
//
// 为什么不用 `moonbitlang/core/char` 的谓词：core 没有 `is_alphabetic`，
// 且 `is_numeric` / `is_whitespace` 与正则 `\p{N}` / `\s` 的语义未必一致。
// 本包自建区间表，语义由 `generated.mbt` 的数据来源唯一决定（见其文件头）。

///|
/// 在升序且互不相邻的区间表中查找码点是否命中。
pub fn in_ranges(ranges : Array[(UInt, UInt)], cp : UInt) -> Bool {
  let mut lo = 0
  let mut hi = ranges.length() - 1
  while lo <= hi {
    let mid = lo + (hi - lo) / 2
    let (low, high) = ranges[mid]
    if cp < low {
      hi = mid - 1
    } else if cp > high {
      lo = mid + 1
    } else {
      return true
    }
  }
  false
}

///|
/// 正则 `\p{L}`：一般类别 Lu | Ll | Lt | Lm | Lo。
pub fn is_letter(cp : UInt) -> Bool {
  in_ranges(letter_ranges, cp)
}

///|
/// 正则 `\p{N}`：一般类别 Nd | Nl | No。
pub fn is_number(cp : UInt) -> Bool {
  in_ranges(number_ranges, cp)
}

///|
/// 正则 `\s`：Unicode `White_Space` 属性。
pub fn is_whitespace(cp : UInt) -> Bool {
  in_ranges(whitespace_ranges, cp)
}

///|
/// 表中所含的区间条数，用于测试与报告（可复算）。
pub fn table_sizes() -> (Int, Int, Int) {
  (letter_ranges.length(), number_ranges.length(), whitespace_ranges.length())
}
