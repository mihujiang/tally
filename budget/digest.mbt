// `tally-digest v1`：把「报告说了什么」和「报告对应的内容是什么」绑在一起。
//
// 分工（这是本层存在的理由，别把两者混成一层）：
// * 报告（`tally-plan v2`）给人看：哪段保留/截断/丢弃、多少 token、为什么；
// * 摘要（`tally-digest v1`）给机器看：报告正文的 sha256 + 每段内容的 sha256。
//
// 于是「报告有没有被改过」「这段内容是不是报告里那一段」都能用两个文件回答，
// 不需要信任报告里的数字。
//
// 段内容只覆盖 kept / truncated：被丢弃的段从未进入窗口，它的字节不在计划里。
// 这一点写进格式，不假装能证明没发生过的事。

///|
pub(all) struct DigestEntry {
  index : Int
  /// `kept` / `truncated` / `dropped`
  action : String
  /// 段内容的 sha256 hex；`dropped` 为 `-`
  sha : String
} derive(Debug)

///|
pub(all) struct PlanDigest {
  report_sha : String
  plan_sha : String
  entries : Array[DigestEntry]
} derive(Debug)

///|
pub suberror DigestError {
  /// 不认识的头部（版本漂移时宁可报错，也不猜格式）
  BadHeader(String)
  /// 第 `line` 行格式不合法
  MalformedLine(Int, String)
  /// 报告正文与 `report` 行不一致
  ReportHashMismatch(String, String)
  /// 段行与 `plan` 行不一致
  PlanHashMismatch(String, String)
  /// 段数与报告里的段数不一致
  SegmentCountMismatch(Int, Int)
  /// 第 `index` 段的动作在报告与摘要里不一致
  SegmentActionMismatch(Int, String, String)
  /// 报告的 `used` 与逐段求和不等
  UsedMismatch(Int64, Int64)
  /// `window - reserve != input_limit`
  LimitMismatch(Int64, Int64)
}

///|
fn split_spaces(line : StringView) -> Array[String] {
  let out : Array[String] = []
  for p in line.split(" ") {
    if p.length() > 0 {
      out.push(p.to_owned())
    }
  }
  out
}

///|
fn parse_int_str(s : String) -> Int? {
  let chars = s.to_array()
  let n = chars.length()
  if n == 0 {
    return None
  }
  let neg = chars[0] == '-'
  let start = if neg { 1 } else { 0 }
  if start >= n {
    return None
  }
  let mut v = 0
  for i = start; i < n; i = i + 1 {
    let d = chars[i].to_int() - 0x30
    if d < 0 || d > 9 {
      return None
    }
    v = v * 10 + d
  }
  Some(if neg { -v } else { v })
}

///|
/// 把 `12->7` 拆成 (12, 7)；截断行的两半都是非负整数。
fn split_arrow(s : String) -> (Int, Int)? {
  let chars = s.to_array()
  let n = chars.length()
  let mut at = -1
  for i = 0; i + 1 < n; i = i + 1 {
    if chars[i] == '-' && chars[i + 1] == '>' {
      at = i
      break
    }
  }
  if at < 0 {
    return None
  }
  let left = parse_int_str(String::from_array(chars[0:at].to_owned()))
  let right = parse_int_str(
    String::from_array(chars[at + 2:n].to_owned()),
  )
  match (left, right) {
    (Some(l), Some(r)) => Some((l, r))
    _ => None
  }
}

///|
fn plan_digest_for(entries : Array[DigestEntry]) -> String {
  let out : Array[Char] = []
  for e in entries {
    for c in (e.index.to_string() + " " + e.action + " " + e.sha + "\n").to_array() {
      out.push(c)
    }
  }
  sha256_hex(@utf8.encode(String::from_array(out)))
}

///|
/// 按段下标升序（插入排序，段数是个位到几十，别为它引依赖）。
fn sort_entries(entries : Array[DigestEntry]) -> Array[DigestEntry] {
  let out = entries.copy()
  let n = out.length()
  for i = 1; i < n; i = i + 1 {
    let cur = out[i]
    let mut j = i
    while j > 0 && out[j - 1].index > cur.index {
      out[j] = out[j - 1]
      j = j - 1
    }
    out[j] = cur
  }
  out
}

///|
/// 计算一份计划的摘要。`entries` 按段下标升序，与输入顺序无关。
pub fn Plan::digest(self : Plan) -> PlanDigest {
  let entries : Array[DigestEntry] = []
  for k in self.kept {
    entries.push({ index: k.index, action: "kept", sha: sha256_hex(k.bytes) })
  }
  for t in self.truncated {
    entries.push({
      index: t.index,
      action: "truncated",
      sha: sha256_hex(t.bytes),
    })
  }
  for d in self.dropped {
    entries.push({ index: d.index, action: "dropped", sha: "-" })
  }
  let sorted = sort_entries(entries)
  {
    report_sha: sha256_hex(@utf8.encode(self.render())),
    plan_sha: plan_digest_for(sorted),
    entries: sorted,
  }
}

