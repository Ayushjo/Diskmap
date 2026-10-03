using DiskMap.Core;

namespace DiskMap.Core.Tests;

/// <summary>
/// WIN-074's enforcement: DiskMap is offline-only by design — the one
/// macOS exception (Sparkle, opt-in) has no Windows counterpart yet;
/// when/if one lands it gets a dedicated file and an exclusion here.
/// The test greps sources, not binaries — a networking type should
/// never reach compile.
/// </summary>
public class NetworkPolicyTests
{
    private static readonly string[] Forbidden =
    [
        "System.Net.Http", "HttpClient", "WebRequest", "WebClient",
        "HttpListener", "Sockets.Http", "IHttpClientFactory",
        "RestSharp", "Flurl",
    ];

    [Fact]
    public void NoNetworkingTypesInSources()
    {
        // Tests run from <repo>/windows/tests/... — locate the tree.
        // BaseDirectory = tests/DiskMap.Core.Tests/bin/<cfg>/net10.0 → up 5 = windows/
        string repo = Path.GetFullPath(Path.Combine(
            AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
        string sourcesRoot = Path.Combine(repo, "src", "DiskMap.Core");
        string appRoot = Path.Combine(repo, "app");
        Assert.True(Directory.Exists(sourcesRoot), $"sources at {sourcesRoot}");

        var offenders = new List<string>();
        foreach (var root in new[] { sourcesRoot, appRoot })
        {
            foreach (var file in Directory.EnumerateFiles(root, "*.cs", SearchOption.AllDirectories)
                         .Where(f => !f.Contains(Path.DirectorySeparatorChar + "obj" + Path.DirectorySeparatorChar)
                                  && !f.Contains(Path.DirectorySeparatorChar + "bin" + Path.DirectorySeparatorChar)))
            {
                string text = File.ReadAllText(file);
                foreach (var term in Forbidden)
                    if (text.Contains(term, StringComparison.Ordinal))
                        offenders.Add($"{Path.GetFileName(file)}: {term}");
            }
        }
        Assert.Empty(offenders);
    }
}
