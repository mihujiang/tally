// 词表模型与校验。
//
// 不变量（每一条都配测试）：
//   V1 `byte_ids` 的 256 项必须全部存在（byte-level BPE 的根基）。
//   V2 每个 token 的字节长度 >= 1（不许出现空 token）。
//   V3 同一字节序列出现两次 -> 报错，而不是静默取一个。
//   V4 `Vocab` 构造完成后不可变；所有操作都是纯函数。

///|
/// 词表。`tokens[id]` 是该 id 的字节序列；`ranks` 是合并优先级；
/// `ids` 提供"字节序列 -> id"的反查；`specials` 是特殊 token 字面量。
pub(all) struct Vocab {
  tokens : Array[Bytes]
  ranks : Map[Bytes, Int]
  ids : Map[Bytes, Int]
  /// 与 `ranks` / `ids` 同内容的短键表：≤ `@bpe.SHORT_MAX` 字节的 token
  /// 被 `@bpe.pack_short` 打包成 `Int64`，编码热路径查这两张表就省掉了
  /// 每次都拼一个 `Bytes` 出来。构建期一次性填好。
  rank_short : Map[Int64, Int]
  id_short : Map[Int64, Int]
  specials : Array[(String, Int)]
  byte_ids : Array[Int]
}

///|
/// 由三块数据构造一个经过校验的 `Vocab`。
///
/// `specials` 的每一项是 `(字面量, id)`；id 必须落在 `tokens` 的范围内。
pub fn build_vocab(
  tokens : Array[Bytes],
  ranks : Map[Bytes, Int],
  specials : Array[(String, Int)],
) -> Vocab raise VocabError {
  let n = tokens.length()
  let ids : Map[Bytes, Int] = Map([])
  for i = 0; i < n; i = i + 1 {
    let t = tokens[i]
    if t.length() == 0 {
      raise EmptyToken(i)
    }
    match ids.get(t) {
      Some(prev) => raise DuplicateToken(prev, i)
      None => ids.set(t, i)
    }
  }
  // V1：256 个单字节 token 必须齐备。
  let byte_ids : Array[Int] = []
  for b = 0; b < 256; b = b + 1 {
    let one = Bytes::make(1, b.to_byte())
    match ids.get(one) {
      Some(id) => byte_ids.push(id)
      None => raise MissingByteToken(b)
    }
  }
  // 特殊 token：校验 id 范围，并按"字节长度降序、id 升序"排序（最长优先匹配）。
  let sorted : Array[(String, Int)] = []
  for e in specials {
    let (lit, id) = e
    if id < 0 || id >= n {
      raise SpecialOutOfRange(id, n)
    }
    sorted.push((lit, id))
  }
  sort_specials(sorted)
  // 短键表：与 ranks / ids 逐项对应，只是键换成 Int64。
  let rank_short : Map[Int64, Int] = Map([])
  for entry in ranks {
    let (key, r) = entry
    let len = key.length()
    if len > 0 && len <= @bpe.SHORT_MAX {
      rank_short.set(@bpe.pack_short(key, 0, len), r)
    }
  }
  let id_short : Map[Int64, Int] = Map([])
  for entry in ids {
    let (key, id) = entry
    let len = key.length()
    if len > 0 && len <= @bpe.SHORT_MAX {
      id_short.set(@bpe.pack_short(key, 0, len), id)
    }
  }
  {
    tokens,
    ranks,
    ids,
    rank_short,
    id_short,
    specials: sorted,
    byte_ids,
  }
}

///|
/// 就地排序：按字面量的**字节长度降序**，长度相同则按 id 升序。
/// 插入排序，完全确定，不依赖任何库的排序实现。
fn sort_specials(arr : Array[(String, Int)]) -> Unit {
  let n = arr.length()
  for i = 1; i < n; i = i + 1 {
    let cur = arr[i]
    let (cur_lit, cur_id) = cur
    let cur_len = @utf8.encode(cur_lit).length()
    let mut j = i - 1
    while j >= 0 {
      let (lit, id) = arr[j]
      let len = @utf8.encode(lit).length()
      let move_right = len < cur_len || (len == cur_len && id > cur_id)
      if !move_right {
        break
      }
      arr[j + 1] = arr[j]
      j = j - 1
    }
    arr[j + 1] = cur
  }
}

///|
/// token 总数。
pub fn Vocab::token_count(self : Vocab) -> Int {
  self.tokens.length()
}

///|
/// 单字节 token 的 id。
pub fn Vocab::byte_id(self : Vocab, b : Int) -> Int {
  self.byte_ids[b & 0xFF]
}

///|
/// 字节序列的合并优先级（越小越先合并）。
pub fn Vocab::rank_of(self : Vocab, bytes : Bytes) -> Int? {
  self.ranks.get(bytes)
}

///|
/// 字节序列对应的 token id。
pub fn Vocab::id_of(self : Vocab, bytes : Bytes) -> Int? {
  self.ids.get(bytes)
}

///|
/// 已登记的特殊 token 字面量列表（按最长优先排序）。
pub fn Vocab::special_literals(self : Vocab) -> Array[String] {
  self.specials.map(fn(e) {
    let (lit, _) = e
    lit
  })
}

///|
/// 特殊 token 名字对应的 id。
pub fn Vocab::special_id(self : Vocab, name : String) -> Int? {
  for e in self.specials {
    let (lit, id) = e
    if lit == name {
      return Some(id)
    }
  }
  None
}

///|
/// 转成 `bpe` 包认识的视图。`specials` 已是"按长度降序"的顺序。
pub fn Vocab::view(self : Vocab) -> @bpe.VocabView {
  let sp : Array[(Bytes, Int)] = []
  for e in self.specials {
    let (lit, id) = e
    sp.push((@utf8.encode(lit), id))
  }
  {
    tokens: self.tokens,
    byte_ids: self.byte_ids,
    rank_of: self.ranks,
    id_of: self.ids,
    rank_short: self.rank_short,
    id_short: self.id_short,
    specials: sp,
  }
}
