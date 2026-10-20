// `tally-seal v1`：给摘要再盖一枚**用密钥认过**的印记。
//
// 三层各司其职，别混：
// * `tally-plan v2` 给人看：哪段保留/截断/丢弃；
// * `tally-digest v1` 给机器算：报告字节与逐段字节的 sha256（**谁都能算**）；
// * `tally-seal v1` 给"谁认过"：摘要字节的 sha256 + 用共享密钥算出的 HMAC。
//
// 为什么不是公钥签名：核心包零第三方依赖，做 Ed25519 是另一件事；
// 而 HMAC 已经把"文件被换过"和"没换但也没人认过"分开了。边界写进格式：
// 它证明**持有同一把密钥的人**认过这份摘要，不证明"谁写的"。
//
// 形式（5 行，行序固定，逐字节冻结）：
//
//   tally-seal v1
//   scheme hmac-sha256
//   key_id <id|->            ← 多密钥轮换时用来指认是哪把
//   digest <sha256 of digest file>
//   seal <hmac sha256 hex>   ← 覆盖上面 4 行（含头部），不含本行
//
// 只签 4 行不含 `seal` 行，是因为签名不可能覆盖自己。

///|
pub(all) struct Seal {
  /// 目前只有 `hmac-sha256`；写进行里是为了将来换算法时能被显式拒绝
  scheme : String
  /// 密钥标识；`-` 表示未声明（轮换与审计用，不参与安全假设）
  key_id : String
  /// 被签摘要文件的 sha256（hex）
  digest_sha : String
  /// HMAC-SHA256 的 hex
  seal : String
} derive(Debug)

///|
pub suberror SealError {
  /// 不认识的头部
  BadSealHeader(String)
  /// 第 `line` 行格式不合法
  SealMalformedLine(Int, String)
  /// 行序固定，但这一行不是期望的键
  SealUnexpectedField(Int, String, String)
  /// 只有 `hmac-sha256`；别的算法宁可拒绝
  SealSchemeUnsupported(String)
  /// 密钥为空：空密钥等于人人可签
  SealEmptyKey
  /// `key_id` 含空白（会破坏空格分隔的格式）
  SealBadKeyId(String)
  /// 被签摘要与 `digest` 行不一致
  SealDigestMismatch(String, String)
  /// HMAC 不一致：密钥不对，或四行里有一处被改
  SealMacMismatch(String, String)
}

///|
fn has_whitespace(s : String) -> Bool {
  for c in s.to_array() {
    if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
      return true
    }
  }
  false
}

///|
/// 规范化的 `key_id`：空串写成 `-`。
fn normalized_key_id(key_id : String) -> String raise SealError {
  if key_id == "" {
    "-"
  } else {
    if has_whitespace(key_id) {
      raise SealBadKeyId(key_id)
    }
    key_id
  }
}

///|
/// 被签的 4 行（含头部）。`seal` 行不在此列。
fn signing_text(seal : Seal) -> String {
  "tally-seal v1\nscheme " +
  seal.scheme +
  "\nkey_id " +
  seal.key_id +
  "\ndigest " +
  seal.digest_sha +
  "\n"
}

///|
/// 渲染成规范文本（5 行，以 `\n` 结尾）。
fn Seal::render(self : Seal) -> String {
  signing_text(self) + "seal " + self.seal + "\n"
}

///|
/// 给摘要盖印记。`key` 是共享密钥的 UTF-8 字节；空密钥直接拒绝。
pub fn seal_digest(
  digest_text : String,
  key : String,
  key_id : String,
) -> String raise SealError {
  if key == "" {
    raise SealEmptyKey
  }
  let digest_sha = sha256_hex(@utf8.encode(normalize_newlines(digest_text)))
  let key_id = normalized_key_id(key_id)
  let unsigned : Seal = {
    scheme: "hmac-sha256",
    key_id,
    digest_sha,
    seal: "",
  }
  let mac = hmac_sha256_hex(@utf8.encode(key), @utf8.encode(signing_text(unsigned)))
  let signed : Seal = { scheme: "hmac-sha256", key_id, digest_sha, seal: mac }
  signed.render()
}

///|
/// 盖章的非异常通道：把构造器折成带位置的一句话。
///
/// 实际只有 `SealEmptyKey` / `SealBadKeyId` 可达（输入问题），其余照列是为了
/// 让 `catch` 穷尽——同时把"哪些错误存在"集中在 `SealError` 一处。
pub fn seal_digest_result(
  digest_text : String,
  key : String,
  key_id : String,
) -> Result[String, String] {
  let outcome : Result[String, SealError] = try {
    Ok(seal_digest(digest_text, key, key_id))
  } catch {
    BadSealHeader(h) => Err(BadSealHeader(h))
    SealMalformedLine(n, t) => Err(SealMalformedLine(n, t))
    SealUnexpectedField(n, a, b) => Err(SealUnexpectedField(n, a, b))
    SealSchemeUnsupported(s) => Err(SealSchemeUnsupported(s))
    SealEmptyKey => Err(SealEmptyKey)
    SealBadKeyId(k) => Err(SealBadKeyId(k))
    SealDigestMismatch(a, b) => Err(SealDigestMismatch(a, b))
    SealMacMismatch(a, b) => Err(SealMacMismatch(a, b))
  }
  match outcome {
    Ok(text) => Ok(text)
    Err(e) => Err(e.message())
  }
}

