using System.IO;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;
using AmbientContextMcp.Core.Mcp;
using AmbientContextMcp.Core.Models;

namespace AmbientContextMcp.AmbientContext;

public sealed class AmbientSnapshotWriter
{
    private static readonly JsonSerializerOptions JsonOptions = new(AmbientContextJson.Options)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private readonly string _path;

    public AmbientSnapshotWriter(string path)
    {
        _path = path;
    }

    public void Write(AmbientContextSnapshot snapshot)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var tempPath = _path + ".tmp";
        File.WriteAllText(tempPath, SerializeReadableJson(snapshot), Encoding.UTF8);
        File.Move(tempPath, _path, true);
    }

    private static string SerializeReadableJson(AmbientContextSnapshot snapshot)
    {
        var json = JsonSerializer.Serialize(snapshot, JsonOptions);
        return Regex.Replace(
            json,
            @"\\u([0-9a-fA-F]{4})",
            match =>
            {
                var value = Convert.ToInt32(match.Groups[1].Value, 16);
                var character = (char)value;
                return char.IsControl(character) || character is '"' or '\\'
                    ? match.Value
                    : character.ToString();
            },
            RegexOptions.CultureInvariant);
    }
}
