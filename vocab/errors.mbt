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
  /// 同一字节序列出现两次。`a`、`b` 是位置：解析器检测时给出两次所在的行号，
  /// 内部构建器兜底检测时给出 token 下标（正常情况下解析器会先命中，带行号）。
  DuplicateToken(Int, Int)
  /// 第 `index` 个 token 为空（不变量 V2）
  EmptyToken(Int)
  /// 缺少单字节 token `byte`（不变量 V1）
  MissingByteToken(Int)
  /// 特殊 token 的 id 越界
  SpecialOutOfRange(Int, Int)
  /// 未知的段名
  UnknownSection(String)
  /// 训练目标词表大小 `vocab_size` 连基座都放不下（256 个单字节 + 特殊 token）
  TrainSizeTooSmall(Int, Int)
} derive(Debug)
