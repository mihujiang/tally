// 解码：token id 序列 -> 原始字节。
//
// 不变量 V6：对任意 `Bytes`，`decode(encode(b)) == b` 逐字节成立。

///|
/// 把 token id 序列拼回字节序列。
///
/// 越界的 id 会被忽略（调用方若需严格模式可自行校验）。
pub fn decode(v : VocabView, ids : Array[Int]) -> Bytes {
  let n = v.tokens.length()
  let mut total = 0
  for id in ids {
    if id >= 0 && id < n {
      total = total + v.tokens[id].length()
    }
  }
  let out : Array[Byte] = Array::make(total, (0).to_byte())
  let mut w = 0
  for id in ids {
    if id >= 0 && id < n {
      let t = v.tokens[id]
      for k = 0; k < t.length(); k = k + 1 {
        out[w] = t.unsafe_get(k)
        w = w + 1
      }
    }
  }
  Bytes::from_array(out)
}