///|
/// 解析印记文本。行序固定，键必须一一对上；不做"尽力而为"的容错。
pub fn parse_seal(text : String) -> Seal raise SealError {
  let text = normalize_newlines(text)
  let lines : Array[String] = []
  for raw in text.split("\n") {
    let line = raw.trim()
    if line.length() > 0 {
      lines.push(line.to_owned())
    }
  }
  if lines.length() != 5 {
    raise SealMalformedLine(
      lines.length(),
      "expected exactly 5 lines (header + scheme + key_id + digest + seal)",
    )
  }
  if lines[0] != "tally-seal v1" {
    raise BadSealHeader(lines[0])
  }
  let expected = ["scheme", "key_id", "digest", "seal"]
  let mut scheme = ""
  let mut key_id = ""
  let mut digest_sha = ""
  let mut seal = ""
  for i = 1; i < 5; i = i + 1 {
    let parts = split_spaces(lines[i])
    if parts.length() != 2 {
      raise SealMalformedLine(i + 1, lines[i])
    }
    if parts[0] != expected[i - 1] {
      raise SealUnexpectedField(i + 1, expected[i - 1], parts[0])
    }
    if i == 1 {
      scheme = parts[1]
    } else if i == 2 {
      key_id = parts[1]
    } else if i == 3 {
      digest_sha = parts[1]
    } else {
      seal = parts[1]
    }
  }
  if scheme != "hmac-sha256" {
    raise SealSchemeUnsupported(scheme)
  }
  if key_id == "" {
    raise SealMalformedLine(3, "empty key_id (use `-`)")
  }
  if digest_sha.length() != 64 || seal.length() != 64 {
    raise SealMalformedLine(4, "digest and seal must be 64 hex chars")
  }
  { scheme, key_id, digest_sha, seal }
}

///|
/// 校验一对「摘要 + 印记」：摘要没被换、印记确实由同一把密钥对这份摘要盖出。
pub fn verify_seal_pair(
  digest_text : String,
  seal_text : String,
  key : String,
) -> Unit raise SealError {
  if key == "" {
    raise SealEmptyKey
  }
  let seal = parse_seal(seal_text)
  let normalized = normalize_newlines(digest_text)
  let actual_digest_sha = sha256_hex(@utf8.encode(normalized))
  if actual_digest_sha != seal.digest_sha {
    raise SealDigestMismatch(seal.digest_sha, actual_digest_sha)
  }
  let actual_seal = hmac_sha256_hex(@utf8.encode(key), @utf8.encode(signing_text(seal)))
  if actual_seal != seal.seal {
    raise SealMacMismatch(seal.seal, actual_seal)
  }
}

///|
/// 给 CLI / 日志用的可读消息，位置与两个 hex 都保留在字符串里。
pub fn SealError::message(self : SealError) -> String {
  match self {
    BadSealHeader(h) => "unrecognised seal header: " + h
    SealMalformedLine(n, t) => "seal line " + n.to_string() + ": malformed: " + t
    SealUnexpectedField(n, expected, actual) =>
      "seal line " +
      n.to_string() +
      ": expected `" +
      expected +
      "`, got `" +
      actual +
      "`"
    SealSchemeUnsupported(s) => "unsupported seal scheme: " + s
    SealEmptyKey => "seal key must not be empty"
    SealBadKeyId(k) => "seal key_id must not contain whitespace: " + k
    SealDigestMismatch(expected, actual) =>
      "seal digest mismatch: seal says " + expected + ", file is " + actual
    SealMacMismatch(expected, actual) =>
      "seal mismatch: seal says " + expected + ", recomputed " + actual
  }
}

///|
/// 不 `raise` 的校验通道：理由同 `verify_report`（suberror 构造器不能经门面再导出）。
pub fn verify_seal(
  digest_text : String,
  seal_text : String,
  key : String,
) -> Result[Unit, String] {
  let err : SealError? = try {
    verify_seal_pair(digest_text, seal_text, key)
    None
  } catch {
    BadSealHeader(h) => Some(BadSealHeader(h))
    SealMalformedLine(n, t) => Some(SealMalformedLine(n, t))
    SealUnexpectedField(n, a, b) => Some(SealUnexpectedField(n, a, b))
    SealSchemeUnsupported(s) => Some(SealSchemeUnsupported(s))
    SealEmptyKey => Some(SealEmptyKey)
    SealBadKeyId(k) => Some(SealBadKeyId(k))
    SealDigestMismatch(a, b) => Some(SealDigestMismatch(a, b))
    SealMacMismatch(a, b) => Some(SealMacMismatch(a, b))
  }
  match err {
    None => Ok(())
    Some(e) => Err(e.message())
  }
}
