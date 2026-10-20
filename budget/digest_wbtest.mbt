// `tally-digest v1` 的证据：
// * 摘要能自洽（报告 + 摘要两个文件互相约束）；
// * 任何一处字节改动都会被抓到，且错误类型可命名；
// * 生产者自己的 bug（`used` 与逐段求和不符）也会被抓到 —— 摘要不是签名，
//   它证明的是"这两个文件描述同一件事"，不是"生成者说的是真的"。

///|
fn index_of_sub(s : String, sub : String) -> Int {
  let chars = s.to_array()
  let sc = sub.to_array()
  if sc.length() == 0 {
    return 0
  }
  for i = 0; i + sc.length() <= chars.length(); i = i + 1 {
    let mut same = true
    for j = 0; j < sc.length(); j = j + 1 {
      if chars[i + j] != sc[j] {
        same = false
        break
      }
    }
    if same {
      return i
    }
  }
  -1
}

///|
/// 把第 `idx` 个字符换成一个仍然合法的字符（字母换字母、数字换数字）。
fn flip_char_at(s : String, idx : Int) -> String {
  let chars = s.to_array()
  let c = chars[idx]
  let v = c.to_int()
  let digits : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
  ]
  chars[idx] = if v >= 0x30 && v <= 0x39 {
    digits[(v - 0x30 + 1) % 10]
  } else if v == 0x61 {
    'b'
  } else {
    'a'
  }
  String::from_array(chars)
}

///|
fn vlines(s : String) -> Array[String] {
  let out : Array[String] = []
  for l in s.split("\n") {
    out.push(l.to_owned())
  }
  out
}

///|
/// 把 LF 换成 CRLF：模拟 Windows 控制台重定向写出来的文件。
fn crlf(s : String) -> String {
  let out : Array[Char] = []
  for c in s.to_array() {
    if c == '\n' {
      out.push('\r')
    }
    out.push(c)
  }
  String::from_array(out)
}

///|
fn zero_sha() -> String {
  let out : Array[Char] = []
  for i = 0; i < 64; i = i + 1 {
    out.push('0')
  }
  String::from_array(out)
}

///|
/// 只替换第一处，找不到就原样返回。用来造"哈希对得上、语义不对"的对照文件。
fn replace_first(s : String, old : String, new : String) -> String {
  let at = index_of_sub(s, old)
  if at < 0 {
    return s
  }
  let chars = s.to_array()
  let old_len = old.to_array().length()
  let out : Array[Char] = []
  for i = 0; i < at; i = i + 1 {
    out.push(chars[i])
  }
  for c in new.to_array() {
    out.push(c)
  }
  for i = at + old_len; i < chars.length(); i = i + 1 {
    out.push(chars[i])
  }
  String::from_array(out)
}

///|
/// 删掉第 `pos` 个字符（长度 -1），用来把 64 位 sha 砍成 63 位。
fn drop_char_at(s : String, pos : Int) -> String {
  let chars = s.to_array()
  let out : Array[Char] = []
  for i = 0; i < chars.length(); i = i + 1 {
    if i != pos {
      out.push(chars[i])
    }
  }
  String::from_array(out)
}

///|
/// 解析一次摘要，返回 (结局, 行号)；成功时行号为 -1。
fn probe_parse(text : String) -> (String, Int) {
  let mut kind = "ok"
  let mut line = -1
  let _ = try {
    let d = parse_digest(text)
    Some(d)
  } catch {
    BadHeader(_) => {
      kind = "BadHeader"
      None
    }
    MalformedLine(n, _) => {
      kind = "MalformedLine"
      line = n
      None
    }
    _ => None
  }
  (kind, line)
}

///|
fn digest_fixture() -> (String, String) {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "aaaa"),
    Segment::text("old", Oldest, "bbbb"),
    Segment::text("mid", Middle, "cccc"),
    Segment::text("new", Newest, "dddd"),
  ]
  let plan = assemble(FitConfig::new(exact_counter(v), 12L), segments)
  (plan.render(), plan.render_digest())
}

