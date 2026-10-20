// 格式冻结（T6）：`tally-seal v1` 的输出逐字节钉死。
//
// 参考值不是"跑一遍实现再抄下来"——那样只能证明实现没变，证明不了实现是对的。
// 这一枚由 Python 的 `hashlib` + `hmac` 对**同一份摘要**（`frozen_digest_mixed`）
// 与**同一把 key**（`ci-key`，`key_id ci`）独立算出，两条路算到同一个 hex。
//
// 生成 `FORMAT.lock` 的脚本从本文件抽这个常量。

///|
let frozen_seal_mixed : String =
  "tally-seal v1\n" +
  "scheme hmac-sha256\n" +
  "key_id ci\n" +
  "digest 3e8f5ace11c2a7824653fb0e43e4824e970b6fc370d29782922a63061134f155\n" +
  "seal c9273313d04bfe7c00c037618379d1bb7fea4634de58e543fa6835e7ce13f503\n"

///|
test "format lock: tally-seal v1 (hmac-sha256, key_id ci)" {
  assert_eq(seal_digest(frozen_digest_mixed, "ci-key", "ci"), frozen_seal_mixed)
}

///|
/// 解析回来必须逐字段对得上：格式冻结不只是"渲染一致"，也包括"读回来是同一件事"。
test "format lock: tally-seal v1 parses back to the same fields" {
  let seal = parse_seal(frozen_seal_mixed)
  assert_eq(seal.scheme, "hmac-sha256")
  assert_eq(seal.key_id, "ci")
  assert_eq(
    seal.digest_sha,
    "3e8f5ace11c2a7824653fb0e43e4824e970b6fc370d29782922a63061134f155",
  )
  assert_eq(
    seal.seal,
    "c9273313d04bfe7c00c037618379d1bb7fea4634de58e543fa6835e7ce13f503",
  )
  verify_seal_pair(frozen_digest_mixed, frozen_seal_mixed, "ci-key")
}
