// tally — precise tokenization and context budgeting for MoonBit LLM apps.
// See https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "weopqrst/tally"

version = "0.8.0"

readme = "README.md"

repository = "https://github.com/mihujiang/tally"

license = "Apache-2.0"

keywords = ["context-window", "budget", "truncation", "tokenizer", "llm"]

preferred_target = "wasm-gc"

description = "Context-budget engine for MoonBit LLM apps: pluggable counters, window/reserve model, priority + score assembly with per-pool quotas and placeholder compression, and explainable, reproducible, verifiable, sealable reports (tally-plan v3 + tally-digest + tally-seal)."

// 只有卫星包（cmd/main）使用 x/fs 做 IO、x/sys 设置退出码；核心包零第三方依赖。
import {
  "moonbitlang/x@0.5.5",
}
