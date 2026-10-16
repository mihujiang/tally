// 训练产物（`tally-train v1`）的导出与回读。
//
// 与 `tally-vocab v1` 的分工：
//
//   * 词表格式存的是**展开后的结果**——每个 id 对应哪串字节；
//   * 训练产物存的是**配方**——参数、特殊 token、合并序列。
//
// 256 个单字节是隐含基座，不必写；合并按 rank 稠密升序，token 表可以完全重建。
// 文件里的 id 一路升序：先 `[merges]`（256 起），再 `[specials]`（接在合并产物之后）。
// 于是训练产物能回答"这份词表是拿什么语料、什么参数训出来的"，词表格式答不了。
// 只存能重建词表的最小信息，不做冗余：冗余字段是漂移的机会。

///|
/// 训练产物的版本标识行。
pub let train_format_header : String = "# tally-train v1"

///|
/// 导出为 `tally-train v1`。
///
/// 与 `to_text` 同源的理由：绝不依赖 Map 的迭代顺序，
/// specials 按 id 升序、merges 按 rank 升序，行尾一律 `\n`。
pub fn TrainResult::to_text(self : TrainResult) -> String {
  let out : Array[Char] = []
  push_str(out, train_format_header)
  push_str(out, "\n")
  push_str(out, "# unicode ")
  push_str(out, @bpe.unicode_version())
  push_str(out, "\n")
  push_str(out, "# corpus_bytes ")
  push_int(out, self.corpus_bytes)
  push_str(out, "\n")
  push_str(out, "# corpus_words ")
  push_int(out, self.corpus_words)
  push_str(out, "\n")
  push_str(out, "# vocab_size ")
  push_int(out, self.vocab_size)
  push_str(out, "\n")
  push_str(out, "# min_frequency ")
  push_int(out, self.min_frequency)
  push_str(out, "\n")
  push_str(out, "# tokens ")
  push_int(out, self.vocab.token_count())
  push_str(out, "\n")
  push_str(out, "[merges]\n")
  for m in self.merges {
    push_int(out, m.rank)
    out.push(' ')
    push_str(out, b64_encode(m.merged))
    out.push(' ')
    push_str(out, b64_encode(m.left))
    out.push(' ')
    push_str(out, b64_encode(m.right))
    out.push('\n')
  }
  push_str(out, "[specials]\n")
  for e in self.vocab.specials {
    let (lit, id) = e
    push_int(out, id)
    out.push(' ')
    push_str(out, b64_encode(@utf8.encode(lit)))
    out.push('\n')
  }
  String::from_array(out)
}

///|
/// 从 `# key value` 元数据行里取十进制值。
fn header_dec(line_no : Int, line : StringView, s : StringView) -> Int raise VocabError {
  match parse_dec(s) {
    Some(v) => v
    None => raise MalformedLine(line_no, line.to_owned())
  }
}

///|
/// 回读 `tally-train v1`，重建 `TrainResult`（词表一并重建）。
///
/// 校验的都是"重建会不会错"的要害：合并 rank 稠密升序、`merged == left + right`、
/// 特殊 token 的 id 接在合并产物之后、`# tokens` 与重建结果相符。
pub fn load_train(text : String) -> TrainResult raise VocabError {
  let merges : Array[Merge] = []
  let specials : Array[(String, Int)] = []
  let mut corpus_bytes = 0
  let mut corpus_words = 0
  let mut vocab_size = 0
  let mut min_frequency = 0
  let mut declared_tokens = 0
  let mut tokens_line = 0
  let mut section = 0 // 0=头部 1=merges 2=specials
  let mut line_no = 0
  for raw in text.split("\n") {
    line_no = line_no + 1
    let line = raw.trim()
    if line.length() == 0 {
      continue
    }
    if line == "[merges]" {
      section = 1
      continue
    }
    if line == "[specials]" {
      section = 2
      continue
    }
    if line.has_prefix("#") {
      let parts = split_fields(line)
      if parts.length() == 3 {
        match parts[1] {
          "corpus_bytes" =>
            corpus_bytes = header_dec(line_no, line, parts[2])
          "corpus_words" =>
            corpus_words = header_dec(line_no, line, parts[2])
          "vocab_size" => vocab_size = header_dec(line_no, line, parts[2])
          "min_frequency" =>
            min_frequency = header_dec(line_no, line, parts[2])
          "tokens" => {
            declared_tokens = header_dec(line_no, line, parts[2])
            tokens_line = line_no
          }
          _ => ()
        }
      }
      continue
    }
    let parts = split_fields(line)
    if section == 1 {
      if parts.length() != 4 {
        raise MalformedLine(line_no, line.to_owned())
      }
      let rank = header_dec(line_no, line, parts[0])
      let merged = b64_decode(parts[1])
      let left = b64_decode(parts[2])
      let right = b64_decode(parts[3])
      // rank 稠密升序才是训练的真实产物；merged 必须真是 left ++ right。
      if rank != 256 + merges.length() {
        raise MalformedLine(line_no, line.to_owned())
      }
      if !bytes_eq(merged, @bpe.concat_bytes(left, right)) {
        raise MalformedLine(line_no, line.to_owned())
      }
      merges.push({ rank: rank, merged: merged, left: left, right: right })
    } else if section == 2 {
      if parts.length() != 2 {
        raise MalformedLine(line_no, line.to_owned())
      }
      let id = header_dec(line_no, line, parts[0])
      // 特殊 token 紧跟在 256 个基座与全部合并产物之后。
      if id != 256 + merges.length() + specials.length() {
        raise MalformedLine(line_no, line.to_owned())
      }
      specials.push((@utf8.decode_lossy(b64_decode(parts[1])), id))
    } else {
      raise UnknownSection(line.to_owned())
    }
  }

  // 重建 token 表：基座 -> 合并产物 -> 特殊 token。
  let tokens : Array[Bytes] = []
  let ranks : Map[Bytes, Int] = Map([])
  for b = 0; b < 256; b = b + 1 {
    let one = Bytes::make(1, b.to_byte())
    ranks.set(one, b)
    tokens.push(one)
  }
  for m in merges {
    ranks.set(m.merged, m.rank)
    tokens.push(m.merged)
  }
  for e in specials {
    tokens.push(@utf8.encode(e.0))
  }
  let vocab = build_vocab(tokens, ranks, specials)
  if declared_tokens != vocab.token_count() {
    raise MalformedLine(tokens_line, "# tokens 与重建结果不符")
  }
  {
    vocab: vocab,
    merges: merges,
    corpus_bytes: corpus_bytes,
    corpus_words: corpus_words,
    vocab_size: vocab_size,
    min_frequency: min_frequency,
  }
}
