// base64 的 RFC 4648 测试向量（这是"规范形式"能被信任的唯一依据）。

///|
fn bytes_of(values : Array[Int]) -> Bytes {
  let out : Array[Byte] = []
  for v in values {
    out.push(v.to_byte())
  }
  Bytes::from_array(out)
}

///|
test "base64 RFC 4648 vectors" {
  assert_eq(b64_encode(Bytes::new(0)), "")
  assert_eq(b64_encode(bytes_of([0x66])), "Zg==")
  assert_eq(b64_encode(bytes_of([0x66, 0x6F])), "Zm8=")
  assert_eq(b64_encode(bytes_of([0x66, 0x6F, 0x6F])), "Zm9v")
  assert_eq(b64_encode(bytes_of([0x66, 0x6F, 0x6F, 0x62])), "Zm9vYg==")
  assert_eq(b64_encode(bytes_of([0x66, 0x6F, 0x6F, 0x62, 0x61])), "Zm9vYmE=")
  assert_eq(b64_encode(bytes_of([0x66, 0x6F, 0x6F, 0x62, 0x61, 0x72])), "Zm9vYmFy")
}

///|
test "base64 round trip over all single bytes and sampled groups" {
  for b = 0; b < 256; b = b + 1 {
    let one = bytes_of([b])
    assert_true(b64_decode(b64_encode(one)) == one)
    let two = bytes_of([b, 255 - b])
    assert_true(b64_decode(b64_encode(two)) == two)
    let three = bytes_of([b, 255 - b, b])
    assert_true(b64_decode(b64_encode(three)) == three)
  }
}

///|
test "base64 rejects invalid characters" {
  let caught = try {
    let _ = b64_decode("Zm9v!")
    "none"
  } catch {
    InvalidBase64(_) => "invalid"
    _ => "other"
  }
  assert_eq(caught, "invalid")
}
