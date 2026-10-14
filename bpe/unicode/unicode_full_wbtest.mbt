// 全码点遍历（矩阵 E）：1,114,112 个码点 × 3 类，逐点比对。
//
// 计划 §3 T2 的验收要求「逐码点比对」。这里用**两种独立算法**互证：
//   * `is_*` 走二分查找（生产路径）
//   * 本文件用「游标推进」的线性扫描把同一张表重算一遍
// 再与生成器写下的**冻结总数**比对 —— 表数据被手改、或二分查找写错，
// 都会在这里红，而不是等到某个冷门码点在生产里被误判。

///|
/// 逐码点扫描区间表（游标版，总代价 O(码点数 + 区间数)）。
/// 返回 `(命中数, 与 `is_it` 不一致的码点数)`。
fn sweep(ranges : Array[(UInt, UInt)], is_it : (UInt) -> Bool) -> (Int, Int) {
  let n = ranges.length()
  let mut idx = 0
  let mut hits = 0
  let mut bad = 0
  for cp = 0; cp <= 0x10FFFF; cp = cp + 1 {
    let u = cp.reinterpret_as_uint()
    while idx < n && u > ranges[idx].1 {
      idx = idx + 1
    }
    let mut expected = false
    if idx < n {
      let (lo, _) = ranges[idx]
      expected = u >= lo
    }
    let got = is_it(u)
    if expected != got {
      bad = bad + 1
    }
    if got {
      hits = hits + 1
    }
  }
  (hits, bad)
}

///|
test "full sweep: linear scan agrees with the binary search and the frozen totals" {
  let (letter_hits, letter_bad) = sweep(letter_ranges, is_letter)
  let (number_hits, number_bad) = sweep(number_ranges, is_number)
  let (space_hits, space_bad) = sweep(whitespace_ranges, is_whitespace)
  assert_eq(letter_bad, 0) // 二分查找 vs 线性扫描
  assert_eq(number_bad, 0)
  assert_eq(space_bad, 0)
  assert_eq(letter_hits, letter_total) // 表 vs 生成器冻结值
  assert_eq(number_hits, number_total)
  assert_eq(space_hits, whitespace_total)
}

///|
test "frozen totals are pinned in plain sight" {
  // 生成器把总数同时写进 generated.mbt 的表和这里的字面量：
  // 只改一处（例如手改区间表）会被上面那条抓住，两处一起改会被这条抓住。
  assert_eq(letter_total, 158172)
  assert_eq(number_total, 2247)
  assert_eq(whitespace_total, 25)
}

///|
test "surrogates and out-of-range code points are in no class" {
  for cp = 0xD800; cp <= 0xDFFF; cp = cp + 1 {
    let u = cp.reinterpret_as_uint()
    assert_false(is_letter(u))
    assert_false(is_number(u))
    assert_false(is_whitespace(u))
  }
  assert_false(is_letter(0x110000))
  assert_false(is_number(0x110000))
  assert_false(is_whitespace(0x110000))
}
