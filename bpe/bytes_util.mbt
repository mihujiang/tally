// 字节序列基础操作。
//
// 本模块刻意不依赖 `moonbitlang/core` 的 `encoding/utf8`：预切分需要的是
// "码点 + 原始字节跨度" 的流，而且必须对**非法 UTF-8 也保持字节保真**
// （不变量 V6：`decode(encode(b)) == b` 对任意 `Bytes` 成立）。
// 官方解码器遇到非法字节会替换成 U+FFFD，这会丢掉原始字节。

///|
/// 输入流中的一个码点单元。
///
/// * `cp`    —— 码点值；若 `valid` 为 `false`，则它是原始字节值（0…255）。
/// * `start` —— 在原始 `Bytes` 中的起始字节偏移。
/// * `size`  —— 占用的字节数（非法字节恒为 1）。
/// * `valid` —— 是否是合法 UTF-8 码点。
///
/// 非法字节在分类时一律按 "既非字母、也非数字、也非空白" 处理，
/// 从而落进预切分模式的 `[^\s\p{L}\p{N}]` 分支，字节原样保留。
pub(all) struct CodePoint {
  cp : UInt
  start : Int
  size : Int
  valid : Bool
} derive(Debug)

///|
fn is_cont(b : Int) -> Bool {
  b >= 0x80 && b <= 0xBF
}

///|
/// 宽松 UTF-8 解码：合法序列解出一个码点，非法字节各自成为一个单元。
///
/// 合法性判定与 Unicode 表 3-7 一致（拒绝过长编码、代理区、> U+10FFFF）。
pub fn decode_utf8_lenient(bytes : Bytes) -> Array[CodePoint] {
  let out : Array[CodePoint] = []
  let n = bytes.length()
  let mut i = 0
  while i < n {
    let b0 = bytes[i].to_int() & 0xFF
    if b0 < 0x80 {
      out.push({ cp: b0.reinterpret_as_uint(), start: i, size: 1, valid: true })
      i = i + 1
      continue
    }
    // 2 字节：C2..DF
    if b0 >= 0xC2 && b0 <= 0xDF && i + 1 < n {
      let b1 = bytes[i + 1].to_int() & 0xFF
      if is_cont(b1) {
        let cp = ((b0 & 0x1F) << 6) | (b1 & 0x3F)
        out.push({ cp: cp.reinterpret_as_uint(), start: i, size: 2, valid: true })
        i = i + 2
        continue
      }
    }
    // 3 字节：E0..EF
    if b0 >= 0xE0 && b0 <= 0xEF && i + 2 < n {
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
        let cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
        out.push({ cp: cp.reinterpret_as_uint(), start: i, size: 3, valid: true })
        i = i + 3
        continue
      }
    }
    // 4 字节：F0..F4
    if b0 >= 0xF0 && b0 <= 0xF4 && i + 3 < n {
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
        let cp = ((b0 & 0x07) << 18) |
          ((b1 & 0x3F) << 12) |
          ((b2 & 0x3F) << 6) |
          (b3 & 0x3F)
        out.push({ cp: cp.reinterpret_as_uint(), start: i, size: 4, valid: true })
        i = i + 4
        continue
      }
    }
    // 非法字节：原样作为一个单元
    out.push({ cp: b0.reinterpret_as_uint(), start: i, size: 1, valid: false })
    i = i + 1
  }
  out
}

///|
/// 拼接两个字节序列。
///
/// 注：本版本 `Bytes` 没有 `op_set`，写入一律经 `Array[Byte]` 中转
/// （`Bytes::from_array`）。这是工具链层面的约束，不是设计选择。
pub fn concat_bytes(a : Bytes, b : Bytes) -> Bytes {
  let la = a.length()
  let lb = b.length()
  if la == 0 {
    return b
  }
  if lb == 0 {
    return a
  }
  let out : Array[Byte] = Array::make(la + lb, (0).to_byte())
  for i = 0; i < la; i = i + 1 {
    out[i] = a.unsafe_get(i)
  }
  for i = 0; i < lb; i = i + 1 {
    out[la + i] = b.unsafe_get(i)
  }
  Bytes::from_array(out)
}

///|
/// 取 `bytes[from, to)` 的副本。
pub fn slice_bytes(bytes : Bytes, from : Int, to : Int) -> Bytes {
  let len = to - from
  let out : Array[Byte] = Array::make(len, (0).to_byte())
  for i = 0; i < len; i = i + 1 {
    out[i] = bytes.unsafe_get(from + i)
  }
  Bytes::from_array(out)
}
