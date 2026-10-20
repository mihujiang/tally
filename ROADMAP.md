# tally 路线图

> **定位（2026-10-19 换轴 + 加权重排）**：tally 是 **MoonBit 的上下文预算引擎**——把任意长度的上下文精确压进 token 预算，并给出**可复现、可 diff** 的丢弃 / 截断报告。cl100k 分词是**底座**，「确定性 + 可核对」是**质量标签**，都不是卖点。
>
> 主线：**0.3.1 收口 → 0.4.0 预算引擎 → 0.5.0 示例 → 0.6.0 稳健与冻结 → 0.7.0 基准 → 1.0.0**。
> 预算层是**产品本体**，从 0.4.0 起就是第一屏、CLI 第一个子命令、README 第一段。

---

## 方向决策记录（2026-10-19）

### 结论

放弃「通用 tokenizer 库」，改为「**上下文预算引擎 + 可插拔计数器**」。tokenizer 只保 cl100k 形状，不扩第二编码；训练（V0.3）冻结为能力证明。

### 依据：mooncakes 3,109 模块全量筛选，相关的只有 5 个

| 包 | 版本 / 首发 | 下载 | 已覆盖 | 缺口 |
|---|---|---|---|---|
| `howtomakeaname/tokenizers-moonbit` | 0.16.3 / 2026-09-29 | **472** | BPE / byte-level / WordPiece / Unigram，39 模型对拍 HF 0.22.2，四后端含 native，真 trainer，`save_pretrained` | **不做 `.tiktoken`、不做预算层、不做格式冻结** |
| `tonyfettes/tiktoken` | 0.2.1 / 2025-11-12 | 97 | tiktoken 同形状引擎 | `pcre2` = C FFI，实际只能 native；无 `from_file`；仓库 404；11 个月未更新 |
| `Milky2018/minigpt` | 0.1.2 / 2026-09-07 | 41 | char-level BPE + 玩具 `train` | 无字节级、无 tie-break、无冻结 |
| `DC-Z-lab/moonllm` | 0.1.0 | — | 4 字符/token 估算 + 会话裁剪 | 不是精确 token，无报告 |
| `niuniu513-ask/MoonRetrieve` | 0.6.0 | — | RAG 内按预算拼片段 | 面向检索，非通用预算层 |
| **`weopqrst/tally`** | 0.1.0 / 2026-10-14 | 5 | cl100k + 2,935 条对拍 + 全序 tie-break + 可解释预算 + `FORMAT.lock` | 无 native、无 o200k、无 benchmark |

（`lllg123/mooncontext`：字符门禁 + 审计报告，明确不做 token、不截断，互补；`moonbitlang/maria` 有 cl100k/o200k 但未上架，不构成包层面竞争。）

### 为什么预算层必须排到最前

1. **编码层重合已被证明**：对手 39 模型 × 4 后端 × 真 trainer，继续投最好也只是追平。
2. **预算层无人做**：生态里只有估算（`moonllm`）、字符门禁（`mooncontext`）、检索内拼装（`MoonRetrieve`）。
3. **组合护城河**：精确计数 + 优先级 + Pinned 原子性 + 报告冻结，单看任一环平淡，四环串起来没有第二家。
4. **`Counter` 把竞争变插座**：预算层不依赖我们的词表后，可以拿对手的 tokenizer 计数、用我们的引擎裁剪——我们是下游，不是替代品。
5. **它是 agent 的必然事件**：上下文溢出发生在每次调用之前，不是边界情况。

### 砍掉

| 项 | 原版本 | 理由 |
|---|---|---|
| o200k 第二编码 | 原 V0.8 | 纯成本零差异化，对手已覆盖并跑完 39 模型 |
| LRU 缓存 + 性能优化目标 | 原 V0.4 | 4k–128k token 场景不是 CPU 瓶颈；只给诚实数字 |
| 测试数 ≥320 等指标 | 原 V0.10 | 为指标而指标，改为「被真实依赖」 |
| 训练继续扩展 | — | V0.3 已闭环，冻结 |

### 重排映射

