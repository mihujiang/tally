// 可插拔计数器：把「数 token」从「必须拥有我们的词表」降成一个函数。
//
// 为什么是结构体 + 闭包，而不是 trait：
// * 接外部 tokenizer 只需包一层闭包，不必给外部类型写 `impl`；
// * 核心包保持零第三方依赖，四后端一致；
// * `name` 与 `exact` 是报告的一部分——「这个数是估的还是精确的、谁算的」必须可追。
//
// 代价：`Counter` 不能 derive、不能序列化。它只需要「能数」。

///|
/// 计数器：给定任意字节序列，给出 token 数。
///
/// `exact=true` 表示逐 token 精确计数；`exact=false` 表示估算，
/// 报告会把它标出来，**估算不允许冒充精确**。
pub(all) struct Counter {
  name : String
  exact : Bool
  count_bytes : (Bytes) -> Int64
}

///|
/// 数一段字节的 token 数。
pub fn Counter::count(self : Counter, bytes : Bytes) -> Int64 {
  (self.count_bytes)(bytes)
}

///|
/// 字符数（Unicode 码点）：按 UTF-8 起始字节计数，续字节 `10xxxxxx` 不计。
///
/// 非法 UTF-8 里的孤立续字节会被并入前一个字符，孤立起始字节各算一个字符；
/// 估算本来就是估算，不需要为此报错。
fn count_chars(bytes : Bytes) -> Int64 {
  let mut n = 0L
  for i = 0; i < bytes.length(); i = i + 1 {
    if is_char_start(bytes.unsafe_get(i)) {
      n = n + 1L
    }
  }
  n
}

///|
/// 估算计数器：`chars_per_token` 个**字符**当 1 token（向上取整）。
///
/// 按字符而不是按字节：中文一个字 3 字节，按字节算会把预算放大 3 倍。
/// 只用于「还没有词表/不知道目标模型」的场合。`exact=false` 会写进报告。
pub fn Counter::estimate(chars_per_token : Int) -> Counter {
  let cpt = if chars_per_token <= 0 { 4 } else { chars_per_token }
  {
    name: "estimate@" + cpt.to_string(),
    exact: false,
    count_bytes: fn(bytes) {
      (count_chars(bytes) + cpt.to_int64() - 1L) / cpt.to_int64()
    },
  }
}
