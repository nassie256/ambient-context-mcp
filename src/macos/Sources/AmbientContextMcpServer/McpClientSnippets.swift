import Foundation

/// C# `McpClientSnippets` (src/windows/AmbientContextMcp.Desktop/Mcp/McpClientSnippets.cs) の移植。
/// 生成される文字列は 1 文字も変えないこと (メニューの「Claude Code 用設定をコピー」で使う)。
public enum McpClientSnippets {
    public static func buildClaudeCodeSnippet(mcpUrl: String, token: String) -> String {
        "claude mcp add ambient-context "
            + "--transport http \(mcpUrl) "
            + "--header \"Authorization: Bearer \(token)\""
    }
}
