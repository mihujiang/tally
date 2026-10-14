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
  specials : Array[(Bytes, Int)]
}

///|
/// 逐片做 BPE 合并，把结果追加到 `out`。
fn encode_piece(v : VocabView, piece : Bytes, out : Array[Int]) -> Unit {
  let n = piece.length()
  if n == 0 {
    return
  }
  let ids : Array[Int] = []
  let parts : Array[Bytes] = []
  for i = 0; i < n; i = i + 1 {
    let b = piece.unsafe_get(i).to_int() & 0xFF
    // 单字节 token 必须存在，否则 byte-level BPE 不成立（见 V1/V7）。
    ids.push(v.byte_ids[b])
    parts.push(slice_bytes(piece, i, i + 1))
  }
  while ids.length() > 1 {
    let len = ids.length()
    let mut best_rank = -1
    let mut best_i = -1
    for i = 0; i < len - 1; i = i + 1 {
      let merged = concat_bytes(parts[i], parts[i + 1])
      match v.rank_of.get(merged) {
        Some(r) =>
          if best_i < 0 || r < best_rank {
            best_rank = r
            best_i = i
          }
        None => ()
      }
    }
    if best_i < 0 {
      break
    }
    let merged = concat_bytes(parts[best_i], parts[best_i + 1])
    parts[best_i] = merged
    // `merged` 一定在 `id_of` 里：它能在 `rank_of` 里被找到。
    match v.id_of.get(merged) {
      Some(id) => ids[best_i] = id
      None => ()
    }
    let _ = parts.remove(best_i + 1)
    let _ = ids.remove(best_i + 1)
  }
  for id in ids {
    out.push(id)
  }
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
/// 把一段普通文本（不含特殊 token）编码为 token id 序列。
pub fn encode_ordinary(v : VocabView, bytes : Bytes) -> Array[Int] {
  let out : Array[Int] = []
  encode_ordinary_into(v, bytes, out)
  out
}

///|
/// 完整编码：先把已登记的特殊 token 字面量切出来（最长优先），
/// 其余部分走普通编码。未登记的特殊字面量按普通文本处理（安全默认值）。
pub fn encode(v : VocabView, bytes : Bytes) -> Array[Int] {
  let out : Array[Int] = []
  let n = bytes.length()
  let mut i = 0
  let mut seg_start = 0
  while i < n {
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
  out
}

///|
/// `encode_ordinary` 的"追加到已有数组"版本，避免中间拷贝。
fn encode_ordinary_into(v : VocabView, bytes : Bytes, out : Array[Int]) -> Unit {
  let pieces = pretokenize(bytes)
  for entry in pieces {
    let (start, end) = entry
    encode_piece(v, slice_bytes(bytes, start, end), out)
  }
}
