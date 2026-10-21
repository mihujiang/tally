// 装配、截断与丢弃报告。
//
// 不变量：
//   V13 `Plan::tokens_used <= limit`，除非 `overflow` 被显式置真并给出原因。
//   V14 `Pinned` 段永远完整出现在结果里；装不下时要给出可操作的建议。
//   V15 `Plan::render` 的输出是规范文本（稳定、可冻结、可 diff、无 Map 迭代序）。
//   V16 报告里的计数器身份（`name` + `exact`）与实际计数来源一致，估算必须自曝。

///|
/// 被完整保留的一段。
pub(all) struct KeptSegment {
  index : Int
  role : String
  priority : Priority
  tokens : Int64
  bytes : Bytes
} derive(Debug)

///|
/// 被截短的一段：只保留一部分字节，`tokens` 是**实际装入**的量。
pub(all) struct TruncatedSegment {
  index : Int
  role : String
  priority : Priority
  original_tokens : Int64
  tokens : Int64
  strategy : TruncateStrategy
  bytes : Bytes
} derive(Debug)

///|
/// 被整段丢弃的一段，带**原因**（这是本层相对同类工具的核心增量）。
pub(all) struct DroppedSegment {
  index : Int
  role : String
  priority : Priority
  tokens : Int64
  reason : String
} derive(Debug)

///|
/// 装配计划。`tokens_used` 是**已装入窗口**的 token 数；
/// 被丢弃的段不计入，被截断的段只计装入的部分。
///
/// `overflow` 为真时 `tokens_used > limit`，超出量在 `excess`；此时 `dropped`
/// 末尾还有一行**哨兵**（`index = -1`、`role = "*overflow*"`），它的 `tokens`
/// 是超出量而不是某个段的原量——按段对账时要跳过它。
pub(all) struct Plan {
  /// 计数器身份（如 `cl100k_base` / `estimate@4`）
  counter : String
  /// 计数是否精确
  exact : Bool
  /// 窗口总大小
  window : Int64
  /// 留给模型回复的预留
  reserve : Int64
  /// 输入可用预算 `window - reserve`
  limit : Int64
  tokens_used : Int64
  pinned_tokens : Int64
  overflow : Bool
  /// 溢出量 `tokens_used - limit`（不溢出时为 0）
  excess : Int64
  kept : Array[KeptSegment]
  truncated : Array[TruncatedSegment]
  dropped : Array[DroppedSegment]
} derive(Debug)

///|
/// 按配置装配上下文。
///
/// 超出预算时的顺序完全确定：先动权重最小的段；权重相同时动**原始下标较小**的
/// （更早的历史）。策略为 `NoTruncate` 时整段丢弃；否则先尝试把该段截短到刚好够用，
/// 截不动（或目标为 0）时才整段丢。
pub fn fit_with(cfg : FitConfig, segments : Array[Segment]) -> Plan raise FitError {
  if cfg.reserve_output >= cfg.window {
    raise ReserveExceedsWindow(cfg.reserve_output, cfg.window)
  }
  assemble(cfg, segments)
}

