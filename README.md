# tally

> **精确的分词与上下文预算**——把「猜 token」变成「数 token」。

MoonBit 的 LLM 应用里，token 数通常靠「字符数 ÷ 常数」估算，误差可达 30%+。
`tally` 提供可以**逐 token 对齐参考实现**、**离线复算**、**跨后端字节一致**的精确值，
并在此之上回答「上下文放不下时，该丢哪一段、为什么」。

```moonbit
let v = @tally.load(vocab_text)          // 词表只加载一次，之后不可变
let n = @tally.count(v, "hello world")   // 精确 token 数：2
let ids = @tally.encode(v, @utf8.encode("hello world"))  // [259, 264]
```

---

## 它是什么

四层结构，一层一个包，依赖方向单向：

| 层 | 包 | 职责 | 依赖 |
|---|---|---|---|
| 算法内核 | `bpe` | 词表无关的 byte-level BPE 编码/解码、预切分扫描器、Unicode 属性表 | 仅 `core` |
| 词表 | `vocab` | 词表模型、加载（含自写 base64）、规范文本导出 | `bpe` + `core` |
| 预算 | `budget` | 上下文装配与截断，输出可解释的丢弃报告 | `bpe` |
| 门面 | `tally`（根包） | `encode` / `count` / `fit` 的最短路径 | 以上三层 |
| 工具 | `cmd/main` | CLI（唯一有 IO 的地方） | `x/fs` |

**核心包零第三方依赖**；`moonbitlang/x` 只被 `cmd/main` 用于读写文件。

## 设计目标（每条都有代码与测试对应）

1. **词表无关的 BPE 框架**——编码器不绑定任何一家词表。同一套算法既吃自带夹具，
   也吃公开词表文件（`.tiktoken` 风格，仅作兼容性输入，其代码一行未搬）。
2. **可复现的词表训练**——给定语料与参数，两次训练产出**逐字节相同**的词表；
   合并冲突的 tie-break 规则显式写进规范。（路线图 V0.3）
3. **预算化装配（budget-aware assembly）**——把上下文窗口当一等公民：优先级模型、
   截断点选择、以及「丢了哪段、丢了多少 token、为什么是它」的报告。
4. **自建 Unicode 属性表**（隐性原创点）——`core` 没有 `\p{L}` 等价物，
   因此属性表由 `tools/gen_unicode.py` 离线生成并冻结，既是工作量也是「从零实现」的物证。

## 快速开始

### 作为库

```powershell
moon add weopqrst/tally   # 发布到 mooncakes 后可用
```

```moonbit
fn demo(vocab_text : String, segments : Array[@tally.Segment]) -> Unit raise {
  // 加载词表（自有规范文本格式，见下）；加载后不可变
  let v = @tally.load(vocab_text)

  // 精确计数
  println(@tally.count(v, "it's a test"))

  // 编码 / 解码：任意字节序列都可编码，解码后逐字节还原
  let ids = @tally.encode(v, @utf8.encode("hello world"))
  println(@tally.decode(v, ids))

  // 逐片明细：哪一段在吃 token
  for piece in @tally.piece_counts(v, @utf8.encode("hello there token")) {
    println(piece)
  }

  // 上下文装配：按优先级截断 + 可解释的丢弃报告
  println(@tally.fit(v, segments, 4096L).render())
}
```

### CLI

```powershell
# 计数
moon run cmd/main --target js -- count --vocab tests/golden/sample-vocab.txt --text "hello world"

# 逐片明细（哪段在吃 token）
moon run cmd/main --target js -- count --vocab tests/golden/sample-vocab.txt --text "hello there token" --explain

# 编码为 id 序列
moon run cmd/main --target js -- encode --vocab tests/golden/sample-vocab.txt --text "hello world"

# 预算装配（Pinned 段保护 + 丢弃报告）
moon run cmd/main --target js -- fit --vocab tests/golden/sample-vocab.txt --limit 5 --text "hello world hello world"
```