| 原 | 新 |
|---|---|
| V0.6 预算层深化 | **V0.4**（扩为完整引擎） |
| V0.7 示例与文档 | **V0.5** |
| V0.5 格式冻结 + V0.9 稳健性 | **V0.6** |
| V0.4 基准 | **V0.7**（后移，最后才谈速度） |
| V0.8 第二编码 | **砍** |

**0.8.0 / 0.9.0 不再发布**；原文保留在文末归档节。

### 决策检查点（kill-switch）

> **0.5.0 发布后 30 天内无外部依赖信号**（README / issue / 下游 `moon.mod` 引用）→ 转维护模式，只修 bug。**不因为已经做了这么多而继续投入。**

---

## 已完成

| 版本 | 关键交付 | 证据 |
|---|---|---|
| V0.1 / 0.1.0 | 对齐 654 条、Unicode 全码点比对、预切分一致、双后端逐字节一致、两类格式冻结 | 49 测试；2026-10-14 发布 |
| V0.2 / 0.2.0 | 矩阵 A 全量 **2,935 条 / 16,273 token**（tiktoken 0.14.0 标注）；往返 550 组；无 OOV | golden 入库带参考版本号 |
| V0.3 / 0.3.0 | 全序 tie-break（频次降 → `left` 升 → `right` 升）；`tally-train v1` 冻结；训练→导出→回读为不动点 | 65 测试双后端全绿；2026-10-19 发布 |
| 0.3.1 | **定位切换为上下文预算引擎**：README / `moon.mod` / CLI 一致；门面补 `pinned`/`newest`/`middle`/`oldest`，单 import 可装配 | 67 测试双后端全绿（含 1 黑盒）；2026-10-19 发布，消费端 `moon run` 复验通过 |
| 0.4.0 | **预算引擎换轴**：`Counter` 解耦词表、窗口/预留模型、`KeepPrefix`/`KeepSuffix` 截断、`tally-plan v2` 进 `FORMAT.lock`；段带 `bytes` | 82 测试双后端全绿（含 3 黑盒：构造器 / 窗口截断 / 外部 Counter 字面量）；矩阵 G 168 组不变量通过；2026-10-19 发布，消费端 `moon run` 复验通过 |
| 0.4.1 | **0.4.0 检查修复**：`fit_with_result` + `FitError` 可命名、`estimate` 改按字符、`cl100k`/`fit` 上移门面（`budget` 包级不再依赖 `vocab`）、`Plan.excess`、CLI 参数校验、格式约束入文档 | 86 测试双后端全绿（含 5 黑盒）；`budget` import 表只剩 `core`；`FORMAT.lock` 未变；2026-10-19 发布，注册表 checksum 与本地构建包 sha256 一致，消费端 `moon run` 复验通过 |
| 0.5.0 | **示例与集成**：4 个可运行示例（100k→8k 日志、多轮历史、RAG 片段、外部 Counter）、英文 README、GitHub Actions CI；示例输出逐字节入库 | 87 测试双后端全绿；`tools/check_examples.py` 比对 4 示例 + 1 CLI 用例，输出可 diff；CI 在 GitHub 上 14 步全绿（run `39210330467`，commit `e07f759`）；2026-10-19 发布 0.5.0，注册表 `checksum=1fd77b1a…` 与本地构建包 sha256 一致 |
| 0.6.0 | **稳健性与可验证**：`tally-digest v1` 侧车（零依赖 SHA-256，FIPS 180-4 自实现）+ `verify` 两级校验（自洽 / 端到端复算）；矩阵 I（600 次随机变异，结果只能是成功或可命名错误）、矩阵 J（改一字节必失败并给位置）；第 5 类格式进 `FORMAT.lock`；CI 加 `verify` 两步 | 122 测试双后端全绿；`check_examples.py` 4 例（含 `verify` 失败演示，输出逐字节入库）；`gen_format_lock --check` 8 份样本差异 0；2026-10-20 完成，待发布 |

---

## 0.3.1 — 收口（立即）

**目标**：止血——线上仍是 0.1.0，README 还写「49 项测试 / 训练未实现」。

