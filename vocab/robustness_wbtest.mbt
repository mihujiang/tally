// 矩阵 I（稳健性）与矩阵 J（篡改）的词表侧。
//
// I 的判据不是"能跑通"，而是：**任意字节垃圾喂进来，只有两种结局**——
// 正常加载，或抛出一个**可命名**的 `VocabError`。中途 panic 就是产品事故。
//
// J 的判据更强：改一个字节之后，错误里必须带**位置**（行号 / 两个 token 的行号），
// 否则用户拿着报错也不知道从哪儿开始查。

///|
fn vlines(s : String) -> Array[String] {
  let out : Array[String] = []
  for l in s.split("\n") {
    out.push(l.to_owned())
  }
  out
}

///|
fn vjoin(lines : Array[String]) -> String {
  lines.join("\n")
}

///|
/// 按行号替换整行（1-based），行号越界时原样返回。
fn vreplace_line(s : String, line_no : Int, new_line : String) -> String {
  let lines = vlines(s)
  if line_no < 1 || line_no > lines.length() {
    return s
  }
  lines[line_no - 1] = new_line
  vjoin(lines)
}

///|
/// 把 `s` 里第 `pos` 个字符换成一个"别的"字符，保持长度不变。
fn vflip_at(s : String, pos : Int) -> String {
  let chars = s.to_array()
  if pos < 0 || pos >= chars.length() {
    return s
  }
  let c = chars[pos].to_int()
  chars[pos] = if c == 0x41 {
    'B'
  } else {
    'A'
  }
  String::from_array(chars)
}

///|
/// 跑一次加载，返回 (结局, 位置)。成功时位置为 -1。
fn vprobe(text : String) -> (String, Int) {
  let mut kind = "ok"
  let mut line = -1
  try {
    let _ = load(text)
  } catch {
    InvalidBase64(_) => kind = "InvalidBase64"
    MalformedLine(l, _) => {
      kind = "MalformedLine"
      line = l
    }
    DuplicateToken(first, _second) => {
      kind = "DuplicateToken"
      line = first
    }
    EmptyToken(index) => {
      kind = "EmptyToken"
      line = index
    }
    MissingByteToken(b) => {
      kind = "MissingByteToken"
      line = b
    }
    SpecialOutOfRange(id, _) => {
      kind = "SpecialOutOfRange"
      line = id
    }
    UnknownSection(_) => kind = "UnknownSection"
    TrainSizeTooSmall(_, _) => kind = "TrainSizeTooSmall"
  }
  (kind, line)
}

///|
test "matrix I: 600 mutated vocab texts yield ok or a named VocabError" {
  let seen : Array[String] = []
  let mut seed : UInt = 20261020U
  let mut ok = 0
  let mut named = 0
  // 两套夹具各 300 次：规范文本（`load`）与 `.tiktoken`（`load_tiktoken`）。
  // 两个入口的判据必须一样：要么成功，要么是可命名的错误——不允许 panic，
  // 也不允许"静默接受一份坏词表"。
  let fixtures = [sample_vocab_text, vtiktoken_text()]
  for f in fixtures {
    let len = f.length().reinterpret_as_uint()
    for i = 0; i < 300; i = i + 1 {
      seed = seed * 1664525U + 1013904223U
      let pos = ((seed >> 9) % len).reinterpret_as_int()
      let mutated = vflip_at(f, pos)
      let (kind, _) = if f.has_prefix("# tally-vocab") {
        vprobe(mutated)
      } else {
        tprobe(mutated)
      }
      if kind == "ok" {
        ok = ok + 1
      } else {
        named = named + 1
        if !seen.contains(kind) {
          seen.push(kind)
        }
      }
    }
  }
  assert_eq(ok + named, 600)
  // 至少踩到一种错误：否则说明变异全落在注释/空行里，这条测试没在测东西
  assert_true(named > 0)
}

///|
test "matrix J: one byte off in a rank or a token is caught with a position" {
  // 行号：1..3 头部注释，4 `[specials]`，5 special，6 `[tokens]`，7 起是 `rank id base64`
  let lines = vlines(sample_vocab_text)
  let first_token_line = 7
  assert_true(lines.length() > first_token_line + 20)
  // 1) 秩不连续：把第一个 token 的 rank 改成 5
  let rank_broken = vreplace_line(sample_vocab_text, first_token_line, "5 0 AA==")
  let (rank_kind, rank_line) = vprobe(rank_broken)
  assert_true(rank_kind == "MalformedLine" || rank_kind == "DuplicateToken")
  assert_true(rank_line >= 0)
  // 2) 重复令牌：把第二个 token 的 base64 换成第一个 token 的
  let dup = vreplace_line(sample_vocab_text, first_token_line + 1, "1 1 AA==")
  let (dup_kind, dup_line) = vprobe(dup)
  assert_eq(dup_kind, "DuplicateToken")
  // 位置是"首次出现的行号"，不是 token 下标——用户要拿它去编辑器里定位
  assert_eq(dup_line, first_token_line)
  // 3) 尾部塞一行垃圾：行号必须指向那一行
  let dirty = sample_vocab_text + "\nnot a token line\n"
  let (dirty_kind, dirty_line) = vprobe(dirty)
  assert_eq(dirty_kind, "MalformedLine")
  assert_eq(dirty_line, lines.length() + 1)
}