///|
pub fn PlanDigest::render(self : PlanDigest) -> String {
  let out : Array[Char] = []
  for c in (
    "tally-digest v1\nreport " +
    self.report_sha +
    "\nplan " +
    self.plan_sha +
    "\n[segments]\n"
  ).to_array() {
    out.push(c)
  }
  for e in self.entries {
    for c in (e.index.to_string() + " " + e.action + " " + e.sha + "\n").to_array() {
      out.push(c)
    }
  }
  String::from_array(out)
}

///|
/// 摘要文本，供 CLI 落盘（与 `Plan::render` 并列的两个产物）。
pub fn Plan::render_digest(self : Plan) -> String {
  self.digest().render()
}

///|
/// 解析摘要文本。逐行给出错误位置，不做"尽力而为"的修复。
pub fn parse_digest(text : String) -> PlanDigest raise DigestError {
  let entries : Array[DigestEntry] = []
  let mut line_no = 0
  let mut report_sha = ""
  let mut plan_sha = ""
  let mut in_segments = false
  for raw in text.split("\n") {
    line_no = line_no + 1
    let line = raw.trim()
    if line.length() == 0 {
      continue
    }
    if line_no == 1 {
      if line != "tally-digest v1" {
        raise BadHeader(line.to_owned())
      }
      continue
    }
    let parts = split_spaces(line)
    if parts.length() == 0 {
      continue
    }
    if parts[0] == "[segments]" {
      in_segments = true
      continue
    }
    if in_segments {
      if parts.length() != 3 {
        raise MalformedLine(line_no, line.to_owned())
      }
      match parse_int_str(parts[0]) {
        None => raise MalformedLine(line_no, line.to_owned())
        Some(index) => {
          let action = parts[1]
          if action != "kept" && action != "truncated" && action != "dropped" {
            raise MalformedLine(line_no, line.to_owned())
          }
          if action == "dropped" && parts[2] != "-" {
            raise MalformedLine(line_no, line.to_owned())
          }
          if action != "dropped" && parts[2].length() != 64 {
            raise MalformedLine(line_no, line.to_owned())
          }
          entries.push({ index, action, sha: parts[2] })
        }
      }
    } else if parts[0] == "report" {
      if parts.length() != 2 || parts[1].length() != 64 {
        raise MalformedLine(line_no, line.to_owned())
      }
      report_sha = parts[1]
    } else if parts[0] == "plan" {
      if parts.length() != 2 || parts[1].length() != 64 {
        raise MalformedLine(line_no, line.to_owned())
      }
      plan_sha = parts[1]
    } else {
      raise MalformedLine(line_no, line.to_owned())
    }
  }
  if report_sha == "" || plan_sha == "" {
    raise MalformedLine(0, "missing report/plan digest line")
  }
  { report_sha, plan_sha, entries }
}

///|
priv struct ReportedSegment {
  index : Int
  action : String
  tokens : Int64
}

///|
priv struct ReportFacts {
  window : Int64
  reserve : Int64
  limit : Int64
  used : Int64
  segments : Array[ReportedSegment]
}

