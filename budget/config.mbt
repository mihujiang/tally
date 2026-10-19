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
} derive(Eq, Debug)

///|
/// 一次装配的配置。
pub(all) struct FitConfig {
  counter : Counter
  window : Int64
  reserve_output : Int64
  strategy : TruncateStrategy
}

///|
/// 默认配置：整窗可用、整段丢弃。
pub fn FitConfig::new(counter : Counter, window : Int64) -> FitConfig {
  { counter, window, reserve_output: 0L, strategy: NoTruncate }
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
