// 短片快路径（n = 2 / 3）必须与"每轮全扫"的原算法逐 id 相同。
//
// 这里保留一份 0.6.1 的朴素实现作为**参考**：段用 `Array[Bytes]`、每轮对所有
// 相邻对重拼字节并取最左最小 rank。随机词表 + 随机输入下对比两条路径。

///|
/// 原算法（0.6.1）：每轮全量扫描相邻对。
fn encode_piece_reference(
  v : VocabView,
  piece : Bytes,
  from : Int,
  to : Int,
  out : Array[Int],
) -> Unit {
  let n = to - from
  if n == 0 {
    return
  }
  let parts : Array[Bytes] = []
  let ids : Array[Int] = []
  for i = 0; i < n; i = i + 1 {
    let one = slice_bytes(piece, from + i, from + i + 1)
    parts.push(one)
    ids.push(v.byte_ids[one.unsafe_get(0).to_int() & 0xFF])
  }
  while parts.length() > 1 {
    let mut best_i = -1
    let mut best_rank = 0
    for i = 0; i + 1 < parts.length(); i = i + 1 {
      let merged = concat_bytes(parts[i], parts[i + 1])
      match v.rank_of.get(merged) {
        Some(r) =>
          if best_i < 0 || r < best_rank {
            best_i = i
            best_rank = r
          }
        None => ()
      }
    }
    if best_i < 0 {
      break
    }
    let merged = concat_bytes(parts[best_i], parts[best_i + 1])
    match v.id_of.get(merged) {
      Some(id) => ids[best_i] = id
      None => ()
    }
    parts[best_i] = merged
    let _ = parts.remove(best_i + 1)
    let _ = ids.remove(best_i + 1)
  }
  for id in ids {
    out.push(id)
  }
}

///|
fn lcg(s : Array[Int]) -> Int {
  s[0] = (s[0] * 75 + 74) % 65537
  s[0]
}

///|
test "short-piece fast paths match the reference algorithm" {
  let seed : Array[Int] = [20261021]
  for round = 0; round < 300; round = round + 1 {
    // 随机词表：8..24 个 2..4 字节的 token，字母只用 a..d 制造重叠
    let extra : Array[Bytes] = []
    let count = 8 + lcg(seed) % 17
    for k1 = 0; k1 < count; k1 = k1 + 1 {
      let len = 2 + lcg(seed) % 3
      let arr : Array[Byte] = []
      for k2 = 0; k2 < len; k2 = k2 + 1 {
        arr.push((97 + lcg(seed) % 4).to_byte())
      }
      extra.push(Bytes::from_array(arr))
    }
    let v = view_with(extra, [])
    // 随机输入：1..12 个 a..d 字节（覆盖 n=2/3 与通用路径）
    let len = 1 + lcg(seed) % 12
    let input : Array[Byte] = []
    for k3 = 0; k3 < len; k3 = k3 + 1 {
      input.push((97 + lcg(seed) % 4).to_byte())
    }
    let bytes = Bytes::from_array(input)
    let fast = encode_ordinary(v, bytes)
    let reference : Array[Int] = []
    for entry in pretokenize(bytes) {
      let (from, to) = entry
      encode_piece_reference(v, bytes, from, to, reference)
    }
    if fast != reference {
      abort(
        "第 \{round} 轮不一致：输入=\{bytes.length()} 字节，id 数 \{fast.length()} vs \{reference.length()}",
      )
    }
    // 计数路径也必须一致
    assert_eq(count_ordinary(v, bytes), fast.length())
  }
}
