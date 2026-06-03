namespace AmbientContextMcp.Mcp;

public static class McpClientSnippets
{
    public static string BuildClaudeCodeSnippet(string mcpUrl, string token)
    {
        return $"claude mcp add ambient-context " +
               $"--transport http {mcpUrl} " +
               $"--header \"Authorization: Bearer {token}\"";
    }
}
