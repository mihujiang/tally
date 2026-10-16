// BPE 训练：给定语料与参数，产出**逐字节可复现**的词表。
//
// 训练与编码共用同一套预切分（`@bpe.pretokenize`）：训练时把每片当成一个"词"，
// 于是学出来的合并规则恰好就是编码时会用到的那批——两边不会错位。
//
// ## 可复现性从哪来
//
// 训练里唯一的"选择"是：每一步合并哪个 pair。只要这个选择由**全序**决定，
// 训练就是纯函数。规则（tie-break，写进规范）：
//
//   1. pair 频次降序；
//   2. 频次相同 -> `left` 字节序升序；
//   3. 再相同 -> `right` 字节序升序。
//
// 第 2、3 条合起来对**不同的 pair** 构成全序（pair 就是 `(left, right)`），
// 所以永远不存在并列，排序稳不稳定都无所谓。另外：
//
// * 频次是整数累加，与遍历顺序无关；
// * 词在统计前先按字节序排好，训练与 `Map` 的迭代顺序**完全无关**；
// * 候选挑选用自写的归并排序，不依赖任何库的排序实现。
//
// 这三条加在一起，才敢说"同输入两次训练逐字节一致"。

///|
/// 一次合并：把 `left` 与 `right` 拼成 `merged`，占据 `rank` 位。
pub(all) struct Merge {
  rank : Int
  merged : Bytes
  left : Bytes
  right : Bytes
}

///|
/// 一次训练的完整产物。
///
/// 除了词表本身，还把**输入与参数**一并带上：只有词表无法回答
/// "这是拿什么语料、什么参数训出来的"，而"可复现"要求这个问题有答案。
pub(all) struct TrainResult {
  vocab : Vocab
  merges : Array[Merge]
  corpus_bytes : Int
  corpus_words : Int
  vocab_size : Int
  min_frequency : Int
}

///|
/// 字节序比较（memcmp 语义）：`-1` / `0` / `1`。
fn compare_bytes(a : Bytes, b : Bytes) -> Int {
  let an = a.length()
  let bn = b.length()
  let n = if an < bn { an } else { bn }
  for i = 0; i < n; i = i + 1 {
    let x = a[i].to_int() & 0xFF
    let y = b[i].to_int() & 0xFF
    if x < y {
      return -1
    }
    if x > y {
      return 1
    }
  }
  if an < bn {
    return -1
  }
  if an > bn {
    return 1
  }
  0
}

///|
/// 字节序列相等：先比长度（绝大多数不等在这一步就出局），再逐字节比。
fn bytes_eq(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  compare_bytes(a, b) == 0
}

///|
/// pair 的无歧义键：`左长度(2 字节大端) + 左 + 右`。
///
/// 不能拿 `左 ++ 右` 当键：`("ab","c")` 与 `("a","bc")` 都拼成 `"abc"`，
/// 却是**两个不同的 pair**，频次必须分开累计。前缀长度把这件事说清楚。
fn pair_key(left : Bytes, right : Bytes) -> Bytes {
  let ln = left.length()
  let rn = right.length()
  let out : Array[Byte] = Array::make(2 + ln + rn, (0).to_byte())
  out[0] = (ln >> 8).to_byte()
  out[1] = (ln & 0xFF).to_byte()
  for i = 0; i < ln; i = i + 1 {
    out[2 + i] = left.unsafe_get(i)
  }
  for i = 0; i < rn; i = i + 1 {
    out[2 + ln + i] = right.unsafe_get(i)
  }
  Bytes::from_array(out)
}

///|
/// 对下标数组做自写的**稳定归并排序**。
///
/// 不调用库排序：训练的可复现性不该依赖"某个库的排序稳不稳定"这种实现细节。
/// `less(i, j)` 为真表示 `i` 排在 `j` 前面。
fn sort_indices(order : Array[Int], less : (Int, Int) -> Bool) -> Unit {
  let n = order.length()
  if n < 2 {
    return
  }
  let buf : Array[Int] = Array::make(n, 0)
  let mut width = 1
  while width < n {
    let mut i = 0
    while i < n {
      let mid = if i + width < n { i + width } else { n }
      let end = if i + 2 * width < n { i + 2 * width } else { n }
      let mut a = i
      let mut b = mid
      let mut k = i
      while a < mid || b < end {
        // 相等时先取左边 -> 稳定。
        if a < mid && (b >= end || !less(order[b], order[a])) {
          buf[k] = order[a]
          a = a + 1
        } else {
          buf[k] = order[b]
          b = b + 1
        }
        k = k + 1
      }
      i = i + 2 * width
    }
    for j = 0; j < n; j = j + 1 {
      order[j] = buf[j]
    }
    width = width * 2
  }
}

///|
/// 候选排序：频次降序 -> `left` 字节序升序 -> `right` 字节序升序。
fn candidate_less(
  lefts : Array[Bytes],
  rights : Array[Bytes],
  counts : Array[Int64],
  i : Int,
  j : Int,
) -> Bool {
  if counts[i] != counts[j] {
    return counts[i] > counts[j]
  }
  let c = compare_bytes(lefts[i], lefts[j])
  if c != 0 {
    return c < 0
  }
  compare_bytes(rights[i], rights[j]) < 0
}

