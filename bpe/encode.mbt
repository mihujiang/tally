// byte-level BPE 编码。
//
// 本包**不认识"词表从哪来"**：所有信息都通过 `VocabView` 传入。
// 这是原创点之一——"一个框架 + 可加载的词表"，而不是"一种词表一个构造函数"。

///|
/// `bpe` 与 `vocab` 之间的唯一契约。
///
/// * `tokens`    —— index = token id 的字节序列。
/// * `byte_ids`  —— 256 项，单字节 token 的 id（不变量 V1 的根基）。
/// * `rank_of`   —— token 字节 -> 合并优先级（越小越先合并）。
/// * `id_of`     —— token 字节 -> token id。
/// * `specials`  —— 特殊 token 字面量 `(字节, id)`。建议按长度降序（性能提示），
///   但正确性由 `match_special` 自行保证（扫全部取最长）。
pub(all) struct VocabView {
  tokens : Array[Bytes]
  byte_ids : Array[Int]
  rank_of : Map[Bytes, Int]
  id_of : Map[Bytes, Int]
  /// 短键（≤ 7 字节）的 rank / id 表，键是 `pack_short` 的打包值。
  /// 热路径上的相邻对几乎都 ≤ 7 字节，查这两张表就不必为每个候选
  /// 拼一个 `Bytes` 出来（每轮合并省下 O(n) 次分配）。
  rank_short : Map[Int64, Int]
  id_short : Map[Int64, Int]
  specials : Array[(Bytes, Int)]
}

///|
/// 打包进 `Int64` 的最长字节数：低 8 位存长度，其余按小端存字节。
pub const SHORT_MAX : Int = 7

///|
/// 把 `piece[start, start+len)` 打包成 `Int64` 键（`len` 必须 ≤ `SHORT_MAX`）。
///
/// 长度放在最低字节、数据从次低字节起，因此不同长度的字节串永不撞键，
/// 也不需要再拼 `Bytes`——这是热路径上省掉的分配。`vocab` 构建短键表时
/// 用的是同一个函数，两端不会漂移。
pub fn pack_short(piece : Bytes, start : Int, len : Int) -> Int64 {
  let mut k : Int64 = len.to_int64()
  for i = 0; i < len; i = i + 1 {
    let byte : Int64 = (piece.unsafe_get(start + i).to_int() & 0xFF).to_int64()
    k = k | (byte << ((i + 1) * 8))
  }
  k
}

///|
/// `[start, end)` 合并后的 rank；不可合并返回 -1。
fn pair_rank(v : VocabView, piece : Bytes, start : Int, end : Int) -> Int {
  let len = end - start
  if len <= SHORT_MAX {
    match v.rank_short.get(pack_short(piece, start, len)) {
      Some(r) => r
      None => -1
    }
  } else {
    match v.rank_of.get(slice_bytes(piece, start, end)) {
      Some(r) => r
      None => -1
    }
  }
}

///|
/// `[start, end)` 对应的 token id。
fn id_at(v : VocabView, piece : Bytes, start : Int, end : Int) -> Int? {
  let len = end - start
  if len <= SHORT_MAX {
    v.id_short.get(pack_short(piece, start, len))
  } else {
    v.id_of.get(slice_bytes(piece, start, end))
  }
}

