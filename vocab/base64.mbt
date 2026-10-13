// 自写 base64（RFC 4648 标准字母表，带 `=` 补位）。
//
// 为什么不复用 `moonbitlang/core/encoding/base64`：
// "什么算规范形式必须由本项目定义，否则会随标准库实现漂移"
// （见计划 §3.2 / §5.5，以及上一项目 payload/base64.mbt 的结论）。
// 词表文本是要被 fingerprint、被 diff 的，编码形式不能依赖外部实现。

///|
let b64_alphabet : Array[Char] = [
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
  'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f',
  'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v',
  'w', 'x', 'y', 'z', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '+', '/',
]

///|
fn b64_char(idx : Int) -> Char {
  b64_alphabet[idx & 0x3F]
}

///|
/// 把 base64 字符映射回 6 位值；非法字符返回 `-1`。
fn b64_value(c : Char) -> Int {
  let v = c.to_int()
  if v >= 0x41 && v <= 0x5A {
    v - 0x41
  } else if v >= 0x61 && v <= 0x7A {
    v - 0x61 + 26
  } else if v >= 0x30 && v <= 0x39 {
    v - 0x30 + 52
  } else if v == 0x2B {
    62
  } else if v == 0x2F {
    63
  } else {
    -1
  }
}

///|
/// 标准 base64 编码（带 `=` 补位，规范形式）。
pub fn b64_encode(bytes : Bytes) -> String {
  let n = bytes.length()
  let out : Array[Char] = []
  let mut i = 0
  while i + 3 <= n {
    let b0 = bytes[i].to_int() & 0xFF
    let b1 = bytes[i + 1].to_int() & 0xFF
    let b2 = bytes[i + 2].to_int() & 0xFF
    out.push(b64_char(b0 >> 2))
    out.push(b64_char(((b0 & 0x03) << 4) | (b1 >> 4)))
    out.push(b64_char(((b1 & 0x0F) << 2) | (b2 >> 6)))
    out.push(b64_char(b2 & 0x3F))
    i = i + 3
  }
  let rem = n - i
  if rem == 1 {
    let b0 = bytes[i].to_int() & 0xFF
    out.push(b64_char(b0 >> 2))
    out.push(b64_char((b0 & 0x03) << 4))
    out.push('=')
    out.push('=')
  } else if rem == 2 {
    let b0 = bytes[i].to_int() & 0xFF
    let b1 = bytes[i + 1].to_int() & 0xFF
    out.push(b64_char(b0 >> 2))
    out.push(b64_char(((b0 & 0x03) << 4) | (b1 >> 4)))
    out.push(b64_char((b1 & 0x0F) << 2))
    out.push('=')
  }
  String::from_array(out)
}

///|
/// 标准 base64 解码。`=` 及其后的内容被忽略；非法字符报错。
pub fn b64_decode(text : StringView) -> Bytes raise VocabError {
  let chars = text.to_array()
  let out : Array[Byte] = []
  let mut acc = 0
  let mut bits = 0
  for c in chars {
    if c == '=' {
      break
    }
    let v = b64_value(c)
    if v < 0 {
      raise InvalidBase64(c)
    }
    acc = ((acc << 6) | v) & 0xFFFFFF
    bits = bits + 6
    if bits >= 8 {
      bits = bits - 8
      out.push(((acc >> bits) & 0xFF).to_byte())
      acc = acc & ((1 << bits) - 1)
    }
  }
  Bytes::from_array(out)
}