///|
/// 装配但**不校验配置**：`reserve >= window`（甚至 `window <= 0`）时按实际预算如实记账。
///
/// 给 0.3 兼容入口 `tally.fit` 用——它必须保持旧语义：预算为 0 时全部丢弃、
/// Pinned 溢出上报，而不是抛错。普通调用请走 `fit_with`。
pub fn assemble(cfg : FitConfig, segments : Array[Segment]) -> Plan {
  let limit = cfg.input_limit()
  let counter = cfg.counter
  let n = segments.length()
  let counts : Array[Int64] = []
  let original : Array[Int64] = []
  let pieces : Array[Bytes] = []
  let dropped_flags : Array[Bool] = []
  let truncated_flags : Array[Bool] = []
  let mut total : Int64 = 0
  let mut pinned_tokens : Int64 = 0
  for i = 0; i < n; i = i + 1 {
    let c = counter.count(segments[i].bytes)
    counts.push(c)
    original.push(c)
    pieces.push(segments[i].bytes)
    dropped_flags.push(false)
    truncated_flags.push(false)
    total = total + c
    if segments[i].priority == Pinned {
      pinned_tokens = pinned_tokens + c
    }
  }
  let mut overflow = false
  while total > limit {
    let deficit = total - limit
    // 选受害者：非 Pinned 中权重最小者；并列时取下标最小者。
    let mut victim = -1
    let mut victim_w = 4
    for i = 0; i < n; i = i + 1 {
      if !dropped_flags[i] && segments[i].priority != Pinned {
        let w = segments[i].priority.weight()
        if w < victim_w {
          victim_w = w
          victim = i
        }
      }
    }
    if victim < 0 {
      // 只剩 Pinned 还装不下：明确上报，而不是悄悄超限。
      overflow = true
      break
    }
    let c = counts[victim]
    if cfg.strategy != NoTruncate && c > deficit {
      // 截到「刚好补上缺口」的量，再用计数器回读实际装下的 token 数。
      let target = c - deficit
      let (cut_bytes, cut_count) = cut_to(
        counter,
        pieces[victim],
        target,
        cfg.strategy == KeepSuffix,
      )
      // `cut_count == 0` 时等价于整段丢，但「丢掉」的解释力更强，故不记为截断。
      if cut_count < c && cut_count > 0L {
        pieces[victim] = cut_bytes
        counts[victim] = cut_count
        total = total - c + cut_count
        truncated_flags[victim] = true
        continue
      }
      // 一个 token 都截不下来：退化为整段丢。
    }
    dropped_flags[victim] = true
    total = total - c
  }
  let kept : Array[KeptSegment] = []
  let truncated : Array[TruncatedSegment] = []
  let dropped : Array[DroppedSegment] = []
  for i = 0; i < n; i = i + 1 {
    let s = segments[i]
    if dropped_flags[i] {
      dropped.push({
        index: i,
        role: s.role,
        priority: s.priority,
        tokens: original[i],
        reason: drop_reason(s.priority),
      })
    } else if truncated_flags[i] {
      truncated.push({
        index: i,
        role: s.role,
        priority: s.priority,
        original_tokens: original[i],
        tokens: counts[i],
        strategy: cfg.strategy,
        bytes: pieces[i],
      })
    } else {
      kept.push({
        index: i,
        role: s.role,
        priority: s.priority,
        tokens: counts[i],
        bytes: pieces[i],
      })
    }
  }
  if overflow {
    dropped.push({
      index: -1,
      role: "*overflow*",
      priority: Pinned,
      tokens: pinned_tokens - limit,
      reason: "Pinned 段本身超过 limit；请增大窗口或缩短 system 提示/工具定义",
    })
  }
  {
    counter: counter.name,
    exact: counter.exact,
    window: cfg.window,
    reserve: cfg.reserve_output,
    limit,
    tokens_used: total,
    pinned_tokens,
    overflow,
    excess: if overflow { total - limit } else { 0L },
    kept,
    truncated,
    dropped,
  }
}

///|
fn drop_reason(p : Priority) -> String {
  match p {
    Pinned => "不可丢但已溢出（不应发生）"
    Newest => "为满足预算而丢弃（最后才牺牲）"
    Middle => "为满足预算而丢弃（优先级低于 Newest）"
    Oldest => "为满足预算而丢弃（最早的历史，最先牺牲）"
  }
}

///|
/// 取 `bytes[from, to)` 的副本（`Bytes` 无 `op_set`，经 `Array[Byte]` 中转）。
fn slice_bytes(bytes : Bytes, from : Int, to : Int) -> Bytes {
  let out : Array[Byte] = Array::make(to - from, (0).to_byte())
  for i = 0; i < to - from; i = i + 1 {
    out[i] = bytes.unsafe_get(from + i)
  }
  Bytes::from_array(out)
}

///|
/// 该字节是否是一个 UTF-8 字符的起始字节（非 `10xxxxxx` 续字节）。
fn is_char_start(b : Byte) -> Bool {
  (b.to_int() & 0xC0) != 0x80
}

///|
/// 在 `bytes` 里取出「token 数不超过 `target`」的最大前缀（或后缀）切片。
///
/// 只依赖 `Counter`，因此对任意计数器（含外部 tokenizer）都成立。
/// 两处诚实说明：
/// * BPE 的 token 数对长度**不严格单调**（追加字节可能触发合并），二分只保证
///   「找到的切片不超预算」，不保证是理论最长的那个；
/// * 切点会回退到 UTF-8 字符边界，避免把半个字符送给下游。
fn cut_to(
  counter : Counter,
  bytes : Bytes,
  target : Int64,
  suffix : Bool,
) -> (Bytes, Int64) {
  let n = bytes.length()
  if n == 0 || target <= 0L {
    return (slice_bytes(bytes, 0, 0), 0L)
  }
  let mut lo = 0
  let mut hi = n
  // 记住 lo 对应的计数：若最后没有因 UTF-8 边界回退，`kept` 就是二分里
  // 已经数过的那段，不必再数一遍（长段上省掉一次完整编码）。
  let mut lo_count = 0L
  while lo < hi {
    let mid = (lo + hi + 1) / 2
    let probe = if suffix {
      slice_bytes(bytes, n - mid, n)
    } else {
      slice_bytes(bytes, 0, mid)
    }
    let c = counter.count(probe)
    if c <= target {
      lo = mid
      lo_count = c
    } else {
      hi = mid - 1
    }
  }
  let mut len = lo
  while len > 0 {
    let cut = if suffix { n - len } else { len }
    if cut >= n || is_char_start(bytes.unsafe_get(cut)) {
      break
    }
    len = len - 1
  }
  let kept = if suffix {
    slice_bytes(bytes, n - len, n)
  } else {
    slice_bytes(bytes, 0, len)
  }
  let kept_count = if len == lo { lo_count } else { counter.count(kept) }
  (kept, kept_count)
}
