// 词表层测试：加载、编码一致性、导出/回读、以及各条不变量的拒绝路径。

///|
/// 256 个单字节 token（id = rank = 0..255）。
fn byte_tokens() -> (Array[Bytes], Map[Bytes, Int]) {
  let tokens : Array[Bytes] = []
  let ranks : Map[Bytes, Int] = Map([])
  for b = 0; b < 256; b = b + 1 {
    let one = Bytes::make(1, b.to_byte())
    tokens.push(one)
    ranks.set(one, b)
  }
  (tokens, ranks)
}

///|
test "sample vocab loads and satisfies the invariants" {
  let v = load(sample_vocab_text)
  assert_eq(v.token_count(), 277)
  // V1：单字节 token 齐备，且 id 就是字节值
  for b = 0; b < 256; b = b + 1 {
    assert_eq(v.byte_id(b), b)
  }
  // 特殊 token
  assert_eq(v.special_id("<|endoftext|>"), Some(276))
}

///|
test "sample vocab encodes whole words into single tokens" {
  let v = load(sample_vocab_text)
  // 夹具里 "hello" 被合并成了一个 token
  assert_eq(v.encode_string("hello"), [259])
  assert_eq(v.count("hello"), 1L)
  assert_eq(v.count("hello world"), 2L) // ["hello", " world"]
  // 数字按最多 3 位分组：["123", "4"]，每个数字字符都是单字节 token
  assert_eq(v.count("1234"), 4L)
}

///|
test "round trip through the sample vocab" {
  let v = load(sample_vocab_text)
  let texts = [
    "hello world",
    "it's a test 1234",
    "中文混排 + emoji 🎉",
    "  \n\n\t trailing  ",
    "",
  ]
  for t in texts {
    assert_true(v.decode_ids(v.encode_string(t)) == @utf8.encode(t))
  }
}

///|
test "export then reload is stable (V10)" {
  let v = load(sample_vocab_text)
  let text1 = v.to_text()
  let v2 = load(text1)
  let text2 = v2.to_text()
  assert_eq(text1, text2)
  assert_eq(v2.token_count(), v.token_count())
  // 逐字节稳定：再导出一次必须完全相同
  assert_eq(load(text2).to_text(), text1)
}

///|
test "duplicate byte sequences are rejected (V3)" {
  let (tokens, ranks) = byte_tokens()
  tokens.push(Bytes::make(1, (0).to_byte()))
  let caught = try {
    let _ = build_vocab(tokens, ranks, [])
    "none"
  } catch {
    DuplicateToken(_, _) => "duplicate"
    _ => "other"
  }
  assert_eq(caught, "duplicate")
}

///|
test "missing single byte token is rejected (V1)" {
  let tokens : Array[Bytes] = []
  let ranks : Map[Bytes, Int] = Map([])
  for b = 0; b < 256; b = b + 1 {
    if b == 200 {
      continue
    }
    let one = Bytes::make(1, b.to_byte())
    tokens.push(one)
    ranks.set(one, b)
  }
  let caught = try {
    let _ = build_vocab(tokens, ranks, [])
    "none"
  } catch {
    MissingByteToken(_) => "missing"
    _ => "other"
  }
  assert_eq(caught, "missing")
}

///|
test "empty token is rejected (V2)" {
  let caught = try {
    let _ = build_vocab([Bytes::new(0)], Map([]), [])
    "none"
  } catch {
    EmptyToken(_) => "empty"
    _ => "other"
  }
  assert_eq(caught, "empty")
}

///|
test "tiktoken-style text loads" {
  // "Zg==" -> b"f" (rank 0), "bw==" -> b"o" (rank 1)
  let (tokens, ranks) = byte_tokens()
  tokens.push(@utf8.encode("<|eot|>"))
  ranks.set(@utf8.encode("<|eot|>"), 256)
  let text = tokens_to_tiktoken(tokens, ranks)
  let v = load_tiktoken(text, [("<|eot|>", 256)])
  assert_eq(v.token_count(), 257)
  assert_eq(v.special_id("<|eot|>"), Some(256))
}

///|
/// 把内存里的词表渲染成 `.tiktoken` 风格文本（仅供测试使用）。
fn tokens_to_tiktoken(tokens : Array[Bytes], ranks : Map[Bytes, Int]) -> String {
  let out : Array[Char] = []
  for id = 0; id < tokens.length(); id = id + 1 {
    let blob = tokens[id]
    let rank = match ranks.get(blob) {
      Some(r) => r
      None => id
    }
    for c in b64_encode(blob).to_array() {
      out.push(c)
    }
    out.push(' ')
    for c in rank.to_string().to_array() {
      out.push(c)
    }
    out.push('\n')
  }
  String::from_array(out)
}
