// diskmap — the headless counterpart of the WPF app (WIN-070/071).
// Same contract as the macOS CLI: sizes are SI ("50GB" = 50·10⁹,
// "GiB" = 1024³), ages are d/w/m/y, progress writes to stderr only on
// a terminal so --json stdout stays clean. Exit codes:
//   0 ok · 1 check threshold exceeded · 2 usage · 3 path unreadable.
using System.Text.Json;
using DiskMap.Core;

var argsList = args.ToList();
if (argsList.Count == 0 || argsList.Contains("--help"))
    return Usage();

string command = argsList[0];

// ---- bench ----
if (command == "bench")
{
    string path = argsList.Skip(1).FirstOrDefault(a => !a.StartsWith("--")) ?? Environment.SystemDirectory;
    int repeat = IntOf(argsList, "--repeat") ?? 3;
    bool json = argsList.Contains("--json");
    var engine = new ScanEngine();
    var runs = new List<object>();
    for (int i = 0; i < repeat; i++)
    {
        var r = await engine.ScanAsync(path, Terminal.Progress());
        runs.Add(new
        {
            run = i + 1, backend = r.Backend, items = r.ItemCount,
            seconds = Math.Round(r.ElapsedSeconds, 2),
            peakMb = Math.Round(r.PeakResidentBytesDuringWalk / 1048576.0, 1),
        });
    }
    if (json) Console.WriteLine(JsonSerializer.Serialize(runs));
    else
        foreach (var run in runs)
            Console.WriteLine(JsonSerializer.Serialize(run));
    return 0;
}

// Everything below needs a path.
string? target = argsList.Skip(1).FirstOrDefault(a => !a.StartsWith("--"));
if (target is null || !Directory.Exists(target))
{
    Console.Error.WriteLine($"diskmap: '{target ?? "(missing)"}' is not a folder");
    return target is null ? Usage() : 3;
}
target = Path.GetFullPath(target);

var scan = await new ScanEngine().ScanAsync(target, Terminal.Progress());
var tree = scan.Tree;
var totals = tree.RollUpSizes();

switch (command)
{
    case "scan":
    {
        if (argsList.Contains("--json"))
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                root = target, backend = scan.Backend, items = scan.ItemCount,
                seconds = Math.Round(scan.ElapsedSeconds, 2),
                bytes = totals[0], denied = scan.DeniedDirectoryIds.Count,
            }));
        }
        else
        {
            Console.WriteLine($"{target}: {HumanUnits.Format(totals[0])} across " +
                $"{scan.ItemCount:N0} items in {scan.ElapsedSeconds:0.0}s ({scan.Backend})");
            if (scan.DeniedDirectoryIds.Count > 0)
                Console.WriteLine($"  {scan.DeniedDirectoryIds.Count} folders couldn't be read (denied)");
        }
        return 0;
    }

    case "find":
    {
        string? query = argsList.Skip(2).FirstOrDefault(a => !a.StartsWith("--"));
        if (query is null)
        {
            Console.Error.WriteLine("diskmap find <path> <query>");
            return 2;
        }
        int limit = IntOf(argsList, "--limit") ?? 50;
        var parsed = FileQuery.Parse(query, home: Environment.GetFolderPath(
            Environment.SpecialFolder.UserProfile), root: target);
        List<int> hits = parsed.Query.IsStructured
            ? parsed.Query.Run(tree, target, totals, new FileQuery.Context(), limit: limit).Ids
            : FileSearch.Search(tree, totals, query, limit);
        if (argsList.Contains("--json"))
        {
            Console.WriteLine(JsonSerializer.Serialize(hits.Select(id =>
                new { path = PathOf(tree, id, target), bytes = totals[id] })));
        }
        else
        {
            foreach (var id in hits)
                Console.WriteLine($"{HumanUnits.Format(totals[id]),10}  {PathOf(tree, id, target)}");
        }
        return 0;
    }

    case "dup":
    {
        var groups = await DuplicateFinder.FindDuplicatesAsync(
            DuplicateFinder.Candidates(tree, target));
        if (argsList.Contains("--json"))
        {
            Console.WriteLine(JsonSerializer.Serialize(groups.Select(g => new
            {
                size = g.SizeEach,
                copies = g.FileIDs.Count,
                sharedExtents = g.SharesStorage,
                paths = g.FileIDs.Select(id => PathOf(tree, id, target)),
            })));
        }
        else
        {
            foreach (var g in groups)
            {
                Console.WriteLine($"{HumanUnits.Format(g.SizeEach)} × {g.FileIDs.Count}"
                    + (g.SharesStorage ? "  (shared extents)" : ""));
                foreach (var id in g.FileIDs) Console.WriteLine($"    {PathOf(tree, id, target)}");
            }
        }
        return 0;
    }

    case "export":
    {
        var format = argsList.Contains("--ndjson") ? TreeExporter.Format.Ndjson
            : argsList.Contains("--csv") ? TreeExporter.Format.Csv
            : argsList.Contains("--ncdu") ? TreeExporter.Format.Ncdu
            : TreeExporter.Format.Json;
        string? outPath = argsList.Skip(2).FirstOrDefault(a => !a.StartsWith("--") && a != target);
        string text = TreeExporter.Export(tree, totals, target, format);
        if (outPath is null) Console.Write(text);
        else File.WriteAllText(outPath, text);
        return 0;
    }

    case "check":
    {
        long threshold = argsList.Skip(2).FirstOrDefault(a => a.StartsWith("--fail-over"))
            is { } flag && argsList.IndexOf(flag) + 1 < argsList.Count
            && TryParseSize(argsList[argsList.IndexOf(flag) + 1], out long parsed)
                ? parsed : 50L * 1_000_000_000;
        bool over = totals[0] > threshold;
        Console.WriteLine($"{HumanUnits.Format(totals[0])} {(over ? "over" : "under")} {HumanUnits.Format(threshold)}");
        return over ? 1 : 0;
    }

    default:
        return Usage();
}