///|
test "digest: roundtrip and verify pass on a clean plan" {
  let (report, digest) = digest_fixture()
  assert_true(digest.has_prefix("tally-digest v1\n"))
  let parsed = try parse_digest(digest) catch {
    _ => panic()
  }
  assert_eq(parsed.report_sha.length(), 64)
  assert_eq(parsed.plan_sha.length(), 64)
  // kept 3 + dropped 1
  assert_eq(parsed.entries.length(), 4)
  let mut dropped_entries = 0
  for e in parsed.entries {
    if e.action == "dropped" {
      dropped_entries = dropped_entries + 1
      assert_eq(e.sha, "-")
    } else {
      assert_eq(e.sha.length(), 64)
    }
  }
  assert_eq(dropped_entries, 1)
  let mut failed = false
  try verify_digest_pair(report, digest) catch {
    _ => failed = true
  }
  assert_false(failed)
}

///|
test "digest: any byte change in the report is caught (J)" {
  let (report, digest) = digest_fixture()
  // 报告里不出现段文本，所以改"角色名"而不是"内容"：仍然是合法报告，只是内容对不上。
  let at_role = index_of_sub(report, "mid")
  let at_used = index_of_sub(report, "used ")
  assert_true(at_role > 0 && at_used > 0)
  let cases = [
    flip_char_at(report, at_role), // 角色改名，仍然是合法报告
    flip_char_at(report, at_used + 5), // used 的数字改一位
    flip_char_at(report, 0), // 头部版本号改名
    report + "x\n", // 多一行
  ]
  for tampered in cases {
    let mut caught = false
    try verify_digest_pair(tampered, digest) catch {
      _ => caught = true
    }
    assert_true(caught)
  }
  // 改名这一类必须是"哈希对不上"，而不是"解析不了"
  let mut hash_mismatch = false
  try verify_digest_pair(flip_char_at(report, at_role), digest) catch {
    ReportHashMismatch(_, _) => hash_mismatch = true
    _ => ()
  }
  assert_true(hash_mismatch)
}

///|
test "digest: any byte change in a segment hash is caught (J)" {
  let (report, digest) = digest_fixture()
  let at = index_of_sub(digest, "kept ")
  assert_true(at > 0)
  // `kept` 行形如 `<index> kept <64hex>`，改最后一个 hex 字符
  let tampered = flip_char_at(digest, at + 5 + 63)
  let mut caught = false
  try verify_digest_pair(report, tampered) catch {
    PlanHashMismatch(_, _) => caught = true
    _ => ()
  }
  assert_true(caught)
}

///|
test "digest: dropped segment rows are listed but not hashed" {
  let v = byte_vocab()
  let segments = [
    Segment::text("system", Pinned, "aaaa"),
    Segment::text("payload", Newest, "bbbbbbbbbbbb"),
  ]
  // limit 小于 payload：整段丢，没有截断
  let plan = assemble(FitConfig::new(exact_counter(v), 6L), segments)
  assert_eq(plan.dropped.length(), 1)
  let digest = plan.digest()
  assert_eq(digest.entries.length(), 2)
  assert_eq(digest.entries[1].action, "dropped")
  assert_eq(digest.entries[1].sha, "-")
  let mut failed = false
  try verify_digest_pair(plan.render(), digest.render()) catch {
    _ => failed = true
  }
  assert_false(failed)
}

///|
/// 生产者的 bug：`used` 与逐段求和不符。摘要要拒绝，而不是跟着错。
test "digest: producer bug in used is caught" {
  let v = byte_vocab()
  let segments = [Segment::text("system", Pinned, "aaaa")]
  let plan = assemble(FitConfig::new(exact_counter(v), 10L), segments)
  let broken = { ..plan, tokens_used: plan.tokens_used + 1L }
  let mut caught = false
  try verify_digest_pair(broken.render(), broken.render_digest()) catch {
    UsedMismatch(_, _) => caught = true
    _ => ()
  }
  assert_true(caught)
}