- [x] README 首段改为预算引擎定位；`fit` 提到主路径；加「与 `tokenizers-moonbit` 的分工」一节
- [x] 非目标与已知边界更新：不提供 o200k；截断粒度、窗口模型、后端范围写明
- [x] `moon.mod` 描述与 keywords 改为预算引擎
- [x] CLI `usage` 改为 `fit` 优先
- [x] 补 `Priority` 的 doc comment（文档页唯一空条目）
- [x] docgen `VocabVocab` 核实为**伪影**：页面 HTML 中 `VocabVocab` 出现 0 次、`>Vocab<` 26 次，
      重复只存在于纯文本抽取（链接 `title` + 链接文本拼接），不是渲染 bug，已撤销该条边界
- [x] 发布 0.3.0（2026-10-19，服务端 200 OK；API `latest_version=0.3.0`、`build_status=success`；
      消费端 `moon add` 复验通过）
- [x] **发现并修复门面缺口**：`pub using` 无法再导出枚举构造器，导致只 import `weopqrst/tally`
      的使用者**无法构造 `Segment`**（`@tally.Pinned` 报 4021），而 `fit` 是主路径。
      新增门面构造器 `pinned` / `newest` / `middle` / `oldest`，单 import 即可装配；
      补 1 项白盒 + 1 项黑盒测试（`facade_test.mbt` 只用公开 API，共 67）
- [x] 发布 0.3.1（2026-10-19，服务端 200 OK；API `latest_version=0.3.1`、`build_status=success`；
      文档页 README 已刷新：`上下文预算引擎` ×2、`67 项测试` ×2、旧「49 项测试」为 0；
      消费端新工程只 `import weopqrst/tally` 即完成 `pinned`/`oldest` + `fit`，`moon run` 通过）

**完成标准**：`moon publish --dry-run` 通过；版本号 / 测试数 / README 三者一致。

---

## V0.4 — 预算引擎换轴 `0.4.0` ★产品本体

**目标**：把 `budget` 从「按优先级丢段的雏形」变成真正的引擎，并解耦 tokenizer。

- [x] **`Counter`**：`{ name, exact, count_bytes }`，`budget` 只依赖它，不再依赖 `Vocab`（`budget/counter.mbt`）
      ——包级解耦 0.4.1 才补齐：`cl100k` 适配器搬到门面，`budget` 的 import 表只剩 `core`
- [x] 内置 `cl100k(v : Vocab)`（0.4.1 起在门面包），结果与原 `count_bytes` 逐 token 相等；
      另有 `estimate(n)` 标注 `exact=false`，估算不允许冒充精确
- [x] **窗口模型**：`window = reserve_output + input_limit`，`reserve >= window` 时 `raise ReserveExceedsWindow`
- [x] **截断策略**：`NoTruncate` / `KeepPrefix`（保留段首）/ `KeepSuffix`（保留段尾、即「最近优先」）。
      **不做** `KeepNewestN`：N 段保留属于会话策略，不是字节层职责，留给 V0.5 示例层
- [x] **Pinned 原子性**：永不裁；超限给可操作诊断而不是静默越界
- [x] **报告 v2（`tally-plan v2`）**：记录 counter 身份（name/exact）、每段动作（kept/truncated/dropped）、截断量
- [x] 向后兼容：`fit(v, segments, limit)` 保留为 shim，语义等同 `fit_with(FitConfig::new(cl100k, limit))`
      （0.4.1 起该 shim 在门面包，走 `budget::assemble`——它不校验 `limit > 0`，保住旧语义）
- [x] 矩阵 G：3 策略 × 4 段落形状 × limit 1..14 = 168 组，校验 used 守恒、`<= limit`、Pinned 不裁、截断量合法、渲染可复现

- [x] 发布 0.4.0（2026-10-19，服务端 200 OK；API `latest_version=0.4.0`、`build_status=success`；
      文档页 README 已刷新：`82 项测试` ×2、`fit_with` ×16、`tally-plan v1` 出现 0 次；
      消费端新工程只 `import weopqrst/tally` 即完成 `estimate` + `with_reserve` + `with_strategy` + `fit_with`，`moon run` 通过）

**完成标准**：`moon test` 双后端全绿（82 项）；shim 与新 API 的 `tally-plan` **逐字节相同**（`compat fit equals explicit config`）。

**实现说明（与原计划的三处偏离）**：
1. 策略名从 `TruncateTail/TruncateHead` 改为 `KeepPrefix/KeepSuffix`——原命名描述「砍哪头」，
   新命名描述「留哪头」，读调用点时不歧义；