static int Usage()
{
    Console.Error.WriteLine("""
        diskmap — disk usage from the file table, not stat calls.

          diskmap bench <path> [--repeat N] [--json]
          diskmap scan  <path> [--json]
          diskmap find  <path> <query> [--limit N] [--json]
          diskmap dup   <path> [--json]
          diskmap export <path> [--json|--ndjson|--csv|--ncdu] [out]
          diskmap check <path> --fail-over 50GB

        Sizes are SI (GB=10⁹, GiB=2³⁰); ages are d/w/m/y.
        Exit codes: 0 ok · 1 threshold exceeded · 2 usage · 3 unreadable.
        """);
    return 2;
}

static int? IntOf(List<string> args, string flag)
{
    int i = args.IndexOf(flag);
    return i >= 0 && i + 1 < args.Count && int.TryParse(args[i + 1], out int v) ? v : null;
}

/// <summary>SI sizes: "50GB"/"50GiB"/"200MB"/"4KB"; bare digits = bytes.</summary>
static bool TryParseSize(string s, out long bytes)
{
    s = s.Trim();
    var unit = s.EndsWith("GiB", StringComparison.OrdinalIgnoreCase) ? (1024.0 * 1024 * 1024, 3)
        : s.EndsWith("GB", StringComparison.OrdinalIgnoreCase) ? (1e9, 2)
        : s.EndsWith("MiB", StringComparison.OrdinalIgnoreCase) ? (1048576.0, 3)
        : s.EndsWith("MB", StringComparison.OrdinalIgnoreCase) ? (1e6, 2)
        : s.EndsWith("KiB", StringComparison.OrdinalIgnoreCase) ? (1024.0, 3)
        : s.EndsWith("KB", StringComparison.OrdinalIgnoreCase) ? (1e3, 2)
        : (1.0, 0);
    bool ok = double.TryParse(s[..^unit.Item2], out double n);
    bytes = ok ? (long)(n * unit.Item1) : 0;
    return ok;
}

static string PathOf(FileTree tree, int id, string root)
{
    var parts = new List<string>();
    for (int p = id; p > 0; p = tree.Parent[p]) parts.Add(tree.NameOf(p));
    parts.Reverse();
    return root.TrimEnd('\\') + '\\' + string.Join('\\', parts);
}

static class Terminal
{
    /// <summary>Progress goes to stderr, and only on a real console.</summary>
    public static IProgress<ScanEngine.ScanProgress>? Progress() =>
        Console.IsErrorRedirected ? null
            : new Progress<ScanEngine.ScanProgress>(p =>
                Console.Error.Write($"\r{p.Items:N0} items · {HumanUnits.Format(p.Bytes)}   "));
}
