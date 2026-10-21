// 预切分：为**一条固定模式**手写的扫描器。
//
// 纪律（见计划 §5.3）：本项目**不做通用正则引擎**。生态里若已有正则，
// 也不使用——那样会抹掉"从零实现"的物证，而且我们只需要这一条模式。
//
// 模式（cl100k_base；取自参考实现 tiktoken 0.14.0 的 pat_str 原文）：
//
//   '(?i:[sdmt]|ll|ve|re)
// | [^\r\n\p{L}\p{N}]?+\p{L}++
// | \p{N}{1,3}+
// |  ?[^\s\p{L}\p{N}]++[\r\n]*+
// | \s++$
// | \s*[\r\n]
// | \s+(?!\S)
// | \s
//
// 与原文的等价性：
// * 占用（possessive）量词 `?+` `++` `*+` 在本模式下**不影响语义**，只减少回溯：
//   这些位置一旦失配，正则引擎也不会通过放弃占用找到别的匹配。
// * 因此实现按普通贪婪处理，交替实现为**有序分支**（取第一个能匹配的分支）。
// * `\s++$` **不可省略**：它负责「到串尾的整段空白」的吸收，
//   漏掉会让尾部空白被切碎（与参考实现不一致）。
//
// 语义要点：
// * 交替是**有序**的：从上到下取第一个能匹配的分支（不是全局最长匹配）。
// * 每个分支内部贪婪。
//
// **非法 UTF-8 的分野**（这是参考实现自己的一条暗规则，见
// `bpe/pretoken_align_wbtest.mbt` 与 `alignment_wbtest.mbt`）：
// 参考实现的 `encode(bytes)` 会先尝试把输入**严格**解码成文本；
//   * 解码成功 -> 正则跑在**文本**上，`\p{L}` / `\p{N}` / `\s` 是真 Unicode 属性类
//     （由 `@unicode` 的生成表提供）；
//   * 解码失败（截断序列、孤立首字节、超范围编码、代理区等）-> **整个输入作为一片**，
//     不再切分，直接交给 BPE。
//
// 第二条不是省事：`b" \xec\x8b\xa4\xed"`（`U+C2E4` 后跟一个悬挂的 `0xED`）在参考实现里
// 编成**单个** token `62085`（`b" \xec\x8b\xa4\xed"` 自身），只有整片 BPE 才可能到达；
// 而 `b" \xc2\x850"`（合法 UTF-8，`U+0085` 是 White_Space）会走到 `\s+(?!\S)`
// 的回退，把空格单独切出来。两条行为并存，正是「先试解码、失败就整片」的指纹。
//
// **第二轮优化**（0.7.0 之后，输出逐字节不变，由 corpus 2,935 例与 pretoken 金样守着）：
// 原来先 `decode_utf8_lenient` 生成 `Array[CodePoint]`，再让各分支反复调
// `@unicode.is_letter` / `is_number` / `is_whitespace`——每个码点被分类 3~5 次，
// 每次都是一次二分查表外加一次 tuple 拆箱。现在改成**单遍解码 + 只分类一次**：
// 每个码点压进一个 `Int`（`cp << 4 | 类别位`），另外只存字节起点；此后所有分支
// 都退化成位测试。分类结果与 `\p{L}` / `\p{N}` / `\s` / `[\r\n]` 的语义逐位对应。

///|
/// 类别位：`\p{L}`、`\p{N}`、`\s`、`[\r\n]`。
const K_L : Int = 1

///|
const K_N : Int = 2

///|
const K_S : Int = 4

///|
const K_NL : Int = 8

///|
/// 单元 = `cp << 4 | 类别位`。
fn is_l(u : Int) -> Bool {
  (u & K_L) != 0
}

///|
fn is_n(u : Int) -> Bool {
  (u & K_N) != 0
}

///|
fn is_s(u : Int) -> Bool {
  (u & K_S) != 0
}

///|
fn is_crlf(u : Int) -> Bool {
  (u & K_NL) != 0
}

///|
/// 既非空白、也非字母、也非数字 —— 对应 `[^\s\p{L}\p{N}]`。
fn is_other(u : Int) -> Bool {
  (u & (K_L | K_N | K_S)) == 0
}

///|
fn cp_of(u : Int) -> Int {
  u >> 4
}