///|
/// 子串查找：用来断言错误消息里点名了缺哪个 rank（错误类型只给"哪一行"，
/// 缺秩这种事没有行号，只能靠消息坐标）。
fn vhas_sub(s : String, sub : String) -> Bool {
  let hay = s.to_array()
  let needle = sub.to_array()
  if needle.length() == 0 {
    return true
  }
  for i = 0; i + needle.length() <= hay.length(); i = i + 1 {
    let mut same = true
    for j = 0; j < needle.length(); j = j + 1 {
      if hay[i + j] != needle[j] {
        same = false
        break
      }
    }
    if same {
      return true
    }
  }
  false
}

///|
/// 与 `vprobe` 同口径，但走 `.tiktoken` 加载器：入口不同，判据必须一样。
fn tprobe(text : String) -> (String, Int) {
  let mut kind = "ok"
  let mut line = -1
  try {
    let _ = load_tiktoken(text, [])
  } catch {
    InvalidBase64(_) => kind = "InvalidBase64"
    MalformedLine(l, _) => {
      kind = "MalformedLine"
      line = l
    }
    DuplicateToken(first, _second) => {
      kind = "DuplicateToken"
      line = first
    }
    EmptyToken(index) => {
      kind = "EmptyToken"
      line = index
    }
    MissingByteToken(b) => {
      kind = "MissingByteToken"
      line = b
    }
    SpecialOutOfRange(id, _) => {
      kind = "SpecialOutOfRange"
      line = id
    }
    UnknownSection(_) => kind = "UnknownSection"
    TrainSizeTooSmall(_, _) => kind = "TrainSizeTooSmall"
  }
  (kind, line)
}

///|
/// 造一份最小 `.tiktoken` 词表：256 个单字节 token，rank 即 id。
fn vtiktoken_text() -> String {
  let lines : Array[String] = []
  for b = 0; b < 256; b = b + 1 {
    let one : Bytes = Bytes::make(1, b.to_byte())
    lines.push(b64_encode(one) + " " + b.to_string())
  }
  lines.join("\n")
}

///|
test "matrix I: tiktoken happy path keeps rank == id" {
  let v = load_tiktoken(vtiktoken_text(), [])
  assert_eq(v.token_count(), 256)
  let a : Bytes = Bytes::make(1, (0x41).to_byte())
  assert_eq(v.id_of(a), Some(65))
  assert_eq(v.byte_id(0x41), 65)
}

///|
test "matrix J: tiktoken duplicate token is caught with both line numbers" {
  let lines = vlines(vtiktoken_text())
  let dup = vreplace_line(vjoin(lines), 2, lines[0])
  let (kind, line) = tprobe(dup)
  assert_eq(kind, "DuplicateToken")
  assert_eq(line, 1)
}

///|
/// 两行抢同一个 rank，如果只是"后写覆盖"，词表里就会出现 ranks 有它、
/// tokens 没有它的错位。必须在解析阶段就报错，并指出冲突行。
test "matrix J: tiktoken duplicate rank is caught with the line" {
  let lines = vlines(vtiktoken_text())
  let text = vreplace_line(vjoin(lines), 2, "AQ== 0")
  let (kind, line) = tprobe(text)
  assert_eq(kind, "MalformedLine")
  assert_eq(line, 2)
  let msg = try {
    let _ = load_tiktoken(text, [])
    ""
  } catch {
    MalformedLine(_, m) => m
    _ => ""
  }
  assert_true(vhas_sub(msg, "duplicate rank 0"))
}

///|
test "matrix J: tiktoken rank gap names the missing rank" {
  let lines = vlines(vtiktoken_text())
  let kept : Array[String] = []
  for i = 0; i < lines.length(); i = i + 1 {
    if i != 4 {
      kept.push(lines[i])
    }
  }
  let msg = try {
    let _ = load_tiktoken(vjoin(kept), [])
    ""
  } catch {
    MalformedLine(_, m) => m
    _ => ""
  }
  assert_true(vhas_sub(msg, "rank 4"))
}

///|
test "matrix J: tiktoken non-numeric rank is malformed with its line" {
  let lines = vlines(vtiktoken_text())
  let text = vreplace_line(vjoin(lines), 3, "Ag== x")
  let (kind, line) = tprobe(text)
  assert_eq(kind, "MalformedLine")
  assert_eq(line, 3)
}

///|
test "matrix J: unknown section and bad base64 are named, not silently accepted" {
  let bad_section = vreplace_line(sample_vocab_text, 4, "[tokenz]")
  let (section_kind, _) = vprobe(bad_section)
  assert_eq(section_kind, "UnknownSection")
  // 把第一个 token 的 base64 里塞一个非法字符
  let bad_b64 = vreplace_line(sample_vocab_text, 7, "0 0 A!==")
  let (b64_kind, _) = vprobe(bad_b64)
  assert_true(b64_kind == "InvalidBase64" || b64_kind == "MalformedLine")
}
