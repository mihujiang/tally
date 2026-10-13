// 便利层：让 `vocab` 的使用者不必手动构造 `bpe` 的视图。
//
// `tally` 根包与 `budget` 都只经这一层使用编码能力。

///|
/// 编码任意字节序列（含特殊 token 切分）。
pub fn Vocab::encode_bytes(self : Vocab, bytes : Bytes) -> Array[Int] {
  @bpe.encode(self.view(), bytes)
}

///|
/// 编码一段文本。注意：先整体 UTF-8 编码，再按字节编码。
pub fn Vocab::encode_string(self : Vocab, text : String) -> Array[Int] {
  @bpe.encode(self.view(), @utf8.encode(text))
}

///|
/// 不做特殊 token 切分的编码（把它们当普通文本）。
pub fn Vocab::encode_ordinary_bytes(self : Vocab, bytes : Bytes) -> Array[Int] {
  @bpe.encode_ordinary(self.view(), bytes)
}

///|
/// token id 序列 -> 原始字节。
pub fn Vocab::decode_ids(self : Vocab, ids : Array[Int]) -> Bytes {
  @bpe.decode(self.view(), ids)
}

///|
/// 字节序列的 token 数（`Int64`：所有累计量都用 64 位，避免 32 位静默溢出）。
pub fn Vocab::count_bytes(self : Vocab, bytes : Bytes) -> Int64 {
  self.encode_bytes(bytes).length().to_int64()
}

///|
/// 文本的 token 数。
pub fn Vocab::count(self : Vocab, text : String) -> Int64 {
  self.count_bytes(@utf8.encode(text))
}