`--file <f>` 可替代 `--text <s>`（按字节读取，不假设 UTF-8 合法）。

## 词表格式

自有规范文本格式 `tally-vocab v1`，可 diff、可指纹，`id` 与 `rank` 显式分开且 `id` 必须稠密升序：

```text
# tally-vocab v1
# unicode 17.0.0
# tokens 277
[specials]
276 PHxlbmRvZnRleHR8Pg==
[tokens]
0 0 AA==
...
```

`load` / `to_text` 满足：`load(to_text(v))` 与 `v` 内容等价，且同一个 `v` 的导出**逐字节稳定**。

### 格式冻结（`FORMAT.lock`）

两种对外文本格式都被逐字节钉死：

| 格式 | 内容 | 冻结在哪 |
|---|---|---|
| `tally-vocab v1` | 词表规范文本（`vocab/export.mbt`） | `vocab/format_lock_wbtest.mbt` + `tests/golden/sample-vocab.txt` |
| `tally-plan v1` | 预算计划报告（`budget/report.mbt`） | `format_lock_wbtest.mbt` + `tests/golden/sample-plan*.txt` |

`FORMAT.lock` 记录每个样本的**字节数与 sha256**；`python tools/gen_format_lock.py --check`
在样本或指纹对不上时失败。改格式实现会先让 MoonBit 测试变红，改样本会先让 `--check` 变红
——两条路都不允许「悄悄漂移」。

## 非目标

- 不是某个库的 MoonBit 版。公开词表文件只作**验证语料与兼容性输入**。
- 不做通用正则引擎——只为**固定的一条**预切分模式手写扫描器。
- 不做 BPE 之外的分词算法（WordPiece / Unigram 留给 1.x）。
- 不做 LLM 客户端、向量检索、GUI / 文档站、服务端。

## 已知边界

| 边界 | 说明 |
|---|---|
| 预切分模式 | 只实现 cl100k 形状的 7 分支模式；换模式需改扫描器 |
| Unicode 版本 | 属性表基于 **17.0.0**（`unicode_version()` 可查）。表由 `tools/gen_unicode.py` 从 `regex` 模块的属性表导出，**与参考实现同一引擎**，因此不是"近似"，而是逐码点一致 |
| `o200k` 类编码 | 需要 `Lu/Lt/Lm/Lo/M` 类别，未支持（见路线图 V0.8） |
| 训练 | 尚未实现（路线图 V0.3）；当前词表由 `tools/gen_sample_vocab.py` 确定性生成 |
| 缓存 | 尚未实现（路线图 V0.4）；当前每次编码都重算 |

## 开发

```powershell
# 双后端检查与测试（两侧必须全绿且结果一致）
moon check --target wasm-gc
moon check --target js
moon test  --target wasm-gc
moon test  --target js

# 生成物：改动后重新生成并提交
python tools/gen_unicode.py            # Unicode 属性表
python tools/gen_sample_vocab.py       # 测试夹具词表
python tools/gen_pretoken_golden.py    # 预切分 golden
python tools/gen_alignment_golden.py   # 逐 token 对齐 golden
python tools/gen_format_lock.py        # FORMAT.lock 指纹

# CI：生成物 / 指纹对不上就失败
python tools/gen_unicode.py --check
python tools/gen_sample_vocab.py --check
python tools/gen_pretoken_golden.py --check
python tools/gen_alignment_golden.py --check
python tools/gen_format_lock.py --check
```

当前规模：**6 个包、49 项测试**，`wasm-gc` 与 `js` 双后端全绿；
矩阵 A 与参考实现逐 token 对齐 **2,935 条语料**（16,273 个 token，差异 0）。

## 许可

Apache-2.0，见 [LICENSE](./LICENSE)。第三方依赖、参考实现声明与 Unicode 数据许可见 [NOTICE](./NOTICE)。