///|
test "digest: malformed digest reports the line number" {
  let (_, digest) = digest_fixture()
  let bad = digest + "garbage\n"
  let mut got = 0
  let parsed = try parse_digest(bad) catch {
    MalformedLine(line, _) => {
      got = line
      { report_sha: "", plan_sha: "", entries: [] }
    }
    _ => panic()
  }
  ignore(parsed)
  assert_eq(got, digest.split("\n").length())
}

///|
/// CRLF 不是篡改：Windows 控制台重定向会写出 CRLF，归一之后再哈希。
test "digest: CRLF copies verify the same as LF" {
  let (report, digest) = digest_fixture()
  let mut failed = false
  try verify_digest_pair(crlf(report), crlf(digest)) catch {
    _ => failed = true
  }
  assert_false(failed)
}

///|
/// 尾部多几个空行也是打印行为，不携带信息；但正文里多一行就是事故。
test "digest: trailing blank lines are tolerated, extra body lines are not" {
  let (report, digest) = digest_fixture()
  let mut failed = false
  try verify_digest_pair(report + "\n\n\n", digest + "\n") catch {
    _ => failed = true
  }
  assert_false(failed)
  let mut caught = false
  try verify_digest_pair(report, digest + "0 kept " + zero_sha() + "\n") catch {
    _ => caught = true
  }
  assert_true(caught)
}

///|
test "digest: unknown version is named, not guessed" {
  let (report, digest) = digest_fixture()
  let bumped = replace_first(digest, "tally-digest v1", "tally-digest v2")
  let mut got = ""
  let _ = try verify_digest_pair(report, bumped) catch {
    BadHeader(h) => got = h
    _ => ()
  }
  assert_eq(got, "tally-digest v2")
}

///|
test "digest: missing plan line is a named error, not a silent pass" {
  let (_, digest) = digest_fixture()
  let lines = vlines(digest)
  let kept : Array[String] = []
  for i = 0; i < lines.length(); i = i + 1 {
    if !lines[i].has_prefix("plan ") {
      kept.push(lines[i])
    }
  }
  let bad = kept.join("\n")
  let (kind, _) = probe_parse(bad)
  assert_eq(kind, "MalformedLine")
}

///|
/// sha 长度不对就不该进入比较阶段：`plan` 行与段行都要求 64 位。
test "digest: a 63-char sha is malformed and reports its line" {
  let (_, digest) = digest_fixture()
  let at = index_of_sub(digest, "kept ")
  assert_true(at > 0)
  // `kept` 行的 sha 从 `kept ` 之后第 1 个字符开始；砍掉一个 hex 字符
  let bad = drop_char_at(digest, at + 5)
  let (kind, line) = probe_parse(bad)
  assert_eq(kind, "MalformedLine")
  // 摘要的第 5 行是第一条段行
  assert_eq(line, 5)
}

///|
/// 重排段行不改变内容，却改变了"报告与摘要的顺序约定"——必须被抓到。
test "digest: reordering segment rows breaks the plan digest" {
  let (report, digest) = digest_fixture()
  // 只取非空行：摘要以 `\n` 结尾，直接按 `\n` 切会多出一个空元素。
  let body : Array[String] = []
  for l in vlines(digest) {
    if l.length() > 0 {
      body.push(l)
    }
  }
  let n = body.length()
  let tmp = body[n - 1]
  body[n - 1] = body[n - 2]
  body[n - 2] = tmp
  let mut caught = false
  let _ = try verify_digest_pair(report, body.join("\n")) catch {
    PlanHashMismatch(_, _) => caught = true
    _ => ()
  }
  assert_true(caught)
}

