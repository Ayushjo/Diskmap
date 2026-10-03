using System.Text.Json;
using DiskMap.Core;

namespace DiskMap.Core.Tests;

public class TreeExporterTests
{
    private static FileTree Fixture(out long[] totals)
    {
        var tree = new FileTree();
        int root = tree.AddNode("root", -1, true, 0, 0, 0);
        int sub = tree.AddNode("sub,dir", root, true, 0, 0, 0);
        tree.AddNode("a.txt", sub, false, 100, 100, 5, fileId: 11);
        tree.AddNode("b.txt", root, false, 50, 50, 4, fileId: 12);
        totals = [0, 0, 0, 0];
        totals[2] = 100; totals[3] = 50; totals[1] = 100; totals[0] = 150;
        return tree;
    }

    [Fact]
    public void CsvQuotesFieldsWithCommas()
    {
        var tree = Fixture(out var totals);
        var csv = TreeExporter.Export(tree, totals, @"C:\root", TreeExporter.Format.Csv);
        Assert.Contains("\"C:\\root\\sub,dir\"", csv);
        Assert.Contains("path,name,logicalBytes", csv);
    }

    [Fact]
    public void NdjsonEmitsOneObjectPerNode()
    {
        var tree = Fixture(out var totals);
        var lines = TreeExporter.Export(tree, totals, @"C:\root", TreeExporter.Format.Ndjson)
            .Trim().Split('\n');
        Assert.Equal(4, lines.Length);
        var doc = JsonDocument.Parse(lines[0]);
        Assert.True(doc.RootElement.GetProperty("directory").GetBoolean());
    }

    [Fact]
    public void NcduNestsChildrenUnderTheirParent()
    {
        var tree = Fixture(out var totals);
        var ncdu = TreeExporter.Export(tree, totals, @"C:\root", TreeExporter.Format.Ncdu);
        var doc = JsonDocument.Parse(ncdu);
        Assert.Equal(1, doc.RootElement[0].GetInt32());   // format major
        // [1,0,{prog},{rootEntry},[children...]] — an entry is the object
        // plus its children array as a separate element.
        var rootEntry = doc.RootElement[3];
        Assert.Equal("C:\\root", rootEntry.GetProperty("name").GetString());
        Assert.Equal(150, rootEntry.GetProperty("dsize").GetInt64());
        var children = doc.RootElement[4];
        // sub,dir obj + its kids array + b.txt obj (b.txt has no kids array)
        Assert.Equal(3, children.GetArrayLength());
        var names = children.EnumerateArray()
            .Where(e => e.ValueKind == JsonValueKind.Object)
            .Select(e => e.GetProperty("name").GetString())
            .ToHashSet();
        Assert.Equal(["sub,dir", "b.txt"], names);
    }

    [Fact]
    public void JsonIsNestedAndCarriesIdentity()
    {
        var tree = Fixture(out var totals);
        var doc = JsonDocument.Parse(
            TreeExporter.Export(tree, totals, @"C:\root", TreeExporter.Format.Json));
        var root = doc.RootElement;
        Assert.Equal("C:\\root", root.GetProperty("name").GetString());
        Assert.Equal(2, root.GetProperty("children").GetArrayLength());
    }

    [Fact]
    public void CopyPathsQuotingOnlyWhenNeeded()
    {
        Assert.Equal(@"C:\plain\name.txt", TreeExporter.QuotePathIfNeeded(@"C:\plain\name.txt"));
        Assert.Equal("\"C:\\has space\\name.txt\"", TreeExporter.QuotePathIfNeeded(@"C:\has space\name.txt"));
        Assert.Equal("\"C:\\a&b\"", TreeExporter.QuotePathIfNeeded(@"C:\a&b"));
    }
}
