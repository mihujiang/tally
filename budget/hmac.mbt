// HMAC-SHA256（RFC 2104 / FIPS 198-1），只服务于 `tally-seal v1`。
//
// 为什么自带：核心包零第三方依赖；印记只用到这一种原语，引通用 crypto 包
// 不划算，也把发布面变宽。
//
// **边界（写进格式，别让人误会）**：对称密钥只能证明"持有同一把密钥的人认过这份摘要"，
// 不能证明"谁写的"。要证明身份得有非对称签名与公钥分发，不在本库范围内。

///|
/// SHA-256 的块长（字节）。HMAC 的 ipad/opad 都按块长铺满。
let hmac_block : Int = 64

///|
/// 对任意字节序列求 HMAC-SHA256，返回 64 位小写 hex。
pub fn hmac_sha256_hex(key : Bytes, message : Bytes) -> String {
  // RFC 2104 §2：密钥比块长时先哈希，短则右补 0。
  let k = if key.length() > hmac_block { sha256_bytes(key) } else { key }
  let ipad : Array[Byte] = []
  let opad : Array[Byte] = []
  for i = 0; i < hmac_block; i = i + 1 {
    let kb = if i < k.length() {
      k.unsafe_get(i).to_int() & 0xFF
    } else {
      0
    }
    ipad.push((kb ^ 0x36).to_byte())
    opad.push((kb ^ 0x5C).to_byte())
  }
  for i = 0; i < message.length(); i = i + 1 {
    ipad.push(message.unsafe_get(i))
  }
  let inner = sha256_bytes(Bytes::from_array(ipad))
  for i = 0; i < inner.length(); i = i + 1 {
    opad.push(inner.unsafe_get(i))
  }
  sha256_hex(Bytes::from_array(opad))
}
