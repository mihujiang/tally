// 内核测试：合并、特殊 token、字节保真往返（不变量 V6/V7/V8）。

///|
/// 构造一个"只有单字节 token"的最小视图（byte-level BPE 的退化情形）。
fn byte_only_view() -> VocabView {
  view_with([], [])
}

///|
/// 构造视图：`extra` 依次追加为 id 256、257、…（rank 同步递增）；
/// `specials` 是 `(字面量, id)`。
fn view_with(
  extra : Array[Bytes],
  specials_in : Array[(Bytes, Int)],
) -> VocabView {
  let tokens : Array[Bytes] = []
  let byte_ids : Array[Int] = []
  let id_of : Map[Bytes, Int] = Map([])
  let rank_of : Map[Bytes, Int] = Map([])
  for b = 0; b < 256; b = b + 1 {
    let one = Bytes::make(1, b.to_byte())
    tokens.push(one)
    byte_ids.push(b)
    id_of.set(one, b)
  }
  for blob in extra {
    let id = tokens.length()
    tokens.push(blob)
    id_of.set(blob, id)
    rank_of.set(blob, id)
  }
  let specials : Array[(Bytes, Int)] = []
  for e in specials_in {
    specials.push(e)
  }
  { tokens, byte_ids, rank_of, id_of, specials }
}

///|
test "round trip is byte exact (V6)" {
  let v = byte_only_view()
  let inputs : Array[Bytes] = [
    bytes_of([0x68, 0x69]), // "hi"
    @utf8.encode("中文 emoji 🎉"),
    bytes_of([0xFF, 0xFE, 0x00, 0x80]), // 非法 UTF-8
    Bytes::new(0),
    @utf8.encode("mixed 混合\n\n\t end  "),
  ]
  for input in inputs {
    assert_true(decode(v, encode_ordinary(v, input)) == input)
  }
}

///|
test "merges pick the lowest rank (V8)" {
  let v = view_with(
    [
      @utf8.encode("he"),
      @utf8.encode("hel"),
      @utf8.encode("hell"),
      @utf8.encode("hello"),
    ],
    [],
  )
  let ids = encode_ordinary(v, @utf8.encode("hello"))
  assert_eq(ids, [259])
  assert_true(decode(v, ids) == @utf8.encode("hello"))
}

///|
test "special tokens are matched longest first (V8)" {
  let eot = @utf8.encode("<|eot|>")
  let short = @utf8.encode("<|eo")
  let v = view_with(
    [short, eot],
    [(short, 256), (eot, 257)],
  )
  let ids = encode(v, @utf8.encode("a<|eot|>b"))
  assert_eq(ids, [97, 257, 98])
  assert_true(decode(v, ids) == @utf8.encode("a<|eot|>b"))
}

///|
test "unregistered special-looking text is encoded as ordinary text" {
  let v = view_with([], [])
  let text = @utf8.encode("<|eot|>")
  // 没有登记特殊 token 时必须能逐字节还原，而不是被吞掉
  assert_true(decode(v, encode(v, text)) == text)
}

///|
test "specials inside a pretoken are still recognised" {
  // 特殊 token 切分发生在预切分**之前**：即使它落在字母流中间也要被切出来
  let eot = @utf8.encode("<|eot|>")
  let v = view_with([eot], [(eot, 256)])
  let ids = encode(v, @utf8.encode("hello<|eot|>world"))
  assert_true(decode(v, ids) == @utf8.encode("hello<|eot|>world"))
  assert_true(ids.contains(256))
}
