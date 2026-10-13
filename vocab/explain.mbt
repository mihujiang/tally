// `count --explain` 用的逐片明细。
//
// 这一层回答"到底哪段在吃 token"：把预切分的每一片连同它的 token 数列出。

///|
/// 逐片明细：`(片文本, 该片的 token 数)`。
pub fn Vocab::piece_counts(self : Vocab, bytes : Bytes) -> Array[(String, Int64)] {
  let view = self.view()
  let out : Array[(String, Int64)] = []
  let pieces = @bpe.pretokenize(bytes)
  for entry in pieces {
    let (start, end) = entry
    let piece = @bpe.slice_bytes(bytes, start, end)
    let n = @bpe.encode_ordinary(view, piece).length().to_int64()
    out.push((@utf8.decode_lossy(piece), n))
  }
  out
}
