// 计数路径必须与编码路径给出同一个数字。
//
// `vocab` 的 `count`/`count_bytes` 现在走 `encode_count`（不分配 id 数组）；
// 这条测试保证"只计数"与"真编码再取 length"永远等价，包括特殊 token 的
// 首字节快路径与非法 UTF-8。

///|
test "count matches encode length" {
  let eot = @utf8.encode("<|eot|>")
  let views : Array[VocabView] = [
    byte_only_view(),
    view_with([@utf8.encode("he"), @utf8.encode("hel"), @utf8.encode("hello")], []),
    view_with([@utf8.encode("ing")], [(eot, 256)]),
  ]
  let inputs : Array[Bytes] = [
    Bytes::new(0),
    bytes_of([0x68, 0x69]),
    @utf8.encode("hello world"),
    @utf8.encode("中文 emoji 🎉 mixed\n\n\t end  "),
    bytes_of([0xFF, 0xFE, 0x00, 0x80]),
    @utf8.encode("<|eot|>"),
    @utf8.encode("a<|eot|>b<|eot|>"),
    // 首字节命中但整串不匹配：不能被"首字节过滤"吞掉
    @utf8.encode("a<|eo b<|eoz|>c<|eot"),
  ]
  for v in views {
    for input in inputs {
      assert_eq(encode_count(v, input), encode(v, input).length())
      assert_eq(count_ordinary(v, input), encode_ordinary(v, input).length())
    }
  }
}
