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
  println("tally — a verifiable context-assembly contract for MoonBit: fit context into a token limit")
  println("")
  println("usage:")
  println(
    "  tally fit    --vocab <file> --limit <n> [--reserve <n>] [--truncate none|tail|head|compress] [--file <f>|--text <s>]",
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
  println("")
  println("segments and pools (1.0；均可重复，digest / verify 的复算同样接受):")
  println(
    "  --segment <role>:<priority>:<path>    priority = pinned|newest|middle|oldest",
  )
  println(
    "                                        给了 --segment 就不再造默认的 system+payload 两段",
  )
  println(
    "  --pool <name>=<limit>                 池配额；借用顺序 = 声明顺序",
  )
  println(
    "  --segment-pool <role>=<name>          把该 role 的所有段归入某个池",
  )
  println(
    "  --segment-score <role>=<n>            同优先级内的取舍分数（越大越优先保留）",
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
  // 段与池：`--segment <role>:<priority>:<path>`，池与分数按 role 挂上去。
  let pool_decls : Array[(String, Int64)] = []
  let segment_specs : Array[(String, String, String)] = []
  let segment_pools : Array[(String, String)] = []
  let segment_scores : Array[(String, Int64)] = []
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
      if mode != "none" && mode != "tail" && mode != "head" && mode != "compress" {
        raise Failure::Failure(
          "--truncate expects none|tail|head|compress, got: \"" + mode + "\"",
        )
      }
      truncate_mode = mode
      i = i + 2
    } else if a == "--pool" && has_next {
      let (name, raw) = split_pair("--pool", args[i + 1], '=', "<name>=<limit>")
      check_token("--pool name", name)
      pool_decls.push((name, parse_i64("--pool", raw)))
      i = i + 2
    } else if a == "--segment" && has_next {
      // 只切前两个冒号：`role` / `priority` 不含冒号，其余全部算路径
      // （Windows 盘符与 URL 里的冒号因此不会被吃掉）。
      let (role, rest) = split_pair(
        "--segment",
        args[i + 1],
        ':',
        "<role>:<priority>:<path>",
      )
      let (prio, path) = split_pair(
        "--segment",
        rest,
        ':',
        "<role>:<priority>:<path>",
      )
      check_token("--segment role", role)
      // 先校验优先级名，避免拼错时静默用默认值。
      let _ = priority_of(prio)
      if path == "" {
        raise Failure::Failure("--segment expects <role>:<priority>:<path>, got empty path")
      }
      segment_specs.push((role, prio, path))
      i = i + 2
    } else if a == "--segment-pool" && has_next {
      let (role, name) = split_pair(
        "--segment-pool",
        args[i + 1],
        '=',
        "<role>=<pool>",
      )
      check_token("--segment-pool pool name", name)
      segment_pools.push((role, name))
      i = i + 2
    } else if a == "--segment-score" && has_next {
      let (role, raw) = split_pair(
        "--segment-score",
        args[i + 1],
        '=',
        "<role>=<score>",
      )
      segment_scores.push((role, parse_i64("--segment-score", raw)))
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
    // 「输入」可以是 `--file` / `--text`，也可以是 `--segment` 列出的段文件。
    let input_bytes = match file {
      Some(f) => Some(@fs.read_file_to_bytes(f))
      None =>
        match text {
          Some(t) => Some(@utf8.encode(t))
          // 只用 `--segment` 时没有单段输入；给空字节占位，默认段不会因此被造出来。
          None => if segment_specs.length() > 0 { Some(Bytes::new(0)) } else { None }
        }
    }
    match (vocab_path, input_bytes) {
      (Some(vf), Some(bytes)) => {
        let vocab = @tally.load(read_text_file(vf))
        let plan = make_plan(
          vocab,
          build_segments(
            segment_specs,
            bytes,
            segment_pools,
            segment_scores,
            pool_decls,
          ),
          limit,
          reserve,
          truncate_mode,
          pool_decls,
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
      println(
        chomp(
          make_plan(
            vocab,
            build_segments(
              segment_specs,
              input_bytes,
              segment_pools,
              segment_scores,
              pool_decls,
            ),
            limit,
            reserve,
            truncate_mode,
            pool_decls,
          ).render(),
        ),
      )
    "digest" =>
      println(
        chomp(
          make_plan(
            vocab,
            build_segments(
              segment_specs,
              input_bytes,
              segment_pools,
              segment_scores,
              pool_decls,
            ),
            limit,
            reserve,
            truncate_mode,
            pool_decls,
          ).render_digest(),
        ),
      )
    _ => usage()
  }
}

///|
/// 段的装配口径只有一处：`--segment` 给定时用它，否则仍是
/// `system`（Pinned）+ `payload`（Newest，来自 `--text` / `--file`）两段。
///
/// 池与分数按 **role** 挂到段上：`--segment-pool history=turns` 会把所有
/// `role == "history"` 的段归入 `turns` 池（多轮历史里角色本来就重复）。
/// role 拼错时直接报错，而不是静默地"没生效"。
fn build_segments(
  specs : Array[(String, String, String)],
  input_bytes : Bytes,
  seg_pools : Array[(String, String)],
  seg_scores : Array[(String, Int64)],
  declared_pools : Array[(String, Int64)],
) -> Array[@budget.Segment] raise {
  let segments : Array[@budget.Segment] = []
  if specs.length() == 0 {
    segments.push(
      @budget.Segment::text("system", @budget.Pinned, "you are a helpful assistant."),
    )
    segments.push(@budget.Segment::new("payload", @budget.Newest, input_bytes))
  } else {
    for spec in specs {
      let (role, prio, path) = spec
      if !@fs.path_exists(path) {
        raise Failure::Failure("segment file not found: " + path)
      }
      segments.push(
        @budget.Segment::new(role, priority_of(prio), @fs.read_file_to_bytes(path)),
      )
    }
  }
  for entry in seg_pools {
    let (role, name) = entry
    // 归入一个没声明配额的池等于什么也没做；这种"静默不生效"必须先点破。
    if !has_pool(declared_pools, name) {
      raise Failure::Failure(
        "--segment-pool: pool \"" +
        name +
        "\" is not declared; add --pool " +
        name +
        "=<limit>",
      )
    }
    let hits = assign_pool(segments, role, name)
    if hits == 0 {
      raise Failure::Failure(
        "--segment-pool: no segment with role \"" + role + "\"",
      )
    }
  }
  for entry in seg_scores {
    let (role, score) = entry
    let hits = assign_score(segments, role, score)
    if hits == 0 {
      raise Failure::Failure(
        "--segment-score: no segment with role \"" + role + "\"",
      )
    }
  }
  segments
}

///|
fn has_pool(declared : Array[(String, Int64)], name : String) -> Bool {
  for entry in declared {
    let (n, _) = entry
    if n == name {
      return true
    }
  }
  false
}

///|
fn assign_pool(
  segments : Array[@budget.Segment],
  role : String,
  name : String,
) -> Int {
  let mut hits = 0
  for i = 0; i < segments.length(); i = i + 1 {
    if segments[i].role == role {
      segments[i] = segments[i].with_pool(name)
      hits = hits + 1
    }
  }
  hits
}

///|
fn assign_score(
  segments : Array[@budget.Segment],
  role : String,
  score : Int64,
) -> Int {
  let mut hits = 0
  for i = 0; i < segments.length(); i = i + 1 {
    if segments[i].role == role {
      segments[i] = segments[i].with_score(score)
      hits = hits + 1
    }
  }
  hits
}

///|
/// CLI 的装配口径只有一处：fit / digest / verify 共用，避免三者各自维护一套参数
/// 而出现"报告和摘要不是同一份计划"的情况。
fn make_plan(
  vocab : @tally.Vocab,
  segments : Array[@budget.Segment],
  limit : Int64,
  reserve : Int64,
  truncate_mode : String,
  pools : Array[(String, Int64)],
) -> @budget.Plan raise {
  let limit = if limit <= 0L { 4096L } else { limit }
  let strategy = match truncate_mode {
    "tail" => @tally.truncate_tail()
    "head" => @tally.truncate_head()
    "compress" => @tally.truncate_compress()
    _ => @tally.truncate_none()
  }
  let mut cfg = @tally
    .fit_config(@tally.cl100k(vocab), limit + reserve)
    .with_reserve(reserve)
    .with_strategy(strategy)
  if pools.length() > 0 {
    cfg = @tally.fit_config_pools(cfg, pools)
  }
  @tally.fit_with(cfg, segments)
}

///|
/// 在**第一个** `sep` 处拆成两半（右侧原样保留，所以路径里的冒号不会被吃掉）；
/// 没有分隔符或左边为空就报错，错误文案里写清期望形状。
fn split_pair(
  flag : String,
  s : String,
  sep : Char,
  shape : String,
) -> (String, String) raise {
  let chars = s.to_array()
  let n = chars.length()
  let mut at = -1
  for i = 0; i < n; i = i + 1 {
    if chars[i] == sep {
      at = i
      break
    }
  }
  if at < 0 {
    raise Failure::Failure(flag + " expects " + shape + ", got: \"" + s + "\"")
  }
  let left = String::from_array(chars[0:at].to_owned())
  let right = String::from_array(chars[at + 1:n].to_owned())
  if left == "" {
    raise Failure::Failure(
      flag + " expects " + shape + ", got empty left side: \"" + s + "\"",
    )
  }
  (left, right)
}

///|
/// 会直接进报告的词（role / 池名）不得含空白：报告按空格切列。
fn check_token(flag : String, s : String) -> Unit raise {
  if s == "" {
    raise Failure::Failure(flag + " must not be empty")
  }
  for c in s.to_array() {
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      raise Failure::Failure(
        flag + " must not contain whitespace (it goes into the report verbatim): \"" +
        s +
        "\"",
      )
    }
  }
}

///|
fn priority_of(name : String) -> @budget.Priority raise {
  match name {
    "pinned" => @budget.Pinned
    "newest" => @budget.Newest
    "middle" => @budget.Middle
    "oldest" => @budget.Oldest
    _ =>
      raise Failure::Failure(
        "--segment priority expects pinned|newest|middle|oldest, got: \"" + name + "\"",
      )
  }
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