///|
/// 解析 `tally-plan v2`。只取 verify 需要的字段；未知行一律报错，
/// 免得"报告格式漂移了但校验还说 ok"。
fn parse_report(report : String) -> ReportFacts raise DigestError {
  let mut line_no = 0
  let mut window : Int64 = 0L
  let mut reserve : Int64 = 0L
  let mut limit : Int64 = 0L
  let mut used : Int64 = 0L
  let mut section = ""
  let segments : Array[ReportedSegment] = []
  for raw in report.split("\n") {
    line_no = line_no + 1
    let line = raw.trim()
    if line.length() == 0 {
      continue
    }
    if line_no == 1 {
      if line != "tally-plan v2" {
        raise BadHeader(line.to_owned())
      }
      continue
    }
    let parts = split_spaces(line)
    if parts.length() == 0 {
      continue
    }
    if parts[0] == "[kept]" || parts[0] == "[truncated]" || parts[0] == "[dropped]" {
      section = parts[0]
      continue
    }
    if section == "" {
      if parts[0] == "counter" {
        if parts.length() != 3 || parts[1].length() == 0 {
          raise MalformedLine(line_no, line.to_owned())
        }
        continue
      }
      if parts[0] == "overflow" {
        if parts.length() != 2 || (parts[1] != "true" && parts[1] != "false") {
          raise MalformedLine(line_no, line.to_owned())
        }
        continue
      }
      if parts[0] == "pinned" {
        if parts.length() != 2 || parse_int_str(parts[1]) == None {
          raise MalformedLine(line_no, line.to_owned())
        }
        continue
      }
      if parts.length() != 2 {
        raise MalformedLine(line_no, line.to_owned())
      }
      let v = match parse_int_str(parts[1]) {
        Some(x) => x.to_int64()
        None => raise MalformedLine(line_no, line.to_owned())
      }
      if parts[0] == "window" {
        window = v
      } else if parts[0] == "reserve" {
        reserve = v
      } else if parts[0] == "input_limit" {
        limit = v
      } else if parts[0] == "used" {
        used = v
      } else if parts[0] == "pinned" {
        ()
      } else {
        raise MalformedLine(line_no, line.to_owned())
      }
      continue
    }
    if section == "[kept]" {
      if parts.length() != 4 {
        raise MalformedLine(line_no, line.to_owned())
      }
      let index = match parse_int_str(parts[0]) {
        Some(x) => x
        None => raise MalformedLine(line_no, line.to_owned())
      }
      let tokens = match parse_int_str(parts[3]) {
        Some(x) => x.to_int64()
        None => raise MalformedLine(line_no, line.to_owned())
      }
      segments.push({ index, action: "kept", tokens })
    } else if section == "[truncated]" {
      if parts.length() != 5 {
        raise MalformedLine(line_no, line.to_owned())
      }
      let index = match parse_int_str(parts[0]) {
        Some(x) => x
        None => raise MalformedLine(line_no, line.to_owned())
      }
      let tokens = match split_arrow(parts[3]) {
        Some(pair) => {
          let (_, kept_tokens) = pair
          kept_tokens.to_int64()
        }
        None => raise MalformedLine(line_no, line.to_owned())
      }
      segments.push({ index, action: "truncated", tokens })
    } else {
      if parts.length() < 5 {
        raise MalformedLine(line_no, line.to_owned())
      }
      let index = match parse_int_str(parts[0]) {
        Some(x) => x
        None => raise MalformedLine(line_no, line.to_owned())
      }
      // 哨兵行（`index == -1`）的 tokens 是溢出量，不是某段的量。
      let tokens = match parse_int_str(parts[3]) {
        Some(x) => x.to_int64()
        None => raise MalformedLine(line_no, line.to_owned())
      }
      segments.push({ index, action: "dropped", tokens })
    }
  }
  { window, reserve, limit, used, segments }
}

///|
/// 把文件里的"编辑产物"归一到规范形：去 UTF-8 BOM、CRLF 归一成 LF、结尾只留一个换行。
///
/// 为什么需要：格式里只有 LF，但 Windows 控制台重定向会把 LF 写成 CRLF；
/// 编辑器（含 PowerShell 的 `Out-File -Encoding utf8`）还会在开头写 BOM。
/// 如果不归一，"文件在磁盘上"和"文件被哈希时"就是两份不同的字节，
/// 校验会在没被篡改的文件上失败——那是误报，比漏报更难查。
pub fn normalize_newlines(text : String) -> String {
  let chars = text.to_array()
  let out : Array[Char] = []
  let mut i = 0
  // BOM 不是正文：留着会让"第一行是 tally-digest v1"变成"第一行多了个隐形字符"。
  if chars.length() > 0 && chars[0] == '\u{FEFF}' {
    i = 1
  }
  while i < chars.length() {
    if chars[i] == '\r' && i + 1 < chars.length() && chars[i + 1] == '\n' {
      out.push('\n')
      i = i + 2
    } else {
      out.push(chars[i])
      i = i + 1
    }
  }
  // 结尾只留一个换行：`println(render())` 会在已经以 `\n` 结尾的正文后再补一个换行，
  // 那是打印行为，不是内容。多个空行也不携带信息，一并归一到规范形。
  while out.length() > 1 &&
    out[out.length() - 1] == '\n' &&
    out[out.length() - 2] == '\n' {
    let _ = out.pop()
  }
  String::from_array(out)
}

