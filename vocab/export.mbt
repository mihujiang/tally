// 规范导出。
//
// 为什么不用 `Json::stringify`：`Json::Object` 底层是 Map，迭代顺序未定义，
// 落盘/指纹用的文本绝不能依赖它（计划 §3.2）。
// 这里用完全显式的顺序：specials 按 id 升序，tokens 按 id 升序，行尾 `\n`。

///|
fn push_str(out : Array[Char], s : String) -> Unit {
  for c in s.to_array() {
    out.push(c)
  }
}

///|
fn push_int(out : Array[Char], n : Int) -> Unit {
  push_str(out, n.to_string())
}

///|
/// 导出为自有规范文本格式（`tally-vocab v1`）。
///
/// 不变量 V10：`load(root_export(v))` 与 `v` 内容等价，
/// 且同样的 `v` 导出结果逐字节稳定。
pub fn Vocab::to_text(self : Vocab) -> String {
  let out : Array[Char] = []
  push_str(out, format_header)
  push_str(out, "\n")
  push_str(out, "# unicode ")
  push_str(out, @bpe.unicode_version())
  push_str(out, "\n")
  push_str(out, "# tokens ")
  push_int(out, self.token_count())
  push_str(out, "\n")
  push_str(out, "[specials]\n")
  for e in self.specials {
    let (lit, id) = e
    push_int(out, id)
    out.push(' ')
    push_str(out, b64_encode(@utf8.encode(lit)))
    out.push('\n')
  }
  push_str(out, "[tokens]\n")
  for id = 0; id < self.tokens.length(); id = id + 1 {
    let bytes = self.tokens[id]
    let rank = match self.rank_of(bytes) {
      Some(r) => r
      None => id
    }
    push_int(out, id)
    out.push(' ')
    push_int(out, rank)
    out.push(' ')
    push_str(out, b64_encode(bytes))
    out.push('\n')
  }
  String::from_array(out)
}
