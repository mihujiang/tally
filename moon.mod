// tally — a verifiable context-assembly contract for MoonBit LLM apps.
// See https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "weopqrst/tally"

version = "0.8.1"

readme = "README.md"

repository = "https://github.com/mihujiang/tally"

license = "Apache-2.0"

keywords = ["context-window", "context-assembly", "verifiable", "truncation", "tokenizer", "llm"]

preferred_target = "wasm-gc"

description = "Verifiable context-assembly contract for MoonBit LLM apps: frozen report formats (tally-plan v3, tally-digest v1, tally-seal v1), pluggable counters, window/reserve model, priority + score assembly with per-pool quotas and placeholder compression, and reports a third party can re-assemble and compare byte for byte."

// 只有卫星包（cmd/main）使用 x/fs 做 IO、x/sys 设置退出码；核心包零第三方依赖。
import {
  "moonbitlang/x@0.5.5",
}
