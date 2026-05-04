using System.Text.Json;
using System.Text.Json.Serialization;

namespace AmbientContextMcp.Core.Mcp;

public static class AmbientContextJson
{
    public static JsonSerializerOptions Options { get; } = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };
}