2. 截断不需要 `encode`：切点靠 `Counter` 二分字节长度得到，因此**外部 tokenizer 也能被截断**；
3. `KeptSegment` / `TruncatedSegment` 现在直接带 `bytes`——否则「截短」只会计账、给不出可用内容。

---

## 0.4.1 — 0.4.0 检查修复 `0.4.1`

**目标**：把 0.4.0 发布后的检查结论修掉——错误通道、估算语义、包级解耦、可对账。

- [x] **错误可命名**：再导出 `type FitError`（`pub using` 能导出类型、导不出 suberror 构造器，
      `@tally.ReserveExceedsWindow` 仍报 4021）；新增 `fit_with_result` 把错误折成
      `Err((reserve, window))`——单 import 的使用者不靠错误类型名字也能分支
- [x] **估算按字符**：`estimate(n)` 从「字节 ÷ n」改为「Unicode 码点 ÷ n」向上取整。
      中文一字 3 字节，原实现会把预算放大 3 倍，与 README 批评的「字符数 ÷ 4」同病
- [x] **包级解耦**：`cl100k` 适配器与 `fit` shim 上移门面包，`budget` 的 import 表只剩 `core`
      （`vocab` 只出现在 `for "wbtest"`）；`budget::fit_impl` 更名为公开的 `assemble`（不校验配置）
- [x] **overflow 可对账**：`Plan` 增加 `excess`；渲染仍是 v2（哨兵行不变），
      格式文档写明 `index == -1` 的哨兵行，以及 `counter` / `role` 不得含空白
- [x] **CLI 参数校验**：非法 `--truncate` / `--limit` / `--reserve` 直接报错（此前静默回落成 none / 0）。
      已知限制：core 不提供退出码 API，`abort` 会带 JS 栈，所以目前只保证文案清楚、进程仍返回 0
- [x] README 勘误：`count` → `count_bytes`、错误处理示例、估算语义、格式约束
- [x] **发布 0.4.1**（2026-10-19，服务端 200 OK；注册表 `checksum=4abb4008…` 与本地
      `_build/publish/weopqrst-tally-0.4.1.zip` 的 sha256 **完全一致**；消费端 `moon add` 后
      `estimate` + `with_reserve` + `fit_with_result` + `Err((r, w))` + `plan.excess` 全部可用）
- [x] 发布后补第 87 项黑盒：锁住 `truncate_none/tail/head` 在**单 import** 下可选。
      0.4.0 的记录里「单 import 完成 with_strategy」一直只是文字，没有测试；这次探针
      误用 `@tally.KeepSuffix`（枚举构造器确实不可见，报 4021）才发现要锁的是 `truncate_*`

**完成标准**：`moon test` 双后端全绿（发布时 86 项，含 5 黑盒；补测后 87 项 / 6 黑盒）；
`gen_format_lock --check` 通过（v2 输出逐字节不变）；`moon info` 中 `budget` 的 import 表不含 `vocab`。

## V0.5 — 示例与集成 `0.5.0`（已完成）

- [x] ① 100k token → 8k：输出丢弃/截断报告 ② 多轮历史（pinned 系统提示不丢） ③ RAG 片段拼装
      —— 落在 `cmd/examples/`（`big-input` / `multi-turn` / `rag`），另加第 4 个：外部 tokenizer
- [x] 文档级适配 `tokenizers-moonbit`（片段 + 用例，**不引入依赖**，守住核心零依赖）
      —— README 的 `Counter` 片段 + `foreign-counter` 示例（外部类型不写 `impl`，也不加依赖）
- [x] 双语 README（中/英，双语即止）：`README.md` + `README.en.md`，顶部互链
- [x] 每个示例的 token 数与报告可在 CI 复算
      —— `tools/check_examples.py`：4 个示例 + 1 条 CLI `fit` 的 stdout 与
      `examples/expected/*.txt` **逐字节**比对；`--update` 才重写，diff 必须人工 review

**完成标准**：`moon run cmd/main -- fit ...` 与全部示例进 CI，输出可 diff —— 已满足
（`.github/workflows/ci.yml` 的 `examples` 步骤）。

