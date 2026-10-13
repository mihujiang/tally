// 装配、截断与丢弃报告。
//
// 不变量：
//   V13 `Plan::tokens_used <= limit`，除非 `overflow` 被显式置真并给出原因。
//   V14 `Pinned` 段永远完整出现在结果里；装不下时要给出可操作的建议。
//   V15 `Plan::render` 的输出是规范文本（稳定、可冻结、可 diff、无 Map 迭代序）。

///|
/// 被保留的一段。
pub(all) struct KeptSegment {
  index : Int
  role : String
  priority : Priority
  tokens : Int64
} derive(Debug)

///|
/// 被丢弃的一段，带**原因**（这是本层相对同类工具的核心增量）。
pub(all) struct DroppedSegment {
  index : Int
  role : String
  priority : Priority
  tokens : Int64
  reason : String
} derive(Debug)

///|
/// 装配计划。`tokens_used` 是**已装入窗口**的 token 数；
/// 被丢弃的段不计入。
pub(all) struct Plan {
  limit : Int64
  tokens_used : Int64
  pinned_tokens : Int64
  overflow : Bool
  kept : Array[KeptSegment]
  dropped : Array[DroppedSegment]
} derive(Debug)

///|
/// 依优先级把段装进 `limit`。
///
/// 丢弃顺序完全确定：先丢权重最小的；权重相同时丢**原始下标较小**的（更早的历史）。
pub fn fit(v : @vocab.Vocab, segments : Array[Segment], limit : Int64) -> Plan {
  let n = segments.length()
  let counts : Array[Int64] = []
  let kept_flags : Array[Bool] = []
  let mut total : Int64 = 0
  let mut pinned_tokens : Int64 = 0
  for i = 0; i < n; i = i + 1 {
    let c = v.count_bytes(segments[i].bytes)
    counts.push(c)
    kept_flags.push(true)
    total = total + c
    if segments[i].priority == Pinned {
      pinned_tokens = pinned_tokens + c
    }
  }
  let mut overflow = false
  while total > limit {
    // 选受害者：非 Pinned 中权重最小者；并列时取下标最小者。
    let mut victim = -1
    let mut victim_w = 4
    for i = 0; i < n; i = i + 1 {
      if kept_flags[i] && segments[i].priority != Pinned {
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
    kept_flags[victim] = false
    total = total - counts[victim]
  }
  let kept : Array[KeptSegment] = []
  let dropped : Array[DroppedSegment] = []
  for i = 0; i < n; i = i + 1 {
    let s = segments[i]
    if kept_flags[i] {
      kept.push({
        index: i,
        role: s.role,
        priority: s.priority,
        tokens: counts[i],
      })
    } else {
      dropped.push({
        index: i,
        role: s.role,
        priority: s.priority,
        tokens: counts[i],
        reason: drop_reason(s.priority),
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
    limit,
    tokens_used: total,
    pinned_tokens,
    overflow,
    kept,
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
