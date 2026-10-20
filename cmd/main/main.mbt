// tally CLI。
//
// 只做三件事：读文件、调库、打印。所有解析与编码都走库内实现，
// 保证 CLI 与库的行为不会分叉。IO 只出现在这里（核心包零 IO）。
//
// `fn main` 内不允许调用会抛错（raise）的函数，因此实际逻辑放在
// `run` 里，由 `main` 统一 `try/catch`。
//
// **退出码是契约**：成功 0，任何失败 1（`@sys.exit`）。0.6.0 以前只保证
// 文案清楚、进程仍返回 0，于是 `tally verify` 在 CI 里"总是成功"——
// 这不是一个能被人依赖的行为，0.6.1 起改掉。

///|
/// 严格解析非负整数：非法输入直接报错，不静默回落成 0
/// （否则 `--limit abc` 会悄悄变成默认的 4096）。
fn parse_i64(flag : String, s : String) -> Int64 raise {
  let chars = s.to_array()
  if chars.length() == 0 {
    raise Failure::Failure(flag + " expects a non-negative integer, got empty")
  }
  let mut v : Int64 = 0
  for c in chars {
    let d = c.to_int() - 0x30
    if d < 0 || d > 9 {
      raise Failure::Failure(
        flag + " expects a non-negative integer, got: \"" + s + "\"",
      )
    }
    v = v * 10L + d.to_int64()
  }
  v
}

///|
fn usage() -> Unit {
  println("tally — context budget engine for MoonBit: fit context into a token limit")
  println("")
  println("usage:")
  println(
    "  tally fit    --vocab <file> --limit <n> [--reserve <n>] [--truncate none|tail|head] [--file <f>]",
  )
  println("  tally count  --vocab <file> [--text <s> | --file <f>] [--explain]")
  println("  tally encode --vocab <file> [--text <s> | --file <f>]")
  println(
    "  tally digest --vocab <file> --limit <n> [--reserve <n>] [--truncate ...] [--file <f>]",
  )
  println(
    "  tally verify --report <f> --digest <f> [--seal <f> --key <s>|--key-file <f>] [--vocab <file> --limit <n> --file <f>]",
  )
  println(
    "  tally seal   --digest <f> (--key <s> | --key-file <f>) [--key-id <id>]",
  )
}

///|
/// 统一 exit：成功 0、失败 1。`run` 里所有错误都经这里变成进程退出码，
/// 这样 `tally verify` 在 CI 里失败就是失败，不必再 grep 输出。
fn main {
  let status = try {
    run(@env.args())
    0
  } catch {
    Failure::Failure(msg) => {
      println("error: " + msg)
      1
    }
    e => {
      println("error: " + e.to_string())
      1
    }
  }
  if status != 0 {
    @sys.exit(status)
  }
}