///|
/// 只做**自洽性**校验：报告没有被改过、摘要与报告对得上、`used` 与逐段求和相等。
/// 要证明"这份报告确实由这批输入和这套策略产出"，还需要重跑一遍（CLI 的 `--vocab` 分支）。
pub fn verify_digest_pair(report : String, digest_text : String) -> Unit raise DigestError {
  let report = normalize_newlines(report)
  let digest_text = normalize_newlines(digest_text)
  let digest = parse_digest(digest_text)
  let facts = parse_report(report)
  let report_sha = sha256_hex(@utf8.encode(report))
  if report_sha != digest.report_sha {
    raise ReportHashMismatch(digest.report_sha, report_sha)
  }
  let plan_sha = plan_digest_for(digest.entries)
  if plan_sha != digest.plan_sha {
    raise PlanHashMismatch(digest.plan_sha, plan_sha)
  }
  if facts.limit != facts.window - facts.reserve {
    raise LimitMismatch(facts.window - facts.reserve, facts.limit)
  }
  // 哨兵行（index == -1）不是某一段：它进 plan 哈希（"溢出过"这件事要可核对），
  // 但不参与段对账——两侧都按同一规则过滤，否则溢出计划的段数永远对不上。
  let real : Array[ReportedSegment] = []
  for s in facts.segments {
    if s.index >= 0 {
      real.push(s)
    }
  }
  let dig_real : Array[DigestEntry] = []
  for d in digest.entries {
    if d.index >= 0 {
      dig_real.push(d)
    }
  }
  if real.length() != dig_real.length() {
    raise SegmentCountMismatch(real.length(), dig_real.length())
  }
  // 报告按 kept → truncated → dropped 分节，摘要按段下标排序；对账前统一成下标序。
  for i = 1; i < real.length(); i = i + 1 {
    let cur = real[i]
    let mut j = i
    while j > 0 && real[j - 1].index > cur.index {
      real[j] = real[j - 1]
      j = j - 1
    }
    real[j] = cur
  }
  let mut sum : Int64 = 0L
  for i = 0; i < real.length(); i = i + 1 {
    let r = real[i]
    let d = dig_real[i]
    if r.index != d.index || r.action != d.action {
      raise SegmentActionMismatch(r.index, r.action, d.action)
    }
    // 只有 kept / truncated 的 token 计入 `used`；丢弃段的数字是"它有多大"，不是"它占了多少"。
    if r.action != "dropped" {
      sum = sum + r.tokens
    }
  }
  if sum != facts.used {
    raise UsedMismatch(facts.used, sum)
  }
}

///|
/// 给 CLI / 日志用的可读消息。位置信息保留在字符串里，别在调用处再拼一遍。
pub fn DigestError::message(self : DigestError) -> String {
  match self {
    BadHeader(h) => "unrecognised header: " + h
    MalformedLine(n, t) =>
      "line " + n.to_string() + ": malformed: " + t
    ReportHashMismatch(expected, actual) =>
      "report sha256 mismatch: digest says " + expected + ", file is " + actual
    PlanHashMismatch(expected, actual) =>
      "segment digest mismatch: digest says " + expected + ", recomputed " + actual
    SegmentCountMismatch(report_n, digest_n) =>
      "segment count mismatch: report has " +
      report_n.to_string() +
      ", digest has " +
      digest_n.to_string()
    SegmentActionMismatch(index, report_action, digest_action) =>
      "segment " +
      index.to_string() +
      ": report says " +
      report_action +
      ", digest says " +
      digest_action
    UsedMismatch(report_used, sum) =>
      "used mismatch: report says " +
      report_used.to_string() +
      ", segments sum to " +
      sum.to_string()
    LimitMismatch(expected, actual) =>
      "input_limit mismatch: window - reserve = " +
      expected.to_string() +
      ", report says " +
      actual.to_string()
  }
}

///|
/// 不 `raise` 的校验通道：把 `DigestError` 折成一句带位置的话。
///
/// 存在的理由和 `fit_with_result` 一样——suberror 构造器不能经 `pub using` 再导出，
/// 只 import 门面包的使用者写不出 `catch { ReportHashMismatch(..) => .. }`。
/// 这里把「哪份文件、哪个位置、两个 sha256 各是什么」一次性给全。
pub fn verify_report(
  report : String,
  digest_text : String,
) -> Result[Unit, String] {
  let err : DigestError? = try {
    verify_digest_pair(report, digest_text)
    None
  } catch {
    BadHeader(h) => Some(BadHeader(h))
    MalformedLine(n, t) => Some(MalformedLine(n, t))
    ReportHashMismatch(a, b) => Some(ReportHashMismatch(a, b))
    PlanHashMismatch(a, b) => Some(PlanHashMismatch(a, b))
    SegmentCountMismatch(a, b) => Some(SegmentCountMismatch(a, b))
    SegmentActionMismatch(i, a, b) => Some(SegmentActionMismatch(i, a, b))
    UsedMismatch(a, b) => Some(UsedMismatch(a, b))
    LimitMismatch(a, b) => Some(LimitMismatch(a, b))
  }
  match err {
    None => Ok(())
    Some(e) => Err(e.message())
  }
}
