// 计划 §3 的 T4：对抗与一致性矩阵。
//
// 矩阵 A（`alignment_wbtest.mbt`）证明"与参考实现逐 token 相同"。
// 这里回答的是**另外三个问题**，它们都不依赖参考实现：
//
//   * 矩阵 B —— 往返恒等：`decode(encode(x)) == x`，输入包括
//     非法 UTF-8 / NUL / emoji / ZWJ 组合 / CJK / 超长重复。
//   * 矩阵 C —— 全覆盖：任意字节序列都能编码，**没有 OOV**，
//     产出的每个 id 都能被解码器查到。
//   * 矩阵 H —— 双后端一致：同一批输入在 `wasm-gc` 与 `js` 下
//     给出**逐字节相同**的 id 序列（用一份冻结指纹钉住）。
//
// 用例是**确定性**生成的（LCG），所以跨后端、跨机器、跨次运行都可复算；
// 这里不引入任何外部 golden，也就没有"改 golden 让测试变绿"的余地。

///|
/// 一组确定性对抗用例：固定样本 + 550 条伪随机字节串。
fn adversarial_cases() -> Array[Bytes] {
  let out : Array[Bytes] = []
  // 固定样本：边界与已知难点
  out.push(Bytes::make(0, (0).to_byte())) // 空输入
  out.push(Bytes::from_array([0x00])) // NUL
  out.push(Bytes::from_array([0x00, 0x00, 0x00])) // NUL 连续
  out.push(@utf8.encode("👍")) // emoji
  out.push(@utf8.encode("🀄")) // 星形平面 emoji
  out.push(@utf8.encode("中文测试")) // CJK
  out.push(@utf8.encode("👨‍👩‍👧‍👦")) // ZWJ 家族组合
  out.push(@utf8.encode("e\u{0301}")) // 组合字符
  out.push(@utf8.encode("a我b")) // 字母 / CJK 混合
  out.push(@utf8.encode(" 한글 テスト")) // 韩文 / 日文
  out.push(Bytes::from_array([0xFF, 0xFE, 0xFD])) // 非法 UTF-8 首字节串
  out.push(Bytes::from_array([0xC2])) // 截断的两字节序列
  out.push(Bytes::from_array([0xED])) // 悬挂的三字节首字节
  out.push(Bytes::from_array([0x80])) // 孤立续字节
  out.push(Bytes::from_array([0xE4, 0xB8])) // 截断的 CJK
  out.push(Bytes::from_array([0x61, 0xFF, 0x62])) // 字母夹非法字节
  out.push(Bytes::from_array([0x20, 0xC2, 0x85, 0x30])) // U+0085 前后有内容
  out.push(Bytes::from_array([0x20, 0xEC, 0x8B, 0xA4, 0xED])) // 合法 + 悬挂
  out.push(Bytes::make(1000, (0x61).to_byte())) // 超长重复
  out.push(Bytes::make(4096, (0x00).to_byte())) // 超长 NUL
  out.push(Bytes::make(777, (0x0A).to_byte())) // 超长换行
  // 伪随机：长度 0..64，字节均匀取 0..255
  let mut s : UInt = 20261014U
  for i = 0; i < 550; i = i + 1 {
    s = s * 1664525U + 1013904223U
    let len = ((s >> 16) % 65U).reinterpret_as_int()
    let buf : Array[Byte] = []
    for k = 0; k < len; k = k + 1 {
      s = s * 1664525U + 1013904223U
      buf.push(((s >> 13) % 256U).reinterpret_as_int().to_byte())
    }
    out.push(Bytes::from_array(buf))
  }
  out
}

///|
/// 矩阵 B：往返恒等。任何字节串编码后必须能**逐字节**解回来。
test "matrix B: decode(encode(x)) is x on adversarial bytes" {
  let vocab = load_tiktoken(cl100k_slice_text, [])
  let cases = adversarial_cases()
  assert_true(cases.length() >= 500)
  for i = 0; i < cases.length(); i = i + 1 {
    assert_eq(decode(vocab, encode(vocab, cases[i])), cases[i])
  }
}

///|
/// 矩阵 C：全覆盖、无 OOV。编码不得抛错，且产出的每个 id 都必须在词表里
/// （否则解码器会静默跳过它 —— 那正是"静默丢字节"的漏洞）。
test "matrix C: every byte sequence encodes with no OOV" {
  let vocab = load_tiktoken(cl100k_slice_text, [])
  let n_vocab = cl100k_slice_real_id.length()
  let cases = adversarial_cases()
  assert_true(cases.length() >= 200)
  for i = 0; i < cases.length(); i = i + 1 {
    let ids = encode(vocab, cases[i])
    for id in ids {
      assert_true(id >= 0 && id < n_vocab)
    }
    // token 数非零 <=> 输入非空（空输入编出 0 个 token）
    assert_eq(ids.length() == 0, cases[i].length() == 0)
  }
}

///|
/// 冻结指纹：`wasm-gc` 与 `js` 两次运行必须都等于这两个数。
///
/// 这样"双后端一致"就成了一个**可复算**的断言：任何一个后端偏离，
/// 要么数字对不上，要么 hash 对不上。
const FROZEN_HASH : UInt = 2158777208U

///|
const FROZEN_TOKENS : UInt = 21701U

///|
test "matrix H: backend fingerprint is frozen" {
  let vocab = load_tiktoken(cl100k_slice_text, [])
  let cases = adversarial_cases()
  let mut hash : UInt = 2166136261U
  let mut total : UInt = 0U
  for i = 0; i < cases.length(); i = i + 1 {
    for id in encode(vocab, cases[i]) {
      hash = (hash ^ id.reinterpret_as_uint()) * 16777619U
      total = total + 1U
    }
  }
  assert_eq(hash, FROZEN_HASH)
  assert_eq(total, FROZEN_TOKENS)
}
