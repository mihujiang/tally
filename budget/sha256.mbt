// SHA-256（FIPS 180-4）的最小实现，只服务于本包的摘要（`tally-digest v1`）。
//
// 为什么自带：核心包的纪律是零第三方依赖，摘要不能为了省 120 行而破例。
// 只实现单向压缩 + hex 编码，没有 HMAC / 流式接口——用在不需要的地方就是负债。

///|
let k_sha256 : Array[UInt] = [
  0x428A2F98U, 0x71374491U, 0xB5C0FBCFU, 0xE9B5DBA5U, 0x3956C25BU, 0x59F111F1U,
  0x923F82A4U, 0xAB1C5ED5U, 0xD807AA98U, 0x12835B01U, 0x243185BEU, 0x550C7DC3U,
  0x72BE5D74U, 0x80DEB1FEU, 0x9BDC06A7U, 0xC19BF174U, 0xE49B69C1U, 0xEFBE4786U,
  0x0FC19DC6U, 0x240CA1CCU, 0x2DE92C6FU, 0x4A7484AAU, 0x5CB0A9DCU, 0x76F988DAU,
  0x983E5152U, 0xA831C66DU, 0xB00327C8U, 0xBF597FC7U, 0xC6E00BF3U, 0xD5A79147U,
  0x06CA6351U, 0x14292967U, 0x27B70A85U, 0x2E1B2138U, 0x4D2C6DFCU, 0x53380D13U,
  0x650A7354U, 0x766A0ABBU, 0x81C2C92EU, 0x92722C85U, 0xA2BFE8A1U, 0xA81A664BU,
  0xC24B8B70U, 0xC76C51A3U, 0xD192E819U, 0xD6990624U, 0xF40E3585U, 0x106AA070U,
  0x19A4C116U, 0x1E376C08U, 0x2748774CU, 0x34B0BCB5U, 0x391C0CB3U, 0x4ED8AA4AU,
  0x5B9CCA4FU, 0x682E6FF3U, 0x748F82EEU, 0x78A5636FU, 0x84C87814U, 0x8CC70208U,
  0x90BEFFFAU, 0xA4506CEBU, 0xBEF9A3F7U, 0xC67178F2U,
]

///|
let hex_alphabet : Array[Char] = [
  '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
]

///|
fn rotr(x : UInt, n : Int) -> UInt {
  (x >> n) | (x << (32 - n))
}

///|
/// 按 FIPS 180-4 §5.1 补位：`0x80` + 若干 `0x00` + 64 位大端比特长度。
fn pad_block(bytes : Bytes) -> Array[Byte] {
  let n = bytes.length()
  let out : Array[Byte] = []
  for i = 0; i < n; i = i + 1 {
    out.push(bytes.unsafe_get(i))
  }
  out.push((0x80).to_byte())
  // 目标长度是 64 的倍数，且末 8 字节留给长度。
  let total = (n + 9 + 63) / 64 * 64
  while out.length() < total - 8 {
    out.push((0).to_byte())
  }
  let bit_len = n.to_int64() * 8L
  for i = 7; i >= 0; i = i - 1 {
    let shift = i * 8
    let b = if i >= 4 {
      // 高 32 位：比特长度 / 2^32
      (bit_len >> 32) >> (shift - 32)
    } else {
      bit_len >> shift
    }
    out.push((b.to_int() & 0xFF).to_byte())
  }
  out
}

///|
/// 压缩一个 512 位块，`h` 原地更新。
fn compress(h : Array[UInt], block : Array[Byte], off : Int) -> Unit {
  let w : Array[UInt] = Array::make(64, 0U)
  for i = 0; i < 16; i = i + 1 {
    let b0 = (block[off + i * 4].to_int() & 0xFF).reinterpret_as_uint()
    let b1 = (block[off + i * 4 + 1].to_int() & 0xFF).reinterpret_as_uint()
    let b2 = (block[off + i * 4 + 2].to_int() & 0xFF).reinterpret_as_uint()
    let b3 = (block[off + i * 4 + 3].to_int() & 0xFF).reinterpret_as_uint()
    w[i] = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
  }
  for i = 16; i < 64; i = i + 1 {
    let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
    let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
    w[i] = w[i - 16] + s0 + w[i - 7] + s1
  }
  let mut a = h[0]
  let mut b = h[1]
  let mut c = h[2]
  let mut d = h[3]
  let mut e = h[4]
  let mut f = h[5]
  let mut g = h[6]
  let mut hh = h[7]
  for i = 0; i < 64; i = i + 1 {
    let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
    let ch = (e & f) ^ ((e ^ 0xFFFFFFFFU) & g)
    let t1 = hh + s1 + ch + k_sha256[i] + w[i]
    let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
    let maj = (a & b) ^ (a & c) ^ (b & c)
    let t2 = s0 + maj
    hh = g
    g = f
    f = e
    e = d + t1
    d = c
    c = b
    b = a
    a = t1 + t2
  }
  h[0] = h[0] + a
  h[1] = h[1] + b
  h[2] = h[2] + c
  h[3] = h[3] + d
  h[4] = h[4] + e
  h[5] = h[5] + f
  h[6] = h[6] + g
  h[7] = h[7] + hh
}

///|
/// 对任意字节序列求 SHA-256，返回 64 位小写 hex。
pub fn sha256_hex(bytes : Bytes) -> String {
  let h : Array[UInt] = [
    0x6A09E667U, 0xBB67AE85U, 0x3C6EF372U, 0xA54FF53AU, 0x510E527FU, 0x9B05688CU,
    0x1F83D9ABU, 0x5BE0CD19U,
  ]
  let padded = pad_block(bytes)
  let mut off = 0
  while off < padded.length() {
    compress(h, padded, off)
    off = off + 64
  }
  let out : Array[Char] = []
  for i = 0; i < 8; i = i + 1 {
    for s = 28; s >= 0; s = s - 4 {
      out.push(hex_alphabet[((h[i] >> s) & 0xFU).reinterpret_as_int()])
    }
  }
  String::from_array(out)
}
