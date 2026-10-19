// tally 示例：四个可以直接运行、输出可逐字节比对的最小场景。
//
// 在仓库根目录运行：
//   moon run cmd/examples --target js -- all
//   moon run cmd/examples --target js -- big-input
//   moon run cmd/examples --target js -- big-input --vocab data/cl100k_base.tiktoken
//
// 默认读仓库夹具词表 `tests/golden/sample-vocab.txt`（277 token）。
// 换成真实词表只需换 `--vocab`：`.tiktoken` 文件走 `load_tiktoken`，
// `tally-vocab v1` 文本走 `load`（`python tools/fetch_vocab.py` 可下载 cl100k_base）。
//
// 为什么示例带 IO：读词表要文件系统。IO 只出现在 `cmd/` 下的工具包，核心包仍然零 IO。

///|
fn load_vocab(path : String) -> @tally.Vocab raise {
  let text = @fs.read_file_to_string(path)
  try {
    @tally.load(text)
  } catch {
    _ => @tally.load_tiktoken(text, [])
  }
}

///|
fn repeat_unit(unit : String, times : Int) -> String {
  let parts : Array[String] = []
  for i = 0; i < times; i = i + 1 {
    parts.push(unit)
  }
  parts.join("")
}

///|
/// 示例 01：十万 token 级的日志装进 8192 窗口。
///
/// 留 1024 给回复，输入预算 7168；超预算的日志段**保留段尾**（最近的日志），
/// 而不是从中间硬切——切点由 `Counter` 二分得到并回退到 UTF-8 边界。
fn demo_big_input(v : @tally.Vocab) -> Unit raise {
  let unit = "INFO request id=1234 path=/api/chat status=200 latency=42ms\n"
  let unit_tokens = @tally.count(v, unit)
  let times = ((100_000L + unit_tokens - 1L) / unit_tokens).to_int()
  let log_text = repeat_unit(unit, times)
  let log_tokens = @tally.count(v, log_text)
  let segments = [
    @tally.pinned("system", "you are a log triage assistant. keep answers short."),
    @tally.oldest("old-log", log_text),
    @tally.newest("user", "which request was slowest, and why?"),
  ]
  let cfg = @tally
    .fit_config(@tally.cl100k(v), 8192L)
    .with_reserve(1024L)
    .with_strategy(@tally.truncate_head())
  println("== 01 big-input: ~100k token log -> 8192 window, 1024 reserved")
  println("log_lines " + times.to_string() + " log_tokens " + log_tokens.to_string())
  println(@tally.fit_with(cfg, segments).render())
}

///|
/// 示例 02：多轮历史。
///
/// system 提示是 `Pinned`（永不裁）；12 轮历史按时间分成 oldest / middle / newest，
/// 预算不够时先动最早的几轮，最近几轮最后才牺牲。
fn demo_multi_turn(v : @tally.Vocab) -> Unit raise {
  let turns : Array[String] = [
    "user: what does the deploy pipeline do?",
    "assistant: it builds, tests, and publishes the module.",
    "user: how long does a full run take?",
    "assistant: about six minutes on the shared runner.",
    "user: can we skip the publish step in pull requests?",
    "assistant: yes, the workflow only publishes on tags.",
    "user: where are the golden files stored?",
    "assistant: under tests/golden, checked by the format lock script.",
    "user: what happens when a report format changes?",
    "assistant: the lock script fails before the change can land.",
    "user: does the budget engine drop or truncate first?",
    "assistant: it drops whole segments unless a strategy is configured.",
  ]
  let segments : Array[@tally.Segment] = [
    @tally.pinned("system", "you are a helpful assistant. cite sources when you can."),
  ]
  for i = 0; i < turns.length(); i = i + 1 {
    let segment = if i < 4 {
      @tally.oldest("history", turns[i])
    } else if i < 9 {
      @tally.middle("history", turns[i])
    } else {
      @tally.newest("history", turns[i])
    }
    segments.push(segment)
  }
  let cfg = @tally.fit_config(@tally.cl100k(v), 360L).with_reserve(40L)
  let plan = @tally.fit_with(cfg, segments)
  let mut pinned_kept = false
  for k in plan.kept {
    if k.role == "system" {
      pinned_kept = true
    }
  }
  println("== 02 multi-turn: 12 turns, pinned system, 360 window / 40 reserved")
  println(
    "pinned_kept " +
    pinned_kept.to_string() +
    " dropped " +
    plan.dropped.length().to_string(),
  )
  println(plan.render())
}