///|
/// 逐片做 BPE 合并，把结果追加到 `out`。范围是 `piece[from, to)`。
///
/// 段用相对 `offsets` 表示：第 i 段是 `[offsets[i], offsets[i+1])`，合并就是删掉一个边界。
/// `ranks[i]` 缓存段 i 与段 i+1 的可合并优先级，合并后只重算受影响的**两个**位置——
/// 每轮不再为所有相邻对重新拼字节、重新查表（0.7.0 之后的第一轮优化；
/// 输出与优化前逐字节相同，由 corpus 2,935 例与双后端测试保证）。
fn encode_piece(
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
  if n == 1 {
    // 单个字节没有可合并对象，直接落 id，省掉两个数组。
    out.push(v.byte_ids[piece.unsafe_get(from).to_int() & 0xFF])
    return
  }
  let b0 = v.byte_ids[piece.unsafe_get(from).to_int() & 0xFF]
  if n == 2 {
    // 两字节：只有「合并 / 不合并」两种结局，不需要数组。
    if pair_rank(v, piece, from, from + 2) >= 0 {
      match id_at(v, piece, from, from + 2) {
        Some(id) => out.push(id)
        None => out.push(b0)
      }
    } else {
      out.push(b0)
      out.push(v.byte_ids[piece.unsafe_get(from + 1).to_int() & 0xFF])
    }
    return
  }
  if n == 3 {
    // 三字节（一个汉字 / 常见短词）：至多两次合并。
    // 只要发生过一次合并，剩下两段的拼接就是整串，所以结局只由
    // 「有没有可合并的相邻对」和「整串是否有 rank」决定。
    let b1 = v.byte_ids[piece.unsafe_get(from + 1).to_int() & 0xFF]
    let b2 = v.byte_ids[piece.unsafe_get(from + 2).to_int() & 0xFF]
    let r01 = pair_rank(v, piece, from, from + 2)
    let r12 = pair_rank(v, piece, from + 1, from + 3)
    if r01 < 0 && r12 < 0 {
      out.push(b0)
      out.push(b1)
      out.push(b2)
      return
    }
    if pair_rank(v, piece, from, from + 3) >= 0 {
      match id_at(v, piece, from, from + 3) {
        Some(id) => {
          out.push(id)
          return
        }
        // 词表损坏（rank 有、id 没有）时按「整串不可合并」继续，
        // 与通用路径的防御分支保持同样的保守方向。
        None => ()
      }
    }
    if r01 >= 0 && (r12 < 0 || r01 <= r12) {
      match id_at(v, piece, from, from + 2) {
        Some(id) => out.push(id)
        None => out.push(b0)
      }
      out.push(b2)
    } else {
      out.push(b0)
      match id_at(v, piece, from + 1, from + 3) {
        Some(id) => out.push(id)
        None => out.push(b1)
      }
    }
    return
  }
  let ids : Array[Int] = []
  let offsets : Array[Int] = []
  for i = 0; i < n; i = i + 1 {
    let b = piece.unsafe_get(from + i).to_int() & 0xFF
    // 单字节 token 必须存在，否则 byte-level BPE 不成立（见 V1/V7）。
    ids.push(v.byte_ids[b])
    offsets.push(i)
  }
  offsets.push(n)
  let ranks : Array[Int] = []
  for i = 0; i + 2 <= n; i = i + 1 {
    ranks.push(pair_rank(v, piece, from + offsets[i], from + offsets[i + 2]))
  }
  while offsets.length() > 2 {
    let mut best = -1
    let mut best_rank = 0
    for i = 0; i < ranks.length(); i = i + 1 {
      let r = ranks[i]
      if r >= 0 && (best < 0 || r < best_rank) {
        best = i
        best_rank = r
      }
    }
    if best < 0 {
      break
    }
    // 合并后的 token 一定在 id 表里：它能在 rank 表里被找到。
    match id_at(v, piece, from + offsets[best], from + offsets[best + 2]) {
      Some(id) => ids[best] = id
      None => ()
    }
    let _ = offsets.remove(best + 1)
    let _ = ids.remove(best + 1)
    let _ = ranks.remove(best)
    if best >= 1 {
      ranks[best - 1] = pair_rank(
        v,
        piece,
        from + offsets[best - 1],
        from + offsets[best + 1],
      )
    }
    if best < ranks.length() {
      ranks[best] = pair_rank(v, piece, from + offsets[best], from + offsets[best + 2])
    }
  }
  for id in ids {
    out.push(id)
  }
}

///|
/// 与 `encode_piece` 同样的合并顺序，但只数 token 数、不产出 id 数组。
fn encode_piece_count(v : VocabView, piece : Bytes, from : Int, to : Int) -> Int {
  let n = to - from
  if n == 0 {
    return 0
  }
  if n == 1 {
    return 1
  }
  if n == 2 {
    return if pair_rank(v, piece, from, from + 2) >= 0 { 1 } else { 2 }
  }
  if n == 3 {
    let r01 = pair_rank(v, piece, from, from + 2)
    let r12 = pair_rank(v, piece, from + 1, from + 3)
    if r01 < 0 && r12 < 0 {
      return 3
    }
    // 发生过一次合并后只剩两段，其拼接就是整串。
    return if pair_rank(v, piece, from, from + 3) >= 0 { 1 } else { 2 }
  }
  let offsets : Array[Int] = []
  for i = 0; i < n; i = i + 1 {
    offsets.push(i)
  }
  offsets.push(n)
  let ranks : Array[Int] = []
  for i = 0; i + 2 <= n; i = i + 1 {
    ranks.push(pair_rank(v, piece, from + offsets[i], from + offsets[i + 2]))
  }
  while offsets.length() > 2 {
    let mut best = -1
    let mut best_rank = 0
    for i = 0; i < ranks.length(); i = i + 1 {
      let r = ranks[i]
      if r >= 0 && (best < 0 || r < best_rank) {
        best = i
        best_rank = r
      }
    }
    if best < 0 {
      break
    }
    let _ = offsets.remove(best + 1)
    let _ = ranks.remove(best)
    if best >= 1 {
      ranks[best - 1] = pair_rank(
        v,
        piece,
        from + offsets[best - 1],
        from + offsets[best + 1],
      )
    }
    if best < ranks.length() {
      ranks[best] = pair_rank(v, piece, from + offsets[best], from + offsets[best + 2])
    }
  }
  offsets.length() - 1
}