///|
/// 少列一段：段数对不上。为了让错误落到"段数"而不是"哈希"，
/// 摘要的 `plan` 行按删掉后的内容重算一遍。
test "digest: dropping a segment row is a count mismatch" {
  let (report, digest) = digest_fixture()
  let parsed = try parse_digest(digest) catch {
    _ => panic()
  }
  let kept : Array[DigestEntry] = []
  for i = 0; i + 1 < parsed.entries.length(); i = i + 1 {
    kept.push(parsed.entries[i])
  }
  let broken : PlanDigest = {
    report_sha: parsed.report_sha,
    plan_sha: plan_digest_for(kept),
    entries: kept,
  }
  let mut caught = false
  let _ = try verify_digest_pair(report, broken.render()) catch {
    SegmentCountMismatch(_, _) => caught = true
    _ => ()
  }
  assert_true(caught)
}

///|
/// 动作被改（kept → truncated）且哈希自洽：这是"两个文件说的不是同一件事"，
/// 只能靠逐段对账发现，哈希无能为力。
test "digest: action mismatch is caught only by per-segment reconciliation" {
  let (report, digest) = digest_fixture()
  let parsed = try parse_digest(digest) catch {
    _ => panic()
  }
  let changed : Array[DigestEntry] = []
  for e in parsed.entries {
    if e.action == "kept" && changed.length() == 0 {
      changed.push({ index: e.index, action: "truncated", sha: e.sha })
    } else {
      changed.push(e)
    }
  }
  let broken : PlanDigest = {
    report_sha: parsed.report_sha,
    plan_sha: plan_digest_for(changed),
    entries: changed,
  }
  let mut caught = false
  let _ = try verify_digest_pair(report, broken.render()) catch {
    SegmentActionMismatch(_, _, _) => caught = true
    _ => ()
  }
  assert_true(caught)
}

///|
/// 哈希全对、算术不对：`input_limit != window - reserve`。
/// 这条说明摘要不是签名——它只证明两个文件一致，不证明它们说的是真的。
test "digest: arithmetic inconsistency inside a self-consistent pair is named" {
  let (report, digest) = digest_fixture()
  let parsed = try parse_digest(digest) catch {
    _ => panic()
  }
  let bad_report = replace_first(report, "input_limit 12", "input_limit 13")
  let broken : PlanDigest = {
    report_sha: sha256_hex(@utf8.encode(bad_report)),
    plan_sha: parsed.plan_sha,
    entries: parsed.entries,
  }
  let mut caught = false
  let _ = try verify_digest_pair(bad_report, broken.render()) catch {
    LimitMismatch(_, _) => caught = true
    _ => ()
  }
  assert_true(caught)
}

///|
/// 溢出计划：哨兵行 `index == -1` 不在报告段数里，但摘要要列出来并参与段哈希。
test "digest: overflow sentinel row is listed and still verifiable" {
  let v = byte_vocab()
  let segments = [Segment::text("system", Pinned, "aaaa")]
  let plan = assemble(FitConfig::new(exact_counter(v), 2L), segments)
  assert_true(plan.overflow)
  let d = plan.digest()
  assert_eq(d.entries.length(), 2)
  assert_eq(d.entries[0].index, -1)
  assert_eq(d.entries[0].action, "dropped")
  assert_eq(d.entries[0].sha, "-")
  let mut failed = false
  try verify_digest_pair(plan.render(), d.render()) catch {
    _ => failed = true
  }
  assert_false(failed)
}

///|
/// 空文件：宁可报"缺 report/plan 行"，也不当成"空摘要 = 全部通过"。
test "digest: empty digest is a named error" {
  let (kind, _) = probe_parse("")
  assert_eq(kind, "MalformedLine")
}

///|
test "digest: normalize_newlines is idempotent" {
  let messy = "a\r\nb\r\n\r\n\r\n"
  let once = normalize_newlines(messy)
  assert_eq(once, "a\nb\n")
  assert_eq(normalize_newlines(once), once)
}
