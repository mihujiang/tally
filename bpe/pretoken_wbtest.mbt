// 预切分扫描器的行为测试。
//
// 每一条都对应手写模式里的一个分支或一个容易被写错的边界。

///|
/// `String` 的编码结果必然是合法 UTF-8，走的就是「Unicode 语义」那条路径。
fn pieces_text(text : String) -> Array[String] {
  let bytes = @utf8.encode(text)
  let out : Array[String] = []
  for entry in pretokenize(bytes) {
    let (start, end) = entry
    out.push(@utf8.decode_lossy(slice_bytes(bytes, start, end)))
  }
  out
}

///|
test "letters and contractions" {
  assert_eq(pieces_text("hello world"), ["hello", " world"])
  assert_eq(pieces_text("it's a test"), ["it", "'s", " a", " test"])
  assert_eq(pieces_text("I'M"), ["I", "'M"])
  assert_eq(pieces_text("we'll"), ["we", "'ll"])
}

///|
test "optional lead char before letters" {
  // 分支 2 的可选前导：' ' + 字母 会被吃进同一片
  assert_eq(pieces_text(" hello"), [" hello"])
  // 前导不能是 \r 或 \n
  assert_eq(pieces_text("\nhello"), ["\n", "hello"])
  // 前导也可以是标点（非字母/数字/换行）：'(' 与 'a' 吃进同一片
  assert_eq(pieces_text("(a)"), ["(a", ")"])
}

///|
test "digits are grouped by at most three" {
  assert_eq(pieces_text("1234"), ["123", "4"])
  assert_eq(pieces_text("12"), ["12"])
  assert_eq(pieces_text("a12b"), ["a", "12", "b"])
}

///|
test "punctuation run grabs trailing newlines" {
  assert_eq(pieces_text("...\n\nx"), ["...\n\n", "x"])
  assert_eq(pieces_text("a!!!"), ["a", "!!!"])
}

///|
test "whitespace runs" {
  assert_eq(pieces_text("a\n\nb"), ["a", "\n\n", "b"])
  // 行尾空白 + 换行由 `\s*[\r\n]+` 整段吸收；其后剩余空白按 `\s+(?!\S)` 只吃一格，
  // 末尾那格空格成为下一片的可选前导（` ?[^\s...]?` 分支），与参考实现一致。
  assert_eq(pieces_text("a  \n  b"), ["a", "  \n", " ", " b"])
  // 结尾全是空白：`\s+(?!\S)` 没有可回退的非空白，整段吃掉
  assert_eq(pieces_text("a  "), ["a", "  "])
  assert_eq(pieces_text("a  b"), ["a", " ", " b"])
}

///|
fn bytes_of(values : Array[Int]) -> Bytes {
  let out : Array[Byte] = []
  for v in values {
    out.push(v.to_byte())
  }
  Bytes::from_array(out)
}

///|
test "invalid bytes stay byte-faithful" {
  // 0xFF 是非法 UTF-8 首字节：按"其它"类处理，且原样保留
  let bytes = bytes_of([0x61, 0xFF, 0x62])
  let pieces = pretokenize(bytes)
  let joined : Array[Byte] = []
  for entry in pieces {
    let (start, end) = entry
    for i = start; i < end; i = i + 1 {
      joined.push(bytes[i])
    }
  }
  assert_true(Bytes::from_array(joined) == bytes_of([0x61, 0xFF, 0x62]))
}