///|
fn run(args : Array[String]) -> Unit raise {
  let mut cmd = ""
  let mut vocab_path : String? = None
  let mut text : String? = None
  let mut file : String? = None
  let mut limit : Int64 = 0
  let mut reserve : Int64 = 0L
  let mut truncate_mode = "none"
  let mut explain = false
  let mut report_path : String? = None
  let mut digest_path : String? = None
  let mut seal_path : String? = None
  let mut key : String? = None
  let mut key_file : String? = None
  let mut key_id = ""
  let mut i = 0
  while i < args.length() {
    let a = args[i]
    let has_next = i + 1 < args.length()
    if a == "count" ||
      a == "encode" ||
      a == "fit" ||
      a == "digest" ||
      a == "verify" ||
      a == "seal" {
      cmd = a
      i = i + 1
    } else if a == "--report" && has_next {
      report_path = Some(args[i + 1])
      i = i + 2
    } else if a == "--digest" && has_next {
      digest_path = Some(args[i + 1])
      i = i + 2
    } else if a == "--seal" && has_next {
      seal_path = Some(args[i + 1])
      i = i + 2
    } else if a == "--key" && has_next {
      key = Some(args[i + 1])
      i = i + 2
    } else if a == "--key-file" && has_next {
      key_file = Some(args[i + 1])
      i = i + 2
    } else if a == "--key-id" && has_next {
      key_id = args[i + 1]
      i = i + 2
    } else if a == "--vocab" && has_next {
      vocab_path = Some(args[i + 1])
      i = i + 2
    } else if a == "--text" && has_next {
      text = Some(args[i + 1])
      i = i + 2
    } else if a == "--file" && has_next {
      file = Some(args[i + 1])
      i = i + 2
    } else if a == "--limit" && has_next {
      limit = parse_i64("--limit", args[i + 1])
      i = i + 2
    } else if a == "--reserve" && has_next {
      reserve = parse_i64("--reserve", args[i + 1])
      i = i + 2
    } else if a == "--truncate" && has_next {
      // 不认识的策略直接报错：静默回落成 none 会让「以为截了其实没截」。
      let mode = args[i + 1]
      if mode != "none" && mode != "tail" && mode != "head" {
        raise Failure::Failure(
          "--truncate expects none|tail|head, got: \"" + mode + "\"",
        )
      }
      truncate_mode = mode
      i = i + 2
    } else if a == "--explain" {
      explain = true
      i = i + 1
    } else if a == "--help" || a == "-h" {
      usage()
      return
    } else {
      i = i + 1
    }
  }
  if cmd == "" {
    usage()
    return
  }
  // 盖章：只对摘要文件盖，不重复生成摘要——"生成"与"认过"是两件事。
  if cmd == "seal" {
    let digest_file = match digest_path {
      Some(p) => p
      None => raise Failure::Failure("seal needs --digest <f>")
    }
    if !@fs.path_exists(digest_file) {
      raise Failure::Failure("digest file not found: " + digest_file)
    }
    let digest_text = @budget.normalize_newlines(@fs.read_file_to_string(digest_file))
    let k = resolve_key(key, key_file)
    match @tally.seal_digest(digest_text, k, key_id) {
      Ok(text) => println(chomp(text))
      Err(msg) => raise Failure::Failure(msg)
    }
    return
  }
  // 只给了密钥却没给印记：多半是以为"带了 key 就会验"，直接点破。
  match seal_path {
    Some(_) => ()
    None =>
      match (key, key_file) {
        (Some(_), _) =>
          raise Failure::Failure("--key / --key-file only make sense with --seal")
        (_, Some(_)) =>
          raise Failure::Failure("--key / --key-file only make sense with --seal")
        _ => ()
      }
  }
  // verify 的 vocab 是可选的：不带 vocab 时只做"报告与摘要自洽"，
  // 带上 vocab + 输入时才重跑一遍做"端到端复算"。
  if cmd == "verify" {
    let report_file = match report_path {
      Some(p) => p
      None => raise Failure::Failure("verify needs --report <f>")
    }
    let digest_file = match digest_path {
      Some(p) => p
      None => raise Failure::Failure("verify needs --digest <f>")
    }
    if !@fs.path_exists(report_file) {
      raise Failure::Failure("report file not found: " + report_file)
    }
    if !@fs.path_exists(digest_file) {
      raise Failure::Failure("digest file not found: " + digest_file)
    }
    let report = @budget.normalize_newlines(read_text_file(report_file))
    let digest_text = @budget.normalize_newlines(read_text_file(digest_file))
    match @budget.verify_report(report, digest_text) {
      Ok(_) => ()
      Err(msg) => raise Failure::Failure(msg)
    }
    // 印记：证明"这份摘要被某把密钥认过"，与"摘要和报告自洽"是两件事，分开报。
    match seal_path {
      Some(sp) => {
        if !@fs.path_exists(sp) {
          raise Failure::Failure("seal file not found: " + sp)
        }
        let seal_text = @budget.normalize_newlines(read_text_file(sp))
        let k = resolve_key(key, key_file)
        match @tally.verify_seal(digest_text, seal_text, k) {
          Ok(_) => ()
          Err(msg) => raise Failure::Failure(msg)
        }
      }
      None => ()
    }
    // 端到端复算：策略与输入都给齐时，重跑一遍必须逐字节还原报告与摘要。
    match (vocab_path, file) {
      (Some(vf), Some(input_file)) => {
        let vocab = @tally.load(read_text_file(vf))
        let plan = make_plan(
          vocab,
          @fs.read_file_to_bytes(input_file),
          limit,
          reserve,
          truncate_mode,
        )
        let rebuilt_report = plan.render()
        let rebuilt_digest = plan.render_digest()
        if rebuilt_report != report {
          raise Failure::Failure(
            "report does not match a fresh recomputation (first difference at line " +
            first_diff_line(rebuilt_report, report).to_string() +
            ")",
          )
        }
        if rebuilt_digest != digest_text {
          raise Failure::Failure(
            "digest does not match a fresh recomputation (first difference at line " +
            first_diff_line(rebuilt_digest, digest_text).to_string() +
            ")",
          )
        }
      }
      _ => ()
    }
    println("verify ok")
    return
  }
  let vocab_file = match vocab_path {
    Some(p) => p
    None => raise Failure::Failure("--vocab <file> is required")
  }
  if !@fs.path_exists(vocab_file) {
    raise Failure::Failure("vocab file not found: " + vocab_file)
  }
  let vocab = @tally.load(read_text_file(vocab_file))
  let input_bytes = match file {
    Some(f) => @fs.read_file_to_bytes(f)
    None =>
      match text {
        Some(t) => @utf8.encode(t)
        None => Bytes::new(0)
      }
  }
  match cmd {
    "count" =>
      if explain {
        let pieces = @tally.piece_counts(vocab, input_bytes)
        let mut total : Int64 = 0
        for e in pieces {
          let (p, n) = e
          total = total + n
          println("piece\t" + n.to_string() + "\t" + p)
        }
        println("total\t" + total.to_string())
      } else {
        println(@tally.count_bytes(vocab, input_bytes).to_string())
      }
    "encode" => {
      let ids = @tally.encode(vocab, input_bytes)
      let parts : Array[String] = []
      for id in ids {
        parts.push(id.to_string())
      }
      println(parts.join(" "))
    }
    // `render()` 已以 `\n` 结尾；`println` 会再补一个，打印前先去掉，落盘才是规范形。
    "fit" =>
      println(chomp(make_plan(vocab, input_bytes, limit, reserve, truncate_mode).render()))
    "digest" =>
      println(
        chomp(make_plan(vocab, input_bytes, limit, reserve, truncate_mode).render_digest()),
      )
    _ => usage()
  }
}

