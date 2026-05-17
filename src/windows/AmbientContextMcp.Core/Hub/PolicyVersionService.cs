using System.Security.Cryptography;
using System.Text;
using AmbientContextMcp.Core.Models;

namespace AmbientContextMcp.Core.Hub;

public static class PolicyVersionService
{
    public static string ComputePolicyVersion(
        IReadOnlyList<PrivacyClassification> classifications,
        IReadOnlyDictionary<string, bool> overrides)
    {
        var sb = new StringBuilder();

        foreach (var item in classifications.OrderBy(c => c.Path, StringComparer.OrdinalIgnoreCase))
        {
            sb.Append("c|").Append(item.Path).Append('|')
              .Append(SensitivityScopeFilter.NormalizeSensitivity(item.Sensitivity)).Append('|')
              .Append(item.DefaultTransmit ? '1' : '0').Append('\n');
        }

        foreach (var pair in overrides.OrderBy(p => p.Key, StringComparer.OrdinalIgnoreCase))
        {
            sb.Append("o|").Append(pair.Key).Append('|')
              .Append(pair.Value ? '1' : '0').Append('\n');
        }

        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(sb.ToString()));
        return Convert.ToBase64String(hash, 0, 9)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }
}
