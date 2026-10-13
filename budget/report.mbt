// 规范文本输出（不用 `Json::stringify`：Map 迭代序未定义）。
//
// 目的：报告要能被冻结、被 diff、被当成指纹。行尾统一 `\n`。

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
/// 把计划渲染成规范文本。冻结为格式 `tally-plan v1`。
pub fn Plan::render(self : Plan) -> String {
  let out : Array[Char] = []
  push_str(out, "tally-plan v1\n")
  push_str(out, "limit ")
  push_i64(out, self.limit)
  push_str(out, "\nused ")
  push_i64(out, self.tokens_used)
  push_str(out, "\npinned ")
  push_i64(out, self.pinned_tokens)
  push_str(out, "\noverflow ")
  push_str(out, if self.overflow { "true" } else { "false" })
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
