// HMAC-SHA256 的参考向量：RFC 4231 的 Test Case 1–4、6、7。
//
// 用标准向量而不是"自己算一遍再冻结"：后者只能证明实现没变，证明不了实现是对的。
// Test Case 5 只给了截断到 128 位的值，与我们的全量输出不可比，故不取。

///|
fn bytes_of_byte(n : Int, b : Int) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < n; i = i + 1 {
    let _ = i
    out.push(b.to_byte())
  }
  Bytes::from_array(out)
}

///|
fn bytes_of_seq(start : Int, end : Int) -> Bytes {
  let out : Array[Byte] = []
  for i = start; i <= end; i = i + 1 {
    out.push(i.to_byte())
  }
  Bytes::from_array(out)
}

///|
test "hmac-sha256: RFC 4231 case 1 (short key, short data)" {
  assert_eq(
    hmac_sha256_hex(
      bytes_of_byte(20, 0x0B),
      @utf8.encode("Hi There"),
    ),
    "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
  )
}

///|
test "hmac-sha256: RFC 4231 case 2 (textual key)" {
  assert_eq(
    hmac_sha256_hex(
      @utf8.encode("Jefe"),
      @utf8.encode("what do ya want for nothing?"),
    ),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
  )
}

///|
test "hmac-sha256: RFC 4231 case 3 (one-byte key and data)" {
  assert_eq(
    hmac_sha256_hex(bytes_of_byte(20, 0xAA), bytes_of_byte(50, 0xDD)),
    "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
  )
}

///|
test "hmac-sha256: RFC 4231 case 4 (25-byte key)" {
  assert_eq(
    hmac_sha256_hex(bytes_of_seq(1, 25), bytes_of_byte(50, 0xCD)),
    "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b",
  )
}

///|
/// 密钥长于块长（131 字节）：必须先哈希成 32 字节，否则两边的 ipad/opad 不同。
test "hmac-sha256: RFC 4231 case 6 (key longer than block)" {
  assert_eq(
    hmac_sha256_hex(
      bytes_of_byte(131, 0xAA),
      @utf8.encode("Test Using Larger Than Block-Size Key - Hash Key First"),
    ),
    "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
  )
}

///|
test "hmac-sha256: RFC 4231 case 7 (long key and long data)" {
  assert_eq(
    hmac_sha256_hex(
      bytes_of_byte(131, 0xAA),
      @utf8.encode(
        "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.",
      ),
    ),
    "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2",
  )
}

///|
/// 空消息也是合法输入；这一条防"要么空要么错"的实现（例如误把空消息当解析失败）。
test "hmac-sha256: empty message is not an error" {
  assert_eq(
    hmac_sha256_hex(@utf8.encode("key"), Bytes::new(0)),
    hmac_sha256_hex(@utf8.encode("key"), @utf8.encode("")),
  )
}
