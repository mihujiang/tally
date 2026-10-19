// 规范文本输出（不用 `Json::stringify`：Map 迭代序未定义）。
//
// 目的：报告要能被冻结、被 diff、被当成指纹。行尾统一 `\n`。
// 与 v1 的差别：多了计数器身份（谁算的、精不精确）、窗口模型三行，
// 以及 `[truncated]` 一节（截短了多少、截的哪一头）。

///|
fn push_str(out : Array[Char], s : String) -> Unit {
  for c in s.to_array() {
    out.push(c)
  }
}

///|
fn push_i64(out : Array[Char], n : Int64) -> Unit {
  push_str(out, n.to_string())
}

///|
fn push_bool(out : Array[Char], b : Bool) -> Unit {
  push_str(out, if b { "true" } else { "false" })
}

///|
fn strategy_name(s : TruncateStrategy) -> String {
  match s {
    NoTruncate => "none"
    KeepPrefix => "prefix"
    KeepSuffix => "suffix"
  }
}

///|
/// 把计划渲染成规范文本。冻结为格式 `tally-plan v2`。
pub fn Plan::render(self : Plan) -> String {
  let out : Array[Char] = []
  push_str(out, "tally-plan v2\n")
  push_str(out, "counter ")
  push_str(out, self.counter)
  push_str(out, " exact=")
  push_bool(out, self.exact)
  push_str(out, "\nwindow ")
  push_i64(out, self.window)
  push_str(out, "\nreserve ")
  push_i64(out, self.reserve)
  push_str(out, "\ninput_limit ")
  push_i64(out, self.limit)
  push_str(out, "\nused ")
  push_i64(out, self.tokens_used)
  push_str(out, "\npinned ")
  push_i64(out, self.pinned_tokens)
  push_str(out, "\noverflow ")
  push_bool(out, self.overflow)
  push_str(out, "\n[kept]\n")
  for k in self.kept {
    push_str(out, k.index.to_string())
    out.push(' ')
    push_str(out, k.priority.name())
    out.push(' ')
    push_str(out, k.role)
    out.push(' ')
    push_i64(out, k.tokens)
    out.push('\n')
  }
  push_str(out, "[truncated]\n")
  for t in self.truncated {
    push_str(out, t.index.to_string())
    out.push(' ')
    push_str(out, t.priority.name())
    out.push(' ')
    push_str(out, t.role)
    out.push(' ')
    push_i64(out, t.original_tokens)
    push_str(out, "->")
    push_i64(out, t.tokens)
    out.push(' ')
    push_str(out, strategy_name(t.strategy))
    out.push('\n')
  }
  push_str(out, "[dropped]\n")
  for d in self.dropped {
    push_str(out, d.index.to_string())
    out.push(' ')
    push_str(out, d.priority.name())
    out.push(' ')
    push_str(out, d.role)
    out.push(' ')
    push_i64(out, d.tokens)
    out.push(' ')
    push_str(out, d.reason)
    out.push('\n')
  }
  String::from_array(out)
}
