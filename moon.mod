// tally — precise tokenization and context budgeting for MoonBit LLM apps.
// See https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "weopqrst/tally"

version = "0.3.0"

readme = "README.md"

repository = "https://github.com/mihujiang/tally"

license = "Apache-2.0"

keywords = ["tokenizer", "bpe", "llm", "unicode", "context"]

preferred_target = "wasm-gc"

description = "Byte-level BPE tokenization and context budgeting with reproducible, byte-exact results."

// 只有卫星包（cmd/main）使用 x/fs 做 IO；核心包零第三方依赖。
import {
  "moonbitlang/x@0.5.5",
}