///|
/// 在 `bytes[pos...]` 处找**最长**的特殊 token 字面量。
/// 返回 `(字节长度, token id)`；无匹配返回 `(0, 0)`。
///
/// 刻意"扫全部取最长"，而不是依赖 `specials` 已排序：
/// `VocabView` 是公开结构，任何构造者都可能给出未排序的表，
/// 这里必须自带正确性（`Vocab::view` 的降序只是性能提示）。
fn match_special(v : VocabView, bytes : Bytes, pos : Int) -> (Int, Int) {
  let n = bytes.length()
  let remain = n - pos
  let mut best_len = 0
  let mut best_id = 0
  for entry in v.specials {
    let (lit, id) = entry
    let l = lit.length()
    if l > best_len && l <= remain {
      let mut ok = true
      for k = 0; k < l; k = k + 1 {
        if bytes[pos + k] != lit[k] {
          ok = false
          break
        }
      }
      if ok {
        best_len = l
        best_id = id
      }
    }
  }
  (best_len, best_id)
}

///|
/// 特殊 token 的**首字节**集合：只有这些字节可能起头，其余位置直接跳过，
/// 不必逐字节调 `match_special`。返回 `None` 表示没有特殊 token，
/// 整段都能走"无特殊 token"的快路径。
fn special_first_bytes(v : VocabView) -> FixedArray[Bool]? {
  if v.specials.length() == 0 {
    return None
  }
  let first : FixedArray[Bool] = FixedArray::make(256, false)
  for entry in v.specials {
    let (lit, _) = entry
    if lit.length() > 0 {
      first[lit.unsafe_get(0).to_int() & 0xFF] = true
    }
  }
  Some(first)
}

///|
/// 把一段普通文本（不含特殊 token）编码为 token id 序列。
pub fn encode_ordinary(v : VocabView, bytes : Bytes) -> Array[Int] {
  let out : Array[Int] = []
  encode_ordinary_into(v, bytes, out)
  out
}

///|
/// 普通文本的 token 数（不产出 id 数组）。
pub fn count_ordinary(v : VocabView, bytes : Bytes) -> Int {
  let starts : Array[Int] = []
  let ends : Array[Int] = []
  pretokenize_spans(bytes, starts, ends)
  let mut total = 0
  for i = 0; i < starts.length(); i = i + 1 {
    total = total + encode_piece_count(v, bytes, starts[i], ends[i])
  }
  total
}

///|
/// 完整编码：先把已登记的特殊 token 字面量切出来（最长优先），
/// 其余部分走普通编码。未登记的特殊字面量按普通文本处理（安全默认值）。
pub fn encode(v : VocabView, bytes : Bytes) -> Array[Int] {
  let out : Array[Int] = []
  let first = special_first_bytes(v)
  match first {
    None => encode_ordinary_into(v, bytes, out)
    Some(first) => {
      let n = bytes.length()
      let mut i = 0
      let mut seg_start = 0
      while i < n {
        // 首字节不在集合里 -> 这个位置不可能起头，直接跳过。
        if !first[bytes.unsafe_get(i).to_int() & 0xFF] {
          i = i + 1
          continue
        }
        let (sp_len, sp_id) = match_special(v, bytes, i)
        if sp_len > 0 {
          if i > seg_start {
            encode_ordinary_into(v, slice_bytes(bytes, seg_start, i), out)
          }
          out.push(sp_id)
          i = i + sp_len
          seg_start = i
        } else {
          i = i + 1
        }
      }
      if n > seg_start {
        encode_ordinary_into(v, slice_bytes(bytes, seg_start, n), out)
      }
    }
  }
  out
}

///|
/// 完整编码的"只计数"版本：与 `encode` 同一条切分路径，但不分配 id 数组。
/// `encode_count(v, b) == encode(v, b).length()` 由单元测试守着。
pub fn encode_count(v : VocabView, bytes : Bytes) -> Int {
  let first = special_first_bytes(v)
  match first {
    None => count_ordinary(v, bytes)
    Some(first) => {
      let n = bytes.length()
      let mut total = 0
      let mut i = 0
      let mut seg_start = 0
      while i < n {
        if !first[bytes.unsafe_get(i).to_int() & 0xFF] {
          i = i + 1
          continue
        }
        let (sp_len, _) = match_special(v, bytes, i)
        if sp_len > 0 {
          if i > seg_start {
            total = total + count_ordinary(v, slice_bytes(bytes, seg_start, i))
          }
          total = total + 1
          i = i + sp_len
          seg_start = i
        } else {
          i = i + 1
        }
      }
      if n > seg_start {
        total = total + count_ordinary(v, slice_bytes(bytes, seg_start, n))
      }
      total
    }
  }
}

///|
/// `encode_ordinary` 的"追加到已有数组"版本，避免中间拷贝。
fn encode_ordinary_into(v : VocabView, bytes : Bytes, out : Array[Int]) -> Unit {
  let starts : Array[Int] = []
  let ends : Array[Int] = []
  pretokenize_spans(bytes, starts, ends)
  for i = 0; i < starts.length(); i = i + 1 {
    encode_piece(v, bytes, starts[i], ends[i], out)
  }
}