///|
/// 单遍宽松解码 + 分类。遇到**任何一个**非法字节立即返回 `None`：
/// 参考实现的分野是「整串严格解码失败 -> 整串一片」，所以不必解完再看。
fn classify(bytes : Bytes) -> (Array[Int], Array[Int])? {
  let n = bytes.length()
  let units : Array[Int] = []
  let starts : Array[Int] = []
  let mut i = 0
  while i < n {
    let b0 = bytes[i].to_int() & 0xFF
    let mut cp = 0
    let mut size = 0
    if b0 < 0x80 {
      cp = b0
      size = 1
    } else if b0 >= 0xC2 && b0 <= 0xDF && i + 1 < n {
      let b1 = bytes[i + 1].to_int() & 0xFF
      if is_cont(b1) {
        cp = ((b0 & 0x1F) << 6) | (b1 & 0x3F)
        size = 2
      }
    } else if b0 >= 0xE0 && b0 <= 0xEF && i + 2 < n {
      let b1 = bytes[i + 1].to_int() & 0xFF
      let b2 = bytes[i + 2].to_int() & 0xFF
      let b1_ok = if b0 == 0xE0 {
        b1 >= 0xA0 && b1 <= 0xBF
      } else if b0 == 0xED {
        b1 >= 0x80 && b1 <= 0x9F
      } else {
        is_cont(b1)
      }
      if b1_ok && is_cont(b2) {
        cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
        size = 3
      }
    } else if b0 >= 0xF0 && b0 <= 0xF4 && i + 3 < n {
      let b1 = bytes[i + 1].to_int() & 0xFF
      let b2 = bytes[i + 2].to_int() & 0xFF
      let b3 = bytes[i + 3].to_int() & 0xFF
      let b1_ok = if b0 == 0xF0 {
        b1 >= 0x90 && b1 <= 0xBF
      } else if b0 == 0xF4 {
        b1 >= 0x80 && b1 <= 0x8F
      } else {
        is_cont(b1)
      }
      if b1_ok && is_cont(b2) && is_cont(b3) {
        cp = ((b0 & 0x07) << 18) |
          ((b1 & 0x3F) << 12) |
          ((b2 & 0x3F) << 6) |
          (b3 & 0x3F)
        size = 4
      }
    }
    if size == 0 {
      return None
    }
    let u = cp.reinterpret_as_uint()
    // 三个类互斥（L / N / White_Space 在 Unicode 里没有交集），所以命中即停：
    // 中文与英文各只查 1 次表，而不是原来的 3 次。
    // ASCII 直接判：`\p{L}` = A-Za-z，`\p{N}` = 0-9，`\s` = 09..0D 与 20，
    // 与生成表在 < 0x80 上逐点一致（由 `ascii_class_wbtest` 守着）。
    let mut kind = 0
    if u < 0x80 {
      if (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) {
        kind = K_L
      } else if u >= 0x30 && u <= 0x39 {
        kind = K_N
      } else if u == 0x20 || (u >= 0x09 && u <= 0x0D) {
        kind = K_S
      }
    } else if @unicode.is_letter(u) {
      kind = K_L
    } else if @unicode.is_number(u) {
      kind = K_N
    } else if @unicode.is_whitespace(u) {
      kind = K_S
    }
    if cp == 0x0D || cp == 0x0A {
      kind = kind | K_NL
    }
    units.push((cp << 4) | kind)
    starts.push(i)
    i = i + size
  }
  Some((units, starts))
}

///|
/// 预切分结果：把原始字节切成若干"片"，每片提供 `[start, end)` 字节区间。
///
/// 返回的是**区间**而非副本，避免在热路径上反复分配；
/// 调用方需要时用 `slice_bytes` 取副本。
pub fn pretokenize(bytes : Bytes) -> Array[(Int, Int)] {
  let starts : Array[Int] = []
  let ends : Array[Int] = []
  pretokenize_spans(bytes, starts, ends)
  let out : Array[(Int, Int)] = []
  for i = 0; i < starts.length(); i = i + 1 {
    out.push((starts[i], ends[i]))
  }
  out
}

///|
/// 预切分的内部形式：起点与终点分别入两个数组，省掉每片一个 tuple。
/// 热路径（`encode_ordinary` / `count`）走这条。
fn pretokenize_spans(bytes : Bytes, starts_out : Array[Int], ends_out : Array[Int]) -> Unit {
  match classify(bytes) {
    // 严格解码失败 -> 整串作为一片（参考实现的指纹）。
    None => {
      starts_out.push(0)
      ends_out.push(bytes.length())
    }
    Some((units, starts)) => {
      let n = units.length()
      let mut i = 0
      while i < n {
        let matched = match_at(units, i)
        // 兜底：非空白的单码点至少被吃掉 1 个码点，保证循环必然前进。
        let step = if matched > 0 { matched } else { 1 }
        let start = starts[i]
        let end = if i + step < n { starts[i + step] } else { bytes.length() }
        starts_out.push(start)
        ends_out.push(end)
        i = i + step
      }
    }
  }
}

///|
/// 在码点流的位置 `i` 依次尝试 8 个分支，返回匹配的码点数（0 表示全部失败）。
fn match_at(units : Array[Int], i : Int) -> Int {
  let m1 = match_contraction(units, i)
  if m1 > 0 {
    return m1
  }
  let m2 = match_optional_lead_letters(units, i)
  if m2 > 0 {
    return m2
  }
  let m3 = match_digits(units, i)
  if m3 > 0 {
    return m3
  }
  let m4 = match_punctuation(units, i)
  if m4 > 0 {
    return m4
  }
  let m5 = match_ws_to_end(units, i)
  if m5 > 0 {
    return m5
  }
  let m6 = match_ws_then_newline(units, i)
  if m6 > 0 {
    return m6
  }
  let m7 = match_ws_not_followed(units, i)
  if m7 > 0 {
    return m7
  }
  match_ws(units, i)
}

