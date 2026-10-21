// 装配、截断与丢弃报告。
//
// 不变量：
//   V13 `Plan::tokens_used <= limit`，除非 `overflow` 被显式置真并给出原因。
//   V14 `Pinned` 段永远完整出现在结果里；装不下时要给出可操作的建议。
//   V15 `Plan::render` 的输出是规范文本（稳定、可冻结、可 diff、无 Map 迭代序）。
//   V16 报告里的计数器身份（`name` + `exact`）与实际计数来源一致，估算必须自曝。
//   V17 池配额的取用、借用、借出逐池记账；借用顺序 = `FitConfig::pools` 的声明顺序。

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
  /// 被省略的量（`original - tokens`）；`Compress` 时同时也写在占位标记里。
  omitted : Int64
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
/// 一个配额池的台账。只有 `FitConfig::pools` 里声明过的池才会出现。
///
/// `demand` 是该池全部段的原始量，`used` 是最终装入量；`borrowed` / `lent`
/// 是与其他池之间的借用流水。`Pinned` 段不可裁，所以 `used` 允许大于
/// `quota`（配额只约束可裁段），报告如实呈现。
pub(all) struct PoolUsage {
  name : String
  quota : Int64
  demand : Int64
  used : Int64
  borrowed : Int64
  lent : Int64
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
  /// 池台账（按 `FitConfig::pools` 声明顺序；未配置池时为空）
  pools : Array[PoolUsage]
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
  // 截断段被省略的**原文**量（`Compress` 的标记里写的就是这个数）
  let omitted_amounts : Array[Int64] = []
  let pieces : Array[Bytes] = []
  let dropped_flags : Array[Bool] = []
  // 是否由「池配额」这一轮裁掉（决定报告里给出的原因）
  let dropped_by_pool : Array[Bool] = []
  let truncated_flags : Array[Bool] = []
  // 段 → 声明池下标（-1 = 未声明，不参与配额）
  let pool_idx : Array[Int] = []
  let mut total : Int64 = 0
  let mut pinned_tokens : Int64 = 0
  for i = 0; i < n; i = i + 1 {
    let s = segments[i]
    let c = counter.count(s.bytes)
    counts.push(c)
    original.push(c)
    omitted_amounts.push(0L)
    pieces.push(s.bytes)
    dropped_flags.push(false)
    dropped_by_pool.push(false)
    truncated_flags.push(false)
    pool_idx.push(pool_index_of(cfg.pools, s.pool))
    total = total + c
    if s.priority == Pinned {
      pinned_tokens = pinned_tokens + c
    }
  }
  let mut overflow = false
  // 第一轮：全局预算。
  while total > limit {
    let deficit = total - limit
    let victim = pick_victim(segments, dropped_flags, -1, pool_idx)
    if victim < 0 {
      // 只剩 Pinned 还装不下：明确上报，而不是悄悄超限。
      overflow = true
      break
    }
    let c = counts[victim]
    if cfg.strategy != NoTruncate && c > deficit {
      // 截到「刚好补上缺口」的量，再用计数器回读实际装下的 token 数。
      let (new_bytes, new_count, new_omitted) = shrink(
        counter,
        cfg.strategy,
        pieces[victim],
        c - deficit,
      )
      // `new_count == 0` 时等价于整段丢，但「丢掉」的解释力更强，故不记为截断。
      if new_count < c && new_count > 0L {
        pieces[victim] = new_bytes
        counts[victim] = new_count
        omitted_amounts[victim] = new_omitted
        total = total - c + new_count
        truncated_flags[victim] = true
        continue
      }
      // 一个 token 都截不下来：退化为整段丢。
    }
    dropped_flags[victim] = true
    total = total - c
  }
  // 第二轮：池配额（按声明顺序；借用也按声明顺序）。
  let npools = cfg.pools.length()
  let pool_used : Array[Int64] = Array::make(npools, 0L)
  let pool_demand : Array[Int64] = Array::make(npools, 0L)
  let pool_borrowed : Array[Int64] = Array::make(npools, 0L)
  let pool_lent : Array[Int64] = Array::make(npools, 0L)
  if npools > 0 {
    for i = 0; i < n; i = i + 1 {
      let p = pool_idx[i]
      if p >= 0 {
        pool_demand[p] = pool_demand[p] + original[i]
        if !dropped_flags[i] {
          pool_used[p] = pool_used[p] + counts[i]
        }
      }
    }
    for j = 0; j < npools; j = j + 1 {
      let quota = cfg.pools[j].limit
      let mut excess = pool_used[j] - quota
      if excess <= 0L {
        continue
      }
      // 借用：按声明顺序找有余量的池，借满为止。
      for k = 0; k < npools; k = k + 1 {
        if k == j || excess <= 0L {
          continue
        }
        let spare = cfg.pools[k].limit - pool_used[k] - pool_lent[k]
        if spare <= 0L {
          continue
        }
        let take = if excess < spare { excess } else { spare }
        // 借用只抬高借用方的可用额度，两池的「实际占用」都不变。
        pool_borrowed[j] = pool_borrowed[j] + take
        pool_lent[k] = pool_lent[k] + take
        excess = excess - take
      }
      // 借完仍超额：只在该池内部继续裁。
      while excess > 0L {
        let victim = pick_victim(segments, dropped_flags, j, pool_idx)
        if victim < 0 {
          break
        }
        let c = counts[victim]
        if cfg.strategy != NoTruncate && c > excess {
          let (new_bytes, new_count, new_omitted) = shrink(
            counter,
            cfg.strategy,
            pieces[victim],
            c - excess,
          )
          if new_count < c && new_count > 0L {
            pieces[victim] = new_bytes
            counts[victim] = new_count
            omitted_amounts[victim] = new_omitted
            total = total - c + new_count
            pool_used[j] = pool_used[j] - c + new_count
            truncated_flags[victim] = true
            excess = excess - (c - new_count)
            continue
          }
        }
        dropped_flags[victim] = true
        dropped_by_pool[victim] = true
        total = total - c
        pool_used[j] = pool_used[j] - c
        excess = excess - c
      }
    }
  }
  let kept : Array[KeptSegment] = []
  let truncated : Array[TruncatedSegment] = []
  let dropped : Array[DroppedSegment] = []
  for i = 0; i < n; i = i + 1 {
    let s = segments[i]
    if dropped_flags[i] {
      let p = pool_idx[i]
      let reason = if p >= 0 && dropped_by_pool[i] {
        pool_drop_reason(s.priority, cfg.pools[p].name, cfg.pools[p].limit)
      } else {
        drop_reason(s.priority)
      }
      dropped.push({
        index: i,
        role: s.role,
        priority: s.priority,
        tokens: original[i],
        reason,
      })
    } else if truncated_flags[i] {
      truncated.push({
        index: i,
        role: s.role,
        priority: s.priority,
        original_tokens: original[i],
        tokens: counts[i],
        strategy: cfg.strategy,
        omitted: omitted_amounts[i],
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
  let pools : Array[PoolUsage] = []
  for j = 0; j < npools; j = j + 1 {
    pools.push({
      name: cfg.pools[j].name,
      quota: cfg.pools[j].limit,
      demand: pool_demand[j],
      used: pool_used[j],
      borrowed: pool_borrowed[j],
      lent: pool_lent[j],
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
    pools,
    kept,
    truncated,
    dropped,
  }
}

///|
/// 段名 → 声明池下标；未声明返回 -1。
fn pool_index_of(pools : Array[PoolQuota], name : String) -> Int {
  if name.length() == 0 {
    return -1
  }
  for j = 0; j < pools.length(); j = j + 1 {
    if pools[j].name == name {
      return j
    }
  }
  -1
}

///|
/// 选受害者：非 Pinned、未丢；权重最小 → 分数最小 → 下标最小。
/// `only_pool >= 0` 时只在该池内选（池配额裁剪）。
fn pick_victim(
  segments : Array[Segment],
  dropped_flags : Array[Bool],
  only_pool : Int,
  pool_idx : Array[Int],
) -> Int {
  let mut victim = -1
  let mut best_w = 5
  let mut best_s = 0L
  for i = 0; i < segments.length(); i = i + 1 {
    if dropped_flags[i] || segments[i].priority == Pinned {
      continue
    }
    if only_pool >= 0 && pool_idx[i] != only_pool {
      continue
    }
    let w = segments[i].priority.weight()
    let s = segments[i].score
    if w < best_w || (w == best_w && s < best_s) {
      victim = i
      best_w = w
      best_s = s
    }
  }
  victim
}

///|
/// 把一段压到 `target` 个 token 以内，返回新字节与新计数。
/// 截不动（`target <= 0` 或一个 token 都留不下）时返回 `(空, 0)`，调用方据此整段丢。
fn shrink(
  counter : Counter,
  strategy : TruncateStrategy,
  bytes : Bytes,
  target : Int64,
) -> (Bytes, Int64, Int64) {
  if target <= 0L {
    return (slice_bytes(bytes, 0, 0), 0L, counter.count(bytes))
  }
  if strategy == Compress {
    return compress_to(counter, bytes, target)
  }
  let (cut, count) = cut_to(counter, bytes, target, strategy == KeepSuffix)
  (cut, count, counter.count(bytes) - count)
}

///|
/// 占位标记：固定文案，只带省略量（零依赖下这就是「占位压缩」的全部）。
fn compress_marker(omitted : Int64) -> Bytes {
  @utf8.encode("\n…[tally: \{omitted} tokens omitted]…\n")
}

///|
/// 保留前缀，把尾部换成占位标记，并把总量压到 `target` 以内。
///
/// 标记长度随省略量的位数变化，所以先按上界留位，再用实际省略量收敛
/// （最多三轮）；最后回读整段，保证报告里的 token 数与正文一致。
fn compress_to(
  counter : Counter,
  bytes : Bytes,
  target : Int64,
) -> (Bytes, Int64, Int64) {
  let original = counter.count(bytes)
  if target <= 0L || original == 0L {
    return (slice_bytes(bytes, 0, 0), 0L, original)
  }
  let mut marker = compress_marker(original)
  let mut marker_count = counter.count(marker)
  let keep_target = target - marker_count
  if keep_target <= 0L {
    return (slice_bytes(bytes, 0, 0), 0L, original)
  }
  let (prefix0, prefix0_count) = cut_to(counter, bytes, keep_target, false)
  let mut prefix = prefix0
  let mut prefix_count = prefix0_count
  for k = 0; k < 3; k = k + 1 {
    marker = compress_marker(original - prefix_count)
    marker_count = counter.count(marker)
    if prefix_count + marker_count <= target {
      break
    }
    let retry = prefix_count - (prefix_count + marker_count - target)
    if retry <= 0L {
      return (slice_bytes(bytes, 0, 0), 0L, original)
    }
    let (p2, c2) = cut_to(counter, bytes, retry, false)
    if c2 >= prefix_count {
      break
    }
    prefix = p2
    prefix_count = c2
  }
  let out = concat_bytes(prefix, marker)
  // 拼接处可能产生新合并，token 数只会更少，不会更多。
  (out, counter.count(out), original - prefix_count)
}

///|
fn concat_bytes(a : Bytes, b : Bytes) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < a.length(); i = i + 1 {
    out.push(a.unsafe_get(i))
  }
  for i = 0; i < b.length(); i = i + 1 {
    out.push(b.unsafe_get(i))
  }
  Bytes::from_array(out)
}

///|
fn pool_drop_reason(p : Priority, pool : String, quota : Int64) -> String {
  let why = match p {
    Pinned => "不可丢但已溢出（不应发生）"
    Newest => "池配额不足（最后才牺牲）"
    Middle => "池配额不足（优先级低于 Newest）"
    Oldest => "池配额不足（最早的历史，最先牺牲）"
  }
  "\{why}：池 \{pool} 配额 \{quota}"
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