**实现说明**：
1. 示例放在 `cmd/examples` 而不是 `examples/`：读词表需要 IO，仓库的口径是「IO 只在 `cmd/`」；
2. 示例默认读夹具词表（277 token），`--vocab data/cl100k_base.tiktoken` 可换真实词表
   （`data/` 不入库，CI 不依赖它）；
3. 报告是 `tally-plan v2` 规范文本，所以「可 diff」直接落在字节上，不需要另建断言层；
4. CI 首次运行**失败在 `golden / format lock`**（run `39210133684`，commit `e4a749e`）：
   `tools/gen_*.py` 依赖 `regex 2026.9.29` 与 `tiktoken 0.14.0`，`gen_alignment_golden.py`
   还要 `data/cl100k_base.tiktoken`，工作流两样都没准备。补 `requirements-dev.txt`
   （golden 里写着 `source_engine` 与 tiktoken 版本，版本一漂移 `--check` 必失败）、
   `RUNNER_TEMP` 下的独立 venv（规避 ubuntu 的 PEP 668，且不进发布包）、
   `fetch_vocab.py` 之后，run `39210330467`（commit `e07f759`）14 步全绿。
   这一步是 0.5 的真正价值：**文档里写的检查，第一次真的被机器执行了**。

**未做（诚实记账）**：
- 线上 0.5.0 包对应 commit `e4a749e`；`e07f759`（CI 修复 + README 两行前置命令 +
  `requirements-dev.txt`）**没有重发**——差异只在开发依赖与 CI 配置，代码与 API 完全一致。
  若要「线上包 == 仓库 HEAD」的严格一致，需要 0.5.1；
- V1.0 的硬条件「被真实项目依赖」仍为 0，不在本版范围内解决。

## V0.6 — 稳健性与可验证 `0.6.0`（已完成）

- [x] 矩阵 I：600 次单字符随机变异喂 `load` / `load_tiktoken`，结果只能是成功或**可命名错误**
      （`vocab/robustness_wbtest.mbt`；两套夹具各 300 次，两个入口判据一致）
- [x] 矩阵 J：词表 / `.tiktoken` / 报告 / 摘要改一字节即失败并给**位置**
      （行号、缺哪个 rank、两个 sha256 各是什么；`budget/digest_wbtest.mbt` 12 条 + vocab 5 条）
- [x] 第 4 类格式（`tally-plan v2`）进 `FORMAT.lock` —— 已在 0.4.0 提前完成
- [x] 第 5 类格式（`tally-digest v1`）进 `FORMAT.lock`：
      `budget/digest_lock_wbtest.mbt` 三份摘要 + `tests/golden/sample-digest{,-overflow,-truncated}.txt`
- [x] 错误信息带位置与上下文（不逐字冻结）

**产品面新增（原计划只有"稳健"，这版把它变成了可交付能力）**：

- [x] `tally-digest v1`：报告旁的第二份文件——报告字节 + 逐段字节各一个 sha256。
      与报告分文件而不是内嵌：报告只描述计划，摘要可单独传、单独被拒
- [x] `verify` **两级**：① 自洽（两份文件互约束：段数 / 动作 / `used` / `window - reserve`）；
      ② 端到端（给齐 `--vocab` + 输入则重新装配，逐字节比对两份旧文件）
- [x] 零第三方依赖的 SHA-256（FIPS 180-4 自实现 + NIST 向量，含百万 `a`）
- [x] CI 加两步：`verify (self-consistency)`、`verify (end-to-end recompute)`；
      失败演示进 `tools/check_examples.py`（`cli-verify-mismatch`），期望输出逐字节入库
- [x] 新格式换行归一（CRLF→LF、尾部空行折叠）：Windows 控制台重定向写出的文件同样可验

**完成标准**：双后端 fuzz 0 panic；6 个生成器 `--check` 差异 0 —— 已满足
（122 测试双后端全绿、`check_examples.py` 4 例逐字节一致、`gen_format_lock.py --check` 8 份样本差异 0）。

**实现说明（这版抓到的三个真 bug）**：

1. **溢出计划无法验**：报告把 `index == -1` 的哨兵行当成"不是某一段"跳过，
   摘要却列了它，段数一侧 1 一侧 2 → 永远 `SegmentCountMismatch`。改为两侧按同一规则过滤
   （哨兵仍进 `plan` 哈希，因为"溢出过"要可核对）；
