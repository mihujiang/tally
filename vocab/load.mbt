// 词表加载与规范导出。
//
// 支持两种输入：
//   1. `.tiktoken` 风格：每行 `<base64(token 字节)> <rank>`（rank 即 id）。
//      —— 这是**数据格式**的处理，不是代码移植（计划 §5.5）。
//   2. 自有规范文本格式 `tally-vocab v1`（可 diff、可指纹，见 export.mbt）。
//
// 自有格式把 id 与 rank 显式分开，且 id 必须稠密升序，
// 这样导出是逐字节稳定的（不变量 V10）。

///|
/// 自有格式的版本标识行。
pub let format_header : String = "# tally-vocab v1"

///|
/// 把一行按空格切成非空字段。格式是规范的，不做多余的宽容。
fn split_fields(line : StringView) -> Array[String] {
  let out : Array[String] = []
  for p in line.split(" ") {
    if p.length() > 0 {
      out.push(p.to_owned())
    }
  }
  out
}

///|
/// 解析非负十进制整数（不依赖标准库的整数解析，避免版本漂移）。
fn parse_dec(s : StringView) -> Int? {
  let chars = s.to_array()
  let n = chars.length()
  if n == 0 {
    return None
  }
  let mut v = 0
  for i = 0; i < n; i = i + 1 {
    let d = chars[i].to_int() - 0x30
    if d < 0 || d > 9 {
      return None
    }
    v = v * 10 + d
  }
  Some(v)
}

///|
/// 加载自有规范文本格式。
pub fn load(text : String) -> Vocab raise VocabError {
  let tokens : Array[Bytes] = []
  let ranks : Map[Bytes, Int] = Map([])
  let specials : Array[(String, Int)] = []
  let mut section = 0 // 0=未开始 1=specials 2=tokens
  let mut line_no = 0
  for raw in text.split("\n") {
    line_no = line_no + 1
    let line = raw.trim()
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") {
      continue
    }
    if line == "[specials]" {
      section = 1
      continue
    }
    if line == "[tokens]" {
      section = 2
      continue
    }
    let parts = split_fields(line)
    if section == 1 {
      if parts.length() != 2 {
        raise MalformedLine(line_no, line.to_owned())
      }
      match parse_dec(parts[0]) {
        None => raise MalformedLine(line_no, line.to_owned())
        Some(id) => {
          let lit = b64_decode(parts[1])
          specials.push((@utf8.decode_lossy(lit), id))
        }
      }
    } else if section == 2 {
      if parts.length() != 3 {
        raise MalformedLine(line_no, line.to_owned())
      }
      match (parse_dec(parts[0]), parse_dec(parts[1])) {
        (Some(id), Some(rank)) => {
          if id != tokens.length() {
            // id 必须稠密升序，否则导出不稳定
            raise MalformedLine(line_no, line.to_owned())
          }
          let bytes = b64_decode(parts[2])
          tokens.push(bytes)
          ranks.set(bytes, rank)
        }
        _ => raise MalformedLine(line_no, line.to_owned())
      }
    } else {
      raise UnknownSection(line.to_owned())
    }
  }
  build_vocab(tokens, ranks, specials)
}

///|
/// 加载 `.tiktoken` 风格的词表：每行 `<base64> <rank>`，rank 即 id。
///
/// `specials` 由调用方传入（字面量, id），因为该格式不携带特殊 token 定义。
pub fn load_tiktoken(
  text : String,
  specials : Array[(String, Int)],
) -> Vocab raise VocabError {
  let pairs : Array[(Bytes, Int)] = []
  let mut max_rank = -1
  let mut line_no = 0
  for raw in text.split("\n") {
    line_no = line_no + 1
    let line = raw.trim()
    if line.length() == 0 {
      continue
    }
    let parts = split_fields(line)
    if parts.length() != 2 {
      raise MalformedLine(line_no, line.to_owned())
    }
    let bytes = b64_decode(parts[0])
    match parse_dec(parts[1]) {
      None => raise MalformedLine(line_no, line.to_owned())
      Some(rank) => {
        pairs.push((bytes, rank))
        if rank > max_rank {
          max_rank = rank
        }
      }
    }
  }
  let n = max_rank + 1
  let slots : Array[Bytes?] = Array::make(n, None)
  let ranks : Map[Bytes, Int] = Map([])
  for e in pairs {
    let (bytes, rank) = e
    slots[rank] = Some(bytes)
    ranks.set(bytes, rank)
  }
  let tokens : Array[Bytes] = []
  for i = 0; i < n; i = i + 1 {
    match slots[i] {
      Some(b) => tokens.push(b)
      None => raise MalformedLine(0, "rank 不连续")
    }
  }
  build_vocab(tokens, ranks, specials)
}
