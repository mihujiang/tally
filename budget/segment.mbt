// 段与优先级模型。
//
// 优先级为什么这样分（README 要解释）：
// * `Pinned`  —— system 提示、工具定义：一旦丢失语义就崩，永不被裁。
// * `Newest`  —— 最近若干轮：对下一步生成影响最大，优先保留。
// * `Middle`  —— 中间历史：第一批牺牲品之一。
// * `Oldest`  —— 最早的历史：最先被丢。

///|
/// 段的丢弃权重，从「不可丢」到「最先牺牲」。
///
/// 典型用法：system 提示与工具定义用 `Pinned`，最近几轮用 `Newest`，
/// 中间历史用 `Middle`，最早的历史用 `Oldest`。
/// 权重相同时先丢原始下标更小的段（更早的历史），因此结果与输入顺序无关可复现。
pub(all) enum Priority {
  Pinned
  Newest
  Middle
  Oldest
} derive(Eq, Debug)

///|
/// 优先级权重；越大越不可丢。
pub fn Priority::weight(self : Priority) -> Int {
  match self {
    Pinned => 3
    Newest => 2
    Middle => 1
    Oldest => 0
  }
}

///|
/// 规范名称（用于可冻结的报告文本，不用 Debug 输出）。
pub fn Priority::name(self : Priority) -> String {
  match self {
    Pinned => "pinned"
    Newest => "newest"
    Middle => "middle"
    Oldest => "oldest"
  }
}

///|
/// 上下文里的一段。`role` 是自由标签（如 `system` / `user`），
/// `bytes` 是该段要送进窗口的内容。
pub(all) struct Segment {
  role : String
  priority : Priority
  bytes : Bytes
}

///|
pub fn Segment::new(role : String, priority : Priority, bytes : Bytes) -> Segment {
  { role, priority, bytes }
}

///|
pub fn Segment::text(role : String, priority : Priority, text : String) -> Segment {
  { role, priority, bytes: @utf8.encode(text) }
}
