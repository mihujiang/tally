// 统一的词表错误类型。
//
// 纪律：**加载时若同一字节序列出现两次 -> 报错**（不变量 V3），
// 而不是静默取一个。静默取一个会让"精确"这个词失去意义。

///|
pub suberror VocabError {
  /// base64 里出现非法字符
  InvalidBase64(Char)
  /// 第 `line` 行无法解析
  MalformedLine(Int, String)
  /// 同一字节序列出现两次（第一次在第 a 行，第二次在第 b 行）
  DuplicateToken(Int, Int)
  /// 第 `index` 个 token 为空（不变量 V2）
  EmptyToken(Int)
  /// 缺少单字节 token `byte`（不变量 V1）
  MissingByteToken(Int)
  /// 特殊 token 的 id 越界
  SpecialOutOfRange(Int, Int)
  /// 未知的段名
  UnknownSection(String)
} derive(Debug)
