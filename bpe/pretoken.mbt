// 预切分：为**一条固定模式**手写的扫描器。
//
// 纪律（见计划 §5.3）：本项目**不做通用正则引擎**。生态里若已有正则，
// 也不使用——那样会抹掉"从零实现"的物证，而且我们只需要这一条模式。
//
// 模式（cl100k_base 一族；此处的形状来自计划 §5.3，最终须与参考实现原文复核）：
//
//   (?i:'s|'t|'re|'ve|'m|'ll|'d)
// | [^\r\n\p{L}\p{N}]?\p{L}+
// | \p{N}{1,3}
// |  ?[^\s\p{L}\p{N}]+[\r\n]*
// | \s*[\r\n]+
// | \s+(?!\S)
// | \s+
//
// 语义要点：
// * 交替是**有序**的：从上到下取第一个能匹配的分支（不是全局最长匹配）。
// * 每个分支内部贪婪。
// * 输入按"码点单元"（`CodePoint`）扫描，非法字节按"其它"类处理，
//   从而保证字节保真（见 `bytes_util.mbt`）。

///|
/// 预切分结果：把原始字节切成若干"片"，每片提供 `[start, end)` 字节区间。
///
/// 返回的是**区间**而非副本，避免在热路径上反复分配；
/// 调用方需要时用 `slice_bytes` 取副本。
pub fn pretokenize(bytes : Bytes) -> Array[(Int, Int)] {
  let cps = decode_utf8_lenient(bytes)
  let n = cps.length()
  let out : Array[(Int, Int)] = []
  let mut i = 0
  while i < n {
    let matched = match_at(cps, i)
    // 兜底：非空白的单码点至少被吃掉 1 个码点，保证循环必然前进。
    let step = if matched > 0 { matched } else { 1 }
    let start = cps[i].start
    let end = if i + step < n { cps[i + step].start } else { bytes.length() }
    out.push((start, end))
    i = i + step
  }
  out
}

///|
/// 在码点流的位置 `i` 尝试 7 个分支，返回匹配的码点数（0 表示全部失败）。
fn match_at(cps : Array[CodePoint], i : Int) -> Int {
  let m1 = match_contraction(cps, i)
  if m1 > 0 {
    return m1
  }
  let m2 = match_optional_lead_letters(cps, i)
  if m2 > 0 {
    return m2
  }
  let m3 = match_digits(cps, i)
  if m3 > 0 {
    return m3
  }
  let m4 = match_punctuation(cps, i)
  if m4 > 0 {
    return m4
  }
  let m5 = match_ws_then_newline(cps, i)
  if m5 > 0 {
    return m5
  }
  let m6 = match_ws_not_followed(cps, i)
  if m6 > 0 {
    return m6
  }
  match_ws(cps, i)
}

///|
fn is_l(cp : CodePoint) -> Bool {
  cp.valid && @unicode.is_letter(cp.cp)
}

///|
fn is_n(cp : CodePoint) -> Bool {
  cp.valid && @unicode.is_number(cp.cp)
}

///|
fn is_s(cp : CodePoint) -> Bool {
  cp.valid && @unicode.is_whitespace(cp.cp)
}

///|
fn is_crlf(cp : CodePoint) -> Bool {
  cp.valid && (cp.cp == 0x0D || cp.cp == 0x0A)
}

///|
/// 既非空白、也非字母、也非数字 —— 对应 `[^\s\p{L}\p{N}]`。
fn is_other(cp : CodePoint) -> Bool {
  !is_s(cp) && !is_l(cp) && !is_n(cp)
}

///|
fn ascii_lower(cp : CodePoint) -> Int {
  let v = cp.cp.reinterpret_as_int()
  if v >= 0x41 && v <= 0x5A {
    v + 0x20
  } else {
    v
  }
}