///|
/// CLI 的装配口径只有一处：fit / digest / verify 共用，避免三者各自维护一套参数
/// 而出现"报告和摘要不是同一份计划"的情况。
fn make_plan(
  vocab : @tally.Vocab,
  input_bytes : Bytes,
  limit : Int64,
  reserve : Int64,
  truncate_mode : String,
) -> @budget.Plan raise {
  let limit = if limit <= 0L { 4096L } else { limit }
  let strategy = match truncate_mode {
    "tail" => @tally.truncate_tail()
    "head" => @tally.truncate_head()
    _ => @tally.truncate_none()
  }
  // MVP：把输入整体视为一段 Newest 段，演示装配、截断与丢弃报告。
  let segments = [
    @budget.Segment::text("system", @budget.Pinned, "you are a helpful assistant."),
    @budget.Segment::new("payload", @budget.Newest, input_bytes),
  ]
  let cfg = @tally
    .fit_config(@tally.cl100k(vocab), limit + reserve)
    .with_reserve(reserve)
    .with_strategy(strategy)
  @tally.fit_with(cfg, segments)
}

///|
/// 报错时给人一个位置，而不是只说"对不上"。
fn first_diff_line(a : String, b : String) -> Int {
  let al = a.split("\n")
  let bl = b.split("\n").to_array()
  let mut n = 0
  let mut i = 0
  let mut done = false
  for x in al {
    if done {
      break
    }
    if i < bl.length() {
      let y = bl[i]
      if x != y {
        done = true
      } else {
        n = n + 1
      }
    }
    i = i + 1
  }
  n + 1
}

///|
/// 去掉结尾的一个换行（含 CRLF）。`render()` 自带结尾换行，而 `println` 还会补一个；
/// 不处理的话，文件里会多出一个空行，哈希就与内容对不上。
fn chomp(s : String) -> String {
  let chars = s.to_array()
  let mut n = chars.length()
  if n > 0 && chars[n - 1] == '\n' {
    n = n - 1
  }
  if n > 0 && chars[n - 1] == '\r' {
    n = n - 1
  }
  String::from_array(chars[0:n].to_owned())
}

///|
/// 读文本文件，并对 Windows 上最常见的坑给明确提示：PowerShell 5.1 的 `>` 默认写 UTF-16，
/// 那种文件读成 UTF-8 只会得到乱码行，报"头部不认识"等于没说。
fn read_text_file(path : String) -> String raise {
  let raw = @fs.read_file_to_bytes(path)
  if raw.length() >= 2 {
    let b0 = raw.unsafe_get(0).to_int() & 0xFF
    let b1 = raw.unsafe_get(1).to_int() & 0xFF
    if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF) {
      raise Failure::Failure(
        path +
        " looks like UTF-16 (BOM found); save it as UTF-8, e.g. `... | Out-File -Encoding utf8`",
      )
    }
  }
  @fs.read_file_to_string(path)
}

///|
/// 去掉结尾的所有换行：`echo` 与多数编辑器都会补一个，留着就会让密钥多一位。
fn trim_trailing_newlines(s : String) -> String {
  let chars = s.to_array()
  let mut n = chars.length()
  while n > 0 && (chars[n - 1] == '\n' || chars[n - 1] == '\r') {
    n = n - 1
  }
  if n == chars.length() {
    s
  } else {
    String::from_array(chars[0:n].to_owned())
  }
}

///|
/// 密钥来源：`--key` 直接给，或 `--key-file` 读文件。
/// 空密钥一律拒绝——空密钥等于人人可签，印记就失去意义。
fn resolve_key(key : String?, key_file : String?) -> String raise {
  match key {
    Some(k) =>
      if k == "" {
        raise Failure::Failure("--key must not be empty")
      } else {
        k
      }
    None =>
      match key_file {
        Some(f) => {
          if !@fs.path_exists(f) {
            raise Failure::Failure("key file not found: " + f)
          }
          let raw = trim_trailing_newlines(read_text_file(f))
          if raw == "" {
            raise Failure::Failure("key file is empty: " + f)
          }
          raw
        }
        None => raise Failure::Failure("--key <s> or --key-file <f> is required")
      }
  }
}
