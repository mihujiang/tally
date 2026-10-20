// SHA-256 的对齐证据：NIST FIPS 180-4 附录里的官方测试向量。
// 摘要一旦算错，"可验证"就变成"可伪造"，所以这里不做自证（不拿自己的输出当期望）。

///|
test "sha256: NIST vectors" {
  assert_eq(
    sha256_hex(Bytes::new(0)),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  assert_eq(
    sha256_hex(@utf8.encode("abc")),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  assert_eq(
    sha256_hex(
      @utf8.encode(
        "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
      ),
    ),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  )
  assert_eq(
    sha256_hex(
      @utf8.encode(
        "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
      ),
    ),
    "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
  )
}

///|
test "sha256: length padding boundaries" {
  // 55 / 56 / 63 / 64 / 65 字节是补位的边界：56 字节起要多吃一个块。
  let hashes : Array[String] = []
  for n in [0, 1, 55, 56, 63, 64, 65, 127, 128, 1000] {
    hashes.push(sha256_hex(Bytes::make(n, (0x61).to_byte())))
  }
  // 都是 64 位 hex，且长度不同的输入不撞车
  for h in hashes {
    assert_eq(h.length(), 64)
  }
  assert_true(hashes[2] != hashes[3])
  assert_true(hashes[4] != hashes[5])
  assert_true(hashes[6] != hashes[7])
  // 期望值来自独立实现（CPython hashlib），仍然不是自证。
  assert_eq(
    hashes[9],
    "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3",
  )
}

///|
/// NIST 的百万字符 `a` 向量：跨多个块的状态传递一旦错，这里必红。
test "sha256: NIST million-a vector" {
  assert_eq(
    sha256_hex(Bytes::make(1000000, (0x61).to_byte())),
    "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
  )
}

///|
/// 摘要的输出形状也是契约：64 位、小写 hex。大写或定长不对，
/// `tally-digest v1` 的段行就会被判定为格式错误。
test "sha256: output is 64 lowercase hex chars" {
  let h = sha256_hex(@utf8.encode("tally"))
  assert_eq(h.length(), 64)
  for c in h.to_array() {
    let v = c.to_int()
    let is_digit = v >= 0x30 && v <= 0x39
    let is_lower = v >= 0x61 && v <= 0x66
    assert_true(is_digit || is_lower)
  }
  // 改一个字符 -> 摘要不同（雪崩效应是摘要可用的前提）
  assert_true(
    sha256_hex(@utf8.encode("tally")) != sha256_hex(@utf8.encode("tallY")),
  )
}