///|
/// 示例 03：RAG 片段拼装。
///
/// 检索分数直接映射成 `Priority`：高分片段最后牺牲，低分片段最先丢。
/// 这里用默认策略（整段丢）——检索片段切一半通常比丢掉更糟。
fn demo_rag(v : @tally.Vocab) -> Unit raise {
  let chunks : Array[(String, Int)] = [
    ("Deploys are triggered by pushing a git tag that matches v*.*.*.", 95),
    ("The publish job validates the package with moon check before upload.", 88),
    ("Golden files are compared byte for byte by the lock script.", 81),
    ("A budget plan lists kept, truncated, and dropped segments.", 64),
    ("Truncation falls back to UTF-8 character boundaries.", 52),
    ("Estimates are always marked exact=false in the report.", 31),
  ]
  let segments : Array[@tally.Segment] = [
    @tally.pinned("system", "answer using only the provided context."),
  ]
  for entry in chunks {
    let (text, score) = entry
    let segment = if score >= 85 {
      @tally.newest("chunk", text)
    } else if score >= 60 {
      @tally.middle("chunk", text)
    } else {
      @tally.oldest("chunk", text)
    }
    segments.push(segment)
  }
  segments.push(@tally.newest("question", "when does the publish job run?"))
  let cfg = @tally.fit_config(@tally.cl100k(v), 260L).with_reserve(20L)
  let plan = @tally.fit_with(cfg, segments)
  println("== 03 rag: 6 chunks + question, 260 window / 20 reserved")
  println(
    "chunks " +
    chunks.length().to_string() +
    " kept " +
    plan.kept.length().to_string() +
    " dropped " +
    plan.dropped.length().to_string(),
  )
  println(plan.render())
}

///|
/// 外部计数器：按空白切词（演示「不需要我们的词表也能计数与截断」）。
fn count_words(bytes : Bytes) -> Int64 {
  let mut n = 0L
  let mut in_word = false
  for i = 0; i < bytes.length(); i = i + 1 {
    let b = bytes.unsafe_get(i).to_int()
    let is_space = b == 0x20 || b == 0x0A || b == 0x09
    if is_space {
      in_word = false
    } else if !in_word {
      in_word = true
      n = n + 1L
    }
  }
  n
}

///|
/// 示例 04：把外部 tokenizer 包成 `Counter`。
///
/// `Counter` 只有 `name` / `exact` / `count_bytes` 三项：外部类型不必写 `impl`，
/// 也不必把它的依赖拖进核心包。截断同样走这个 `Counter`，所以外部词表也能被裁。
fn demo_foreign_counter() -> Unit raise {
  let word_counter : @tally.Counter = {
    name: "space-words",
    exact: false,
    count_bytes: fn(bytes) { count_words(bytes) },
  }
  let segments = [
    @tally.pinned("system", "answer in one sentence."),
    @tally.oldest(
      "doc",
      "the quick brown fox jumps over the lazy dog while the diligent beaver builds a dam near the river bank and the patient heron waits for a fish to swim past",
    ),
    @tally.newest("question", "what is the fox doing?"),
  ]
  let cfg = @tally
    .fit_config(word_counter, 24L)
    .with_reserve(4L)
    .with_strategy(@tally.truncate_tail())
  let plan = @tally.fit_with(cfg, segments)
  println("== 04 foreign-counter: external tokenizer as Counter, 24 window / 4 reserved")
  println("counter " + plan.counter + " exact " + plan.exact.to_string())
  println(plan.render())
}

///|
fn usage() -> Unit {
  println("tally examples:")
  println("  moon run cmd/examples --target js -- all")
  println("  moon run cmd/examples --target js -- big-input|multi-turn|rag|foreign-counter")
  println("  [--vocab <file>]  默认 tests/golden/sample-vocab.txt")
}

///|
fn run(args : Array[String]) -> Unit raise {
  let mut case = "all"
  let mut vocab_path = "tests/golden/sample-vocab.txt"
  let mut i = 1
  while i < args.length() {
    let a = args[i]
    if a == "--vocab" && i + 1 < args.length() {
      vocab_path = args[i + 1]
      i = i + 2
    } else if a == "--help" || a == "-h" {
      usage()
      return
    } else {
      case = a
      i = i + 1
    }
  }
  let v = load_vocab(vocab_path)
  match case {
    "big-input" => demo_big_input(v)
    "multi-turn" => demo_multi_turn(v)
    "rag" => demo_rag(v)
    "foreign-counter" => demo_foreign_counter()
    "all" => {
      demo_big_input(v)
      demo_multi_turn(v)
      demo_rag(v)
      demo_foreign_counter()
    }
    _ => raise Failure::Failure("unknown example: " + case)
  }
}

///|
fn main {
  try {
    run(@env.args())
  } catch {
    e => println("error: " + e.to_string())
  }
}
