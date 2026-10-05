using System.Buffers.Binary;
using DiskMap.Core.Native;
using Microsoft.Win32.SafeHandles;

namespace DiskMap.Core;

/// <summary>
/// The NTFS change journal (WIN-031): the durable record of every create,
/// delete, rename, and size change since a baseline scan. One
/// FSCTL_QUERY_USN_JOURNAL gives the marker a scan bookmarks; replaying
/// FSCTL_READ_USN_JOURNAL from it lists every touched file record — the
/// Windows counterpart of the macOS FSEvents incremental rescan.
///
/// Fallbacks (caller decides): journal id changed (deleted/recreated),
/// requested start already overwritten (first record's USN beyond our
/// marker), non-NTFS volume, or a change flood.
/// </summary>
public static class UsnJournal
{
    /// <summary>A journal cursor: id + where the next change lands.</summary>
    public readonly record struct Marker(long JournalId, long NextUsn);

    /// <summary>One changed record from the journal.</summary>
    public readonly record struct Entry(
        long Frn, long ParentFrn, string Name, uint Reason, long Usn, uint Attributes);

    public sealed record Changes(
        /// <summary>Every record read, in USN order.</summary>
        List<Entry> Entries,
        /// <summary>The journal cursor the replay ended at.</summary>
        Marker Marker,
        /// <summary>True when entries between the marker and the first read were overwritten — must not be trusted.</summary>
        bool Wrapped);

    /// <summary>The journal's identity + current cursor; null when the device has none.</summary>
    public static unsafe Marker? Query(SafeFileHandle volume)
    {
        var data = new Win32.USN_JOURNAL_DATA_V0();
        void* outBuf = &data;
        if (!Win32.DeviceIoControl(volume, Win32.FSCTL_QUERY_USN_JOURNAL,
                null, 0, outBuf, sizeof(Win32.USN_JOURNAL_DATA_V0), out _, IntPtr.Zero))
            return null;
        return new Marker(data.UsnJournalID, data.NextUsn);
    }

    /// <summary>
    /// Reads every journal record strictly after <paramref name="from"/>
    /// on journal <paramref name="journalId"/>. Wrapped when the window
    /// [from, firstReturned) was overwritten before we could read it.
    /// </summary>
    public static unsafe Changes? ReadAll(
        SafeFileHandle volume, Marker from, CancellationToken ct, int maxEntries = 2_000_000)
    {
        var input = new Win32.READ_USN_JOURNAL_DATA_V0
        {
            StartUsn = from.NextUsn,
            ReasonMask = Win32.USN_REASON_ALL,
            ReturnOnlyOnClose = 0,
            Timeout = 0,
            BytesToWaitFor = 0,
            UsnJournalID = (ulong)from.JournalId,
        };
        var entries = new List<Entry>();
        var buffer = new byte[64 * 1024];
        bool wrapped = false;
        bool first = true;
        long cursor = from.NextUsn;

        while (true)
        {
            ct.ThrowIfCancellationRequested();
            input.StartUsn = cursor;
            int bytes;
            fixed (byte* outBuf = buffer)
            {
                if (!Win32.DeviceIoControl(volume, Win32.FSCTL_READ_USN_JOURNAL,
                        &input, sizeof(Win32.READ_USN_JOURNAL_DATA_V0),
                        outBuf, buffer.Length, out bytes, IntPtr.Zero))
                    return null;   // call failed — let the caller decide
            }
            if (bytes <= 8) break;   // just the continuation USN — journal empty
            cursor = BinaryPrimitives.ReadInt64LittleEndian(buffer.AsSpan(0, 8));
            int pos = 8;
            while (pos + 8 <= bytes)
            {
                int recordLength = BinaryPrimitives.ReadInt32LittleEndian(buffer.AsSpan(pos));
                if (recordLength <= 0 || pos + recordLength > bytes) break;
                var rec = buffer.AsSpan(pos, recordLength);
                int major = BinaryPrimitives.ReadUInt16LittleEndian(rec.Slice(4));
                if (major == Win32.UsnRecordVersion2 && rec.Length >= Win32.UsnRecordMinLength)
                {
                    long frn = BinaryPrimitives.ReadInt64LittleEndian(rec.Slice(8))
                        & Win32.UsnRecordMask;
                    long parent = BinaryPrimitives.ReadInt64LittleEndian(rec.Slice(16))
                        & Win32.UsnRecordMask;
                    long usn = BinaryPrimitives.ReadInt64LittleEndian(rec.Slice(24));
                    uint reason = BinaryPrimitives.ReadUInt32LittleEndian(rec.Slice(40));
                    uint attrs = BinaryPrimitives.ReadUInt32LittleEndian(rec.Slice(52));
                    int nameBytes = BinaryPrimitives.ReadUInt16LittleEndian(rec.Slice(56));
                    int nameOffset = BinaryPrimitives.ReadUInt16LittleEndian(rec.Slice(58));
                    string name = nameOffset + nameBytes <= rec.Length && nameBytes > 0
                        ? System.Text.Encoding.Unicode.GetString(
                            rec.Slice(nameOffset, nameBytes))
                        : "";
                    entries.Add(new Entry(frn, parent, name, reason, usn, attrs));
                    if (first)
                    {
                        // The first record we get back carries a USN newer
                        // than our marker when the journal overwrote what
                        // we meant to replay.
                        first = false;
                        if (usn > from.NextUsn + 1) wrapped = true;
                    }
                    if (entries.Count >= maxEntries)
                        return new Changes(entries, new Marker(from.JournalId, usn), Wrapped: true);
                }
                pos += recordLength;
            }
            // A zero-length tail means the read returned no records.
            if (pos <= 8) break;
        }
        return new Changes(entries, new Marker(from.JournalId, cursor), wrapped);
    }
}