///|
fn ascii_lower(cp : Int) -> Int {
  if cp >= 0x41 && cp <= 0x5A {
    cp + 0x20
  } else {
    cp
  }
}

///|
/// 分支 1：`(?i:'s|'t|'re|'ve|'m|'ll|'d)`
fn match_contraction(units : Array[Int], i : Int) -> Int {
  let n = units.length()
  if i >= n || cp_of(units[i]) != 0x27 {
    return 0
  }
  // 只考虑 ASCII 缩写（与参考实现一致：这些后缀都是 ASCII）。
  let c1 = if i + 1 < n { ascii_lower(cp_of(units[i + 1])) } else { -1 }
  let c2 = if i + 2 < n { ascii_lower(cp_of(units[i + 2])) } else { -1 }
  let two = c1 == 0x73 || c1 == 0x74 || c1 == 0x6D || c1 == 0x64
  if two {
    return 2
  }
  if c1 == 0x72 || c1 == 0x76 || c1 == 0x6C {
    if c2 != -1 {
      let is_re = c1 == 0x72 && c2 == 0x65
      let is_ve = c1 == 0x76 && c2 == 0x65
      let is_ll = c1 == 0x6C && c2 == 0x6C
      if is_re || is_ve || is_ll {
        return 3
      }
    }
  }
  0
}

///|
/// 分支 2：`[^\r\n\p{L}\p{N}]?\p{L}+`
fn match_optional_lead_letters(units : Array[Int], i : Int) -> Int {
  let n = units.length()
  if i >= n {
    return 0
  }
  let mut j = i
  if !is_l(units[i]) {
    // 可选前导：非 \r、非 \n、非字母、非数字
    let ok_lead = !is_crlf(units[i]) && !is_l(units[i]) && !is_n(units[i])
    if !ok_lead || i + 1 >= n || !is_l(units[i + 1]) {
      return 0
    }
    j = i + 1
  }
  // 贪婪吃字母
  let mut k = j
  while k < n && is_l(units[k]) {
    k = k + 1
  }
  k - i
}

///|
/// 分支 3：`\p{N}{1,3}`
fn match_digits(units : Array[Int], i : Int) -> Int {
  let n = units.length()
  if i >= n || !is_n(units[i]) {
    return 0
  }
  let mut k = 0
  while k < 3 && i + k < n && is_n(units[i + k]) {
    k = k + 1
  }
  k
}

///|
/// 分支 4：` ?[^\s\p{L}\p{N}]+[\r\n]*`
fn match_punctuation(units : Array[Int], i : Int) -> Int {
  let n = units.length()
  if i >= n {
    return 0
  }
  let mut j = i
  if cp_of(units[i]) == 0x20 && i + 1 < n && is_other(units[i + 1]) {
    j = i + 1
  } else if !is_other(units[i]) {
    return 0
  }
  let mut k = j
  while k < n && is_other(units[k]) {
    k = k + 1
  }
  // 尾部换行，贪婪
  let mut e = k
  while e < n && is_crlf(units[e]) {
    e = e + 1
  }
  e - i
}

///|
/// 分支 5：`\s++$`
///
/// 语义：从 i 起到串尾**全是空白**时整段吸收（占有量词不回退，`$` 落在串尾）；
/// 只要后面还有非空白，本分支整体失败。
fn match_ws_to_end(units : Array[Int], i : Int) -> Int {
  let n = units.length()
  let mut w = 0
  while i + w < n && is_s(units[i + w]) {
    w = w + 1
  }
  if w > 0 && i + w == n {
    w
  } else {
    0
  }
}

///|
/// 分支 6：`\s*[\r\n]`
///
/// 语义：匹配"从 i 开始的最长全空白前缀，且该前缀以 \r 或 \n 结尾"。
fn match_ws_then_newline(units : Array[Int], i : Int) -> Int {
  let n = units.length()
  let mut w = i
  while w < n && is_s(units[w]) {
    w = w + 1
  }
  if w == i {
    return 0
  }
  // 回退到运行段里最后一个 \r 或 \n
  let mut p = w - 1
  while p >= i {
    if is_crlf(units[p]) {
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
fn match_ws_not_followed(units : Array[Int], i : Int) -> Int {
  let n = units.length()
  let mut w = 0
  while i + w < n && is_s(units[i + w]) {
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
fn match_ws(units : Array[Int], i : Int) -> Int {
  let n = units.length()
  let mut w = 0
  while i + w < n && is_s(units[i + w]) {
    w = w + 1
  }
  w
}
