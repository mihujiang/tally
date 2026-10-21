// 装配配置：计数器 + 窗口 + 输出预留 + 截断策略。
//
// 窗口模型：`window = reserve_output + input_limit`。
// 真实场景里「128k 窗口」不等于「128k 都能给输入」——要留出回复。
// 预留放不下时**显式报错**，而不是悄悄把可用空间算成负数。

///|
/// 预算装不下时对单段的处理方式。
pub(all) enum TruncateStrategy {
  /// 整段丢弃（0.3 的默认行为）。
  NoTruncate
  /// 保留段首、截掉段尾：适合 system 提示这类开头最重要的内容。
  KeepPrefix
  /// 保留段尾、截掉段首：适合历史/日志这类最近内容最重要的段。
  KeepSuffix
  /// 保留段首、把被截掉的尾部换成**确定性占位标记**，并标注省略了多少 token。
  ///
  /// 零依赖约束下这是「占位压缩」的全部含义：标记是固定文案（只带省略量），
  /// 不做语义摘要；标记本身的 token 数计入窗口。适合长日志/长工具输出——
  /// 模型能看到「这里有 N 个 token 被省略」，比整段消失更有信息量。
  Compress
} derive(Eq, Debug)

///|
/// 一个配额池：同名段共享 `limit` 个 token 的额度。
///
/// 语义要点（都写进报告，可核对）：
/// * 配额只约束**可裁段**；`Pinned` 段不裁，若 Pinned 自身超过配额，
///   报告里 `used` 会如实大于 `quota`。
/// * 池的额度用不完时，可按 `pools` 数组的声明顺序借给超额的池；
///   借用/借出量逐池记账。
/// * 没有声明配额的池不参与配额（只受总预算约束）。
pub(all) struct PoolQuota {
  name : String
  limit : Int64
}

///|
pub fn PoolQuota::new(name : String, limit : Int64) -> PoolQuota {
  { name, limit }
}

///|
/// 一次装配的配置。
pub(all) struct FitConfig {
  counter : Counter
  window : Int64
  reserve_output : Int64
  strategy : TruncateStrategy
  /// 池配额，按声明顺序参与借用；空数组 = 不做池约束。
  pools : Array[PoolQuota]
}

///|
/// 默认配置：整窗可用、整段丢弃、无池配额。
pub fn FitConfig::new(counter : Counter, window : Int64) -> FitConfig {
  { counter, window, reserve_output: 0L, strategy: NoTruncate, pools: [] }
}

///|
/// 设置池配额（按数组顺序处理借用）。
pub fn FitConfig::with_pools(
  self : FitConfig,
  pools : Array[PoolQuota],
) -> FitConfig {
  { ..self, pools }
}

///|
/// 预留 `reserve_output` 个 token 给模型回复。
pub fn FitConfig::with_reserve(
  self : FitConfig,
  reserve_output : Int64,
) -> FitConfig {
  { ..self, reserve_output }
}

///|
/// 设置截断策略。
pub fn FitConfig::with_strategy(
  self : FitConfig,
  strategy : TruncateStrategy,
) -> FitConfig {
  { ..self, strategy }
}

///|
/// 输入可用预算：`window - reserve_output`。
pub fn FitConfig::input_limit(self : FitConfig) -> Int64 {
  self.window - self.reserve_output
}

///|
/// 装配错误（不是「装不下」，装不下会写进报告；这是配置本身不成立）。
pub suberror FitError {
  /// 输出预留吃掉了整个窗口：`reserve >= window`
  ReserveExceedsWindow(Int64, Int64)
}