///|
/// 分支 1：`(?i:'s|'t|'re|'ve|'m|'ll|'d)`
fn match_contraction(cps : Array[CodePoint], i : Int) -> Int {
  let n = cps.length()
  if i >= n || cps[i].cp != 0x27 || !cps[i].valid {
    return 0
  }
  // 只考虑 ASCII 缩写（与参考实现一致：这些后缀都是 ASCII）。
  let c1 = if i + 1 < n { ascii_lower(cps[i + 1]) } else { -1 }
  let c2 = if i + 2 < n { ascii_lower(cps[i + 2]) } else { -1 }
  let two = c1 == 0x73 || c1 == 0x74 || c1 == 0x6D || c1 == 0x64
  if two {
    return 2
  }
  if (c1 == 0x72 || c1 == 0x76 || c1 == 0x6C) && c2 != -1 {
    let is_re = c1 == 0x72 && c2 == 0x65
    let is_ve = c1 == 0x76 && c2 == 0x65
    let is_ll = c1 == 0x6C && c2 == 0x6C
    if is_re || is_ve || is_ll {
      return 3
    }
  }
  0
}

///|
/// 分支 2：`[^\r\n\p{L}\p{N}]?\p{L}+`
fn match_optional_lead_letters(cps : Array[CodePoint], i : Int) -> Int {
  let n = cps.length()
  if i >= n {
    return 0
  }
  let mut j = i
  if !is_l(cps[i]) {
    // 可选前导：非 \r、非 \n、非字母、非数字
    let ok_lead = cps[i].valid &&
      !is_crlf(cps[i]) &&
      !is_l(cps[i]) &&
      !is_n(cps[i])
    if !ok_lead || i + 1 >= n || !is_l(cps[i + 1]) {
      return 0
    }
    j = i + 1
  }
  // 贪婪吃字母
  let mut k = j
  while k < n && is_l(cps[k]) {
    k = k + 1
  }
  k - i
}

///|
/// 分支 3：`\p{N}{1,3}`
fn match_digits(cps : Array[CodePoint], i : Int) -> Int {
  let n = cps.length()
  if i >= n || !is_n(cps[i]) {
    return 0
  }
  let mut k = 0
  while k < 3 && i + k < n && is_n(cps[i + k]) {
    k = k + 1
  }
  k
}

///|
/// 分支 4：` ?[^\s\p{L}\p{N}]+[\r\n]*`
fn match_punctuation(cps : Array[CodePoint], i : Int) -> Int {
  let n = cps.length()
  if i >= n {
    return 0
  }
  let mut j = i
  if cps[i].valid && cps[i].cp == 0x20 && i + 1 < n && is_other(cps[i + 1]) {
    j = i + 1
  } else if !is_other(cps[i]) {
    return 0
  }
  let mut k = j
  while k < n && is_other(cps[k]) {
    k = k + 1
  }
  // 尾部换行，贪婪
  let mut e = k
  while e < n && is_crlf(cps[e]) {
    e = e + 1
  }
  e - i
}

///|
/// 分支 5：`\s*[\r\n]+`
///
/// 语义：匹配"从 i 开始的最长全空白前缀，且该前缀以 \r 或 \n 结尾"。
fn match_ws_then_newline(cps : Array[CodePoint], i : Int) -> Int {
  let n = cps.length()
  let mut w = i
  while w < n && is_s(cps[w]) {
    w = w + 1
  }
  if w == i {
    return 0
  }
  // 回退到运行段里最后一个 \r 或 \n
  let mut p = w - 1
  while p >= i {
    if is_crlf(cps[p]) {
      return p - i + 1
    }
    p = p - 1
  }
  0
}

///|
/// 分支 6：`\s+(?!\S)`
///
/// 语义：贪婪吃空白；若后面还有非空白则回退一个（把最后一个空白留给后面的分支）。
fn match_ws_not_followed(cps : Array[CodePoint], i : Int) -> Int {
  let n = cps.length()
  let mut w = 0
  while i + w < n && is_s(cps[i + w]) {
    w = w + 1
  }
  if w == 0 {
    return 0
  }
  if i + w == n {
    w // 已到串尾，后面的 (?!\S) 恒成立
  } else if w >= 2 {
    w - 1 // 后面是非空白 -> 回退一个
  } else {
    0
  }
}

///|
/// 分支 7：`\s+`
fn match_ws(cps : Array[CodePoint], i : Int) -> Int {
  let n = cps.length()
  let mut w = 0
  while i + w < n && is_s(cps[i + w]) {
    w = w + 1
  }
  w
}
