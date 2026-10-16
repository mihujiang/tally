// 格式冻结（T5）：`tally-train v1` 的**输出格式**逐字节钉死。
//
// 这份冻结串不是手写的，而是**真实训练**（`vocab/train.mbt`）在固定配方下的
// 产物：语料 `train_corpus`、`vocab_size = 280`、`min_frequency = 2`、
// 一个特殊 token `<|endoftext|>`。它同时钉住三件事：
//
//   * 格式形状：头部字段顺序、`[merges]` 在 `[specials]` 之前、行尾 `\n`；
//   * 训练结果：合并序列与顺序（即 tie-break 规则）真的没变；
//   * `# unicode` 行跟真实版本一致（版本升级会让这里变红——这正是目的）。
//
// `# tokens` 与 base64 是派生字段，改实现先红的是这里的断言，
// 再由 `tools/gen_format_lock.py` 把同一串落成 `tests/golden/sample-train.txt` 求指纹。
// 随包分发：使用方可以自己复跑这些断言。

///|
let frozen_train_artifact : String =
  "# tally-train v1\n" +
  "# unicode 17.0.0\n" +
  "# corpus_bytes 180\n" +
  "# corpus_words 43\n" +
  "# vocab_size 280\n" +
  "# min_frequency 2\n" +
  "# tokens 280\n" +
  "[merges]\n" +
  "256 MTI= MQ== Mg==\n" +
  "257 aW4= aQ== bg==\n" +
  "258 ICA= IA== IA==\n" +
  "259 IGE= IA== YQ==\n" +
  "260 MTIz MTI= Mw==\n" +
  "261 6K8= 6A== rw==\n" +
  "262 DQo= DQ== Cg==\n" +
  "263 IGk= IA== aQ==\n" +
  "264 IHQ= IA== dA==\n" +
  "265 IHc= IA== dw==\n" +
  "266 IGFu IGE= bg==\n" +
  "267 IGFuZA== IGFu ZA==\n" +
  "268 IHdv IHc= bw==\n" +
  "269 IHdvcg== IHdv cg==\n" +
  "270 IHdvcmw= IHdvcg== bA==\n" +
  "271 IHdvcmxk IHdvcmw= ZA==\n" +
  "272 ZWw= ZQ== bA==\n" +
  "273 ZWxs ZWw= bA==\n" +
  "274 ZWxsbw== ZWxs bw==\n" +
  "275 aGVsbG8= aA== ZWxsbw==\n" +
  "276 aW5n aW4= Zw==\n" +
  "277 huiv hg== 6K8=\n" +
  "278 huivjQ== huiv jQ==\n" +
  "[specials]\n" +
  "279 PHxlbmRvZnRleHR8Pg==\n"

///|
/// 真实训练的产物必须逐字节等于冻结串：格式或规则漂移在这里先红。
test "train lock: real training reproduces the frozen artifact byte for byte" {
  let r = train(train_corpus, 280, 2, ["<|endoftext|>"])
  assert_eq(r.to_text(), frozen_train_artifact)
}

///|
/// 再走一轮：回读 -> 再导出仍逐字节相同。
/// 单轮相等可能是巧合（两边都漏了同一行），两轮才能排除。
test "train lock: the frozen artifact is a fixed point" {
  let once = load_train(frozen_train_artifact).to_text()
  assert_eq(once, frozen_train_artifact)
}
