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
/// 精确计数器：用给定词表逐 token 计数（cl100k 形状）。
pub fn Counter::cl100k(v : @vocab.Vocab) -> Counter {
  {
    name: "cl100k_base",
    exact: true,
    count_bytes: fn(bytes) { v.count_bytes(bytes) },
  }
}

///|
/// 估算计数器：`chars_per_token` 个字符当 1 token（向上取整）。
///
/// 只用于「还没有词表/不知道目标模型」的场合。`exact=false` 会写进报告。
pub fn Counter::estimate(chars_per_token : Int) -> Counter {
  let cpt = if chars_per_token <= 0 { 4 } else { chars_per_token }
  {
    name: "estimate@" + cpt.to_string(),
    exact: false,
    count_bytes: fn(bytes) {
      let n = bytes.length().to_int64()
      (n + cpt.to_int64() - 1L) / cpt.to_int64()
    },
  }
}
