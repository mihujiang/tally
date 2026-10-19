// tally CLI。
//
// 只做三件事：读文件、调库、打印。所有解析与编码都走库内实现，
// 保证 CLI 与库的行为不会分叉。IO 只出现在这里（核心包零 IO）。
//
// `fn main` 内不允许调用会抛错（raise）的函数，因此实际逻辑放在
// `run` 里，由 `main` 统一 `try/catch`。

///|
fn parse_i64(s : String) -> Int64 {
  let chars = s.to_array()
  let mut v : Int64 = 0
  for c in chars {
    let d = c.to_int() - 0x30
    if d >= 0 && d <= 9 {
      v = v * 10L + d.to_int64()
    }
  }
  v
}

///|
fn usage() -> Unit {
  println("tally — context budget engine for MoonBit: fit context into a token limit")
  println("")
  println("usage:")
  println("  tally fit    --vocab <file> --limit <n> [--reserve <n>] [--truncate none|tail|head] [--file <f>]")
  println("  tally count  --vocab <file> [--text <s> | --file <f>] [--explain]")
  println("  tally encode --vocab <file> [--text <s> | --file <f>]")
}

///|
fn main {
  try {
    run(@env.args())
  } catch {
    e => println("error: " + e.to_string())
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
  let mut i = 0
  while i < args.length() {
    let a = args[i]
    let has_next = i + 1 < args.length()
    if a == "count" || a == "encode" || a == "fit" {
      cmd = a
      i = i + 1
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
      limit = parse_i64(args[i + 1])
      i = i + 2
    } else if a == "--reserve" && has_next {
      reserve = parse_i64(args[i + 1])
      i = i + 2
    } else if a == "--truncate" && has_next {
      truncate_mode = args[i + 1]
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
  let vocab_file = match vocab_path {
    Some(p) => p
    None => raise Failure::Failure("--vocab <file> is required")
  }
  if !@fs.path_exists(vocab_file) {
    raise Failure::Failure("vocab file not found: " + vocab_file)
  }
  let vocab = @tally.load(@fs.read_file_to_string(vocab_file))
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
    "fit" => {
      let limit = if limit <= 0L { 4096L } else { limit }
      let strategy = match truncate_mode {
        "tail" => @tally.truncate_tail()
        "head" => @tally.truncate_head()
        _ => @tally.truncate_none()
      }
      // MVP：把输入整体视为一段 Newest 段，演示装配、截断与丢弃报告。
      let segments = [
        @budget.Segment::text(
          "system",
          @budget.Pinned,
          "you are a helpful assistant.",
        ),
        @budget.Segment::new("payload", @budget.Newest, input_bytes),
      ]
      let cfg = @tally
        .fit_config(@tally.cl100k(vocab), limit + reserve)
        .with_reserve(reserve)
        .with_strategy(strategy)
      println(@tally.fit_with(cfg, segments).render())
    }
    _ => usage()
  }
}