///|
/// 在一段符号序列里，把 `(left, right)` 全部就地合并成 `merged`。
///
/// 从左到右扫一遍，每次匹配吃掉两个符号，因此结果**不重叠**——
/// 这与编码器逐片合并的语义一致。
fn merge_once(
  seq : Array[Bytes],
  left : Bytes,
  right : Bytes,
  merged : Bytes,
) -> Array[Bytes] {
  let out : Array[Bytes] = []
  let mut i = 0
  let n = seq.length()
  while i < n {
    if i + 1 < n && bytes_eq(seq[i], left) && bytes_eq(seq[i + 1], right) {
      out.push(merged)
      i = i + 2
    } else {
      out.push(seq[i])
      i = i + 1
    }
  }
  out
}

///|
/// 从语料训练一个词表。
///
/// * `vocab_size` —— **目标总数**，含 256 个单字节与 `specials`。
///   语料不够（或频次不够）就提前停下，不补零、不灌水。
/// * `min_frequency` —— pair 频次低于它就停止合并（GPT-2 传统取 2）。
///   取 0 或负数表示"只看 `vocab_size`，不设频次下限"。
/// * `specials` —— 特殊 token 字面量，按给定顺序追加在合并产物之后。
///
/// 返回的 `TrainResult` 同时带出合并序列与本次的参数，便于冻结与 diff。
pub fn train(
  corpus : Array[Bytes],
  vocab_size : Int,
  min_frequency : Int,
  specials : Array[String],
) -> TrainResult raise VocabError {
  let floor = 256 + specials.length()
  if vocab_size < floor {
    raise TrainSizeTooSmall(vocab_size, floor)
  }

  // 1. 基座：256 个单字节，id 与 rank 都是 0..255。
  let tokens : Array[Bytes] = []
  let ranks : Map[Bytes, Int] = Map([])
  for b = 0; b < 256; b = b + 1 {
    let one = Bytes::make(1, b.to_byte())
    ranks.set(one, b)
    tokens.push(one)
  }

  // 2. 预切分 + 词频。
  let freq : Map[Bytes, Int64] = Map([])
  let mut corpus_bytes = 0
  for doc in corpus {
    corpus_bytes = corpus_bytes + doc.length()
    for entry in @bpe.pretokenize(doc) {
      let (s, e) = entry
      if e > s {
        let piece = @bpe.slice_bytes(doc, s, e)
        match freq.get(piece) {
          Some(c) => freq.set(piece, c + 1L)
          None => freq.set(piece, 1L)
        }
      }
    }
  }

  // 3. 词按字节序排好：训练从此与 Map 的迭代顺序彻底无关。
  let raw_words : Array[Bytes] = []
  let raw_freq : Array[Int64] = []
  for k, v in freq {
    raw_words.push(k)
    raw_freq.push(v)
  }
  let word_order : Array[Int] = []
  for i = 0; i < raw_words.length(); i = i + 1 {
    word_order.push(i)
  }
  sort_indices(word_order, fn(i, j) { compare_bytes(raw_words[i], raw_words[j]) < 0 })
  let words : Array[Bytes] = []
  let word_freq : Array[Int64] = []
  for i in word_order {
    words.push(raw_words[i])
    word_freq.push(raw_freq[i])
  }

  // 4. 每个词展开成单字节符号序列，逐步合并。
  let syms : Array[Array[Bytes]] = []
  for w in words {
    let s : Array[Bytes] = []
    for i = 0; i < w.length(); i = i + 1 {
      s.push(Bytes::make(1, w[i]))
    }
    syms.push(s)
  }

  let merges : Array[Merge] = []
  let limit = vocab_size - specials.length()
  while tokens.length() < limit {
    // 统计当前所有相邻 pair（按词频加权）。
    let lefts : Array[Bytes] = []
    let rights : Array[Bytes] = []
    let counts : Array[Int64] = []
    let index : Map[Bytes, Int] = Map([])
    for wi = 0; wi < syms.length(); wi = wi + 1 {
      let seq = syms[wi]
      let f = word_freq[wi]
      let mut i = 0
      while i + 1 < seq.length() {
        let key = pair_key(seq[i], seq[i + 1])
        match index.get(key) {
          Some(k) => counts[k] = counts[k] + f
          None => {
            index.set(key, lefts.length())
            lefts.push(seq[i])
            rights.push(seq[i + 1])
            counts.push(f)
          }
        }
        i = i + 1
      }
    }
    if lefts.length() == 0 {
      break
    }
    let order : Array[Int] = []
    for i = 0; i < lefts.length(); i = i + 1 {
      order.push(i)
    }
    sort_indices(order, fn(i, j) { candidate_less(lefts, rights, counts, i, j) })
    let best = order[0]
    if min_frequency > 0 && counts[best] < min_frequency.to_int64() {
      break
    }
    let merged = @bpe.concat_bytes(lefts[best], rights[best])
    let rank = tokens.length()
    ranks.set(merged, rank)
    tokens.push(merged)
    merges.push(
      { rank: rank, merged: merged, left: lefts[best], right: rights[best] },
    )
    for wi = 0; wi < syms.length(); wi = wi + 1 {
      syms[wi] = merge_once(syms[wi], lefts[best], rights[best], merged)
    }
  }

  // 5. 特殊 token 追加在合并产物之后（顺序由调用方给定，天然确定）。
  let special_entries : Array[(String, Int)] = []
  for lit in specials {
    let id = tokens.length()
    tokens.push(@utf8.encode(lit))
    special_entries.push((lit, id))
  }
  {
    vocab: build_vocab(tokens, ranks, special_entries),
    merges: merges,
    corpus_bytes: corpus_bytes,
    corpus_words: words.length(),
    vocab_size: vocab_size,
    min_frequency: min_frequency,
  }
}