2. **`.tiktoken` 的重复 rank 被静默覆盖**：两人抢同一个 rank 时只留后者，词表里出现
   "ranks 有它、tokens 没有它"的错位。改为解析阶段报 `MalformedLine` 并指出冲突行；
3. **`DuplicateToken` 报的是 token 下标却写成"行号"**：注释说第 a 行、实际是数组位置，
   用户拿着去编辑器里定位会差一截。改为两个加载器都在解析阶段记录首次出现的**行号**
   （`build_vocab` 的同名不变检查保留为兜底）。

**未做**：摘要不签名（没有密钥体系）；`verify` 的退出码仍不是契约（core 无 `exit` API），
CI 按 stdout 判定。

## V0.7 — 基准与诚实数字 `0.7.0`

- [ ] 基准 2 项：`count` 吞吐、**100k → 8k 端到端耗时**；只记录，不设优化目标
- [ ] 数字写进 README，标注「未优化」
- [ ] 断言仅「不退化超 2 倍」

**完成标准**：基准进 CI，失败数 0。

## V1.0 — 正式版 `1.0.0`

- [ ] **被 ≥1 个真实 MoonBit 项目依赖**（`weopqrst/agent` 或 `mooncassette`），README 列出
- [ ] 门面第一屏是 `fit`，`encode` 降为底层能力
- [ ] API 冻结 + 语义化版本承诺
- [ ] 质量底线：测试 ≥ 120、对齐 ≥ 2,000、码点全覆盖、核心第三方依赖 0
- [ ] 发布审计七步走完

**完成标准**：`moon publish` 走完；下游 `moon.mod` 出现本包并可构建。

---

## 明确不做

| 项 | 理由 |
|---|---|
| 通用正则引擎 | 只为一条固定模式，抽象是负收益 |
| o200k / 任何第二编码 | 对手已覆盖；广度不是我们的轴 |
| 性能优化（LRU 等） | 不是瓶颈；只给诚实数字 |
| BPE 之外的算法 | 对手已做完 |
| 成本估算层 | 与 `mooncassette` 的 `cost` 重叠，只在 README 指路 |
| GUI / 文档站 / 服务端 | mooncakes 已渲染文档 |
| 训练能力扩展 | 已闭环，冻结 |

## 风险与观察点

1. **对手速度**：一个月 16 个版本、472 下载。若其补上 `.tiktoken` 或预算层，两个差异点同时被压缩 → 直接进维护模式，不加码。
2. **发现性**：mooncakes 搜索索引坏（`load indices failed`），可见性全靠 keywords 与 README 首段 → 定位改写的优先级高于任何功能。
3. **需求验证**：下载 5（首发 4 天）。真实信号只有「有下游引用」，不是下载数。

## 待拍板

1. 可编译适配器是否另开 `tally-adapters` 独立模块？（涉及「核心零依赖」口径）
2. 大词表文件：进仓库 / CI 下载 / 用户提供
3. 是否公开声明与 `tokenizers-moonbit` 的互补关系（对外可见动作）
4. 有无竞赛 / 提交截止日期（若有：只做 0.3.1 + 0.4.0 的接口最小可用 + 0.5.0 示例）

---

## 归档：换轴前的原计划（**不执行**）

| 原版本 | 内容 | 处置 |
|---|---|---|
| V0.4 性能 | LRU 分片缓存、4 项基准、吞吐优化 | 基准后移为 V0.7；优化砍掉 |
| V0.5 格式冻结 | 4 类格式 + CI 硬校验 | 并入 V0.6 |
| V0.6 预算深化 | 更多策略 + 矩阵 G | 升级为 V0.4 主线 |
| V0.7 示例 | 4 个示例 + 双语 README | 前移为 V0.5，示例 4 → 3 |
| V0.8 第二编码 | o200k 形状 + 属性表扩展 | **砍掉** |
| V0.9 稳健性 | 矩阵 I/J + 错误冻结 | 前移为 V0.6，错误不冻结 |
| V0.10 = V1.0 | 测试 ≥320 / 示例 ≥4 | 目标下调，新增「被依赖」硬条件 |
