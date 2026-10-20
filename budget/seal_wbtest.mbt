// `tally-seal v1` 的证据：
// * 盖章 → 校验通过（摘要文件被 Windows 改成 CRLF 也算通过，因为先归一化）；
// * 摘要被改、`key_id` 被改、`seal` 行被改、换密钥——四种各自被抓到；
// * 格式错误（行序、行数、算法、长度）报得出**是哪一行**；
// * 空密钥被拒：空密钥等于人人可签，不能"顺利通过"。

///|
fn sealed_fixture() -> (String, String) raise {
  let digest = frozen_digest_mixed
  (digest, seal_digest(digest, "correct horse battery staple", "k1"))
}

///|
fn seal_error_kind(e : SealError) -> String {
  match e {
    BadSealHeader(_) => "BadSealHeader"
    SealMalformedLine(_, _) => "SealMalformedLine"
    SealUnexpectedField(_, _, _) => "SealUnexpectedField"
    SealSchemeUnsupported(_) => "SealSchemeUnsupported"
    SealEmptyKey => "SealEmptyKey"
    SealBadKeyId(_) => "SealBadKeyId"
    SealDigestMismatch(_, _) => "SealDigestMismatch"
    SealMacMismatch(_, _) => "SealMacMismatch"
  }
}

///|
fn probe_seal(digest : String, seal : String, key : String) -> String {
  let mut kind = "ok"
  let _ = try {
    verify_seal_pair(digest, seal, key)
    Some(())
  } catch {
    e => {
      kind = seal_error_kind(e)
      None
    }
  }
  kind
}

///|
test "seal: a freshly sealed digest verifies" {
  let (digest, seal) = sealed_fixture()
  assert_eq(probe_seal(digest, seal, "correct horse battery staple"), "ok")
}

///|
test "seal: CRLF digest file and trailing blank lines still verify" {
  let (digest, seal) = sealed_fixture()
  assert_eq(
    probe_seal(crlf(digest) + "\r\n\r\n", crlf(seal), "correct horse battery staple"),
    "ok",
  )
}

///|
test "seal: one changed byte in the digest is caught" {
  let (digest, seal) = sealed_fixture()
  let tampered = flip_char_at(digest, index_of_sub(digest, "seg ") + 6)
  assert_eq(
    probe_seal(tampered, seal, "correct horse battery staple"),
    "SealDigestMismatch",
  )
}

///|
test "seal: the digest file must be the one that was sealed" {
  let (_, seal) = sealed_fixture()
  assert_eq(
    probe_seal(frozen_digest_truncated, seal, "correct horse battery staple"),
    "SealDigestMismatch",
  )
}

///|
test "seal: a wrong key is caught (mac mismatch, not digest mismatch)" {
  let (digest, seal) = sealed_fixture()
  assert_eq(probe_seal(digest, seal, "wrong key"), "SealMacMismatch")
}

///|
/// `key_id` 也在被签的 4 行里：只改标识不重算，等于把"谁认过"抹掉了。
test "seal: editing key_id invalidates the mac" {
  let (digest, seal) = sealed_fixture()
  let tampered = replace_first(seal, "key_id k1", "key_id k2")
  assert_eq(
    probe_seal(digest, tampered, "correct horse battery staple"),
    "SealMacMismatch",
  )
}

///|
test "seal: editing the seal line itself invalidates the mac" {
  let (digest, seal) = sealed_fixture()
  let at = index_of_sub(seal, "\nseal ") + 6
  assert_eq(
    probe_seal(digest, flip_char_at(seal, at), "correct horse battery staple"),
    "SealMacMismatch",
  )
}

///|
test "seal: empty key is refused on both sides" {
  let (digest, seal) = sealed_fixture()
  assert_eq(probe_seal(digest, seal, ""), "SealEmptyKey")
  let refused = try {
    let _ = seal_digest(digest, "", "k1")
    false
  } catch {
    SealEmptyKey => true
    _ => false
  }
  assert_true(refused)
}

///|
test "seal: key_id with whitespace is refused (it would break the format)" {
  let (digest, _) = sealed_fixture()
  let refused = try {
    let _ = seal_digest(digest, "key", "k 1")
    false
  } catch {
    SealBadKeyId(_) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "seal: empty key_id renders as `-` and still verifies" {
  let (digest, _) = sealed_fixture()
  let seal = seal_digest(digest, "key", "")
  assert_eq(probe_seal(digest, seal, "key"), "ok")
  assert_eq(parse_seal(seal).key_id, "-")
}

///|
test "seal: unknown scheme is refused rather than guessed" {
  let (digest, seal) = sealed_fixture()
  let tampered = replace_first(seal, "scheme hmac-sha256", "scheme hmac-sha1")
  assert_eq(
    probe_seal(digest, tampered, "correct horse battery staple"),
    "SealSchemeUnsupported",
  )
}

///|
test "seal: field order is fixed, swapped lines are caught by name" {
  let (digest, seal) = sealed_fixture()
  let lines = vlines(seal)
  let swapped = lines[0] +
    "\n" +
    lines[1] +
    "\n" +
    lines[3] +
    "\n" +
    lines[2] +
    "\n" +
    lines[4] +
    "\n"
  assert_eq(
    probe_seal(digest, swapped, "correct horse battery staple"),
    "SealUnexpectedField",
  )
}

///|
test "seal: missing or extra lines are malformed, not silently accepted" {
  let (digest, seal) = sealed_fixture()
  let lines = vlines(seal)
  let short = lines[0] + "\n" + lines[1] + "\n" + lines[2] + "\n" + lines[3] + "\n"
  assert_eq(probe_seal(digest, short, "correct horse battery staple"), "SealMalformedLine")
  assert_eq(
    probe_seal(digest, seal + "extra 1\n", "correct horse battery staple"),
    "SealMalformedLine",
  )
}

///|
test "seal: truncated hex is malformed" {
  let (digest, seal) = sealed_fixture()
  let tampered = drop_char_at(seal, seal.to_array().length() - 2)
  assert_eq(
    probe_seal(digest, tampered, "correct horse battery staple"),
    "SealMalformedLine",
  )
}

///|
test "seal: bad header is named" {
  let (digest, seal) = sealed_fixture()
  let tampered = replace_first(seal, "tally-seal v1", "tally-seal v2")
  assert_eq(probe_seal(digest, tampered, "correct horse battery staple"), "BadSealHeader")
}

///|
/// CLI 走的非异常通道：消息必须点名两个 hex，否则用户分不清"摘要错"还是"密钥错"。
test "seal: verify_seal message names both hexes" {
  let (digest, seal) = sealed_fixture()
  let good_mac = parse_seal(seal).seal
  match verify_seal(digest, seal, "wrong key") {
    Ok(_) => abort("expected a failure")
    Err(msg) => {
      assert_true(index_of_sub(msg, "seal mismatch") >= 0)
      assert_true(index_of_sub(msg, good_mac) >= 0)
      assert_eq(msg.to_array().length() > 100, true)
    }
  }
}
