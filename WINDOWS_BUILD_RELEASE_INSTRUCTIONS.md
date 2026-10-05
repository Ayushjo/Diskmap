# Windows Build and Release Instructions

Use these instructions to build, test, and package the Windows edition of
**freedisk.space**, then publish it alongside the macOS build in one GitHub
release.

Both platform artifacts must be built from the same commit and use the version
stored in [`VERSION`](VERSION).

## Windows requirements

- Windows 10 or 11 on x64
- .NET 10 SDK
- PowerShell
- GitHub CLI (`gh`) when uploading from the command line

## Build and test Windows

Run from the repository root in PowerShell:

```powershell
dotnet --version
dotnet build .\windows\DiskMap.Win.slnx -c Release
dotnet test .\windows\DiskMap.Win.slnx -c Release --no-build
```

## Run a development build

```powershell
Start-Process .\windows\app\DiskMap.App\bin\Release\net10.0-windows\DiskMap.App.exe
```

Windows displays a UAC prompt because the application intentionally requests
administrator access for fast MFT scanning and access to protected directories.
Running it directly with `dotnet run` requires an already elevated terminal.

## Produce the Windows release executable

Use a fresh output directory so stale files cannot enter the release:

```powershell
$version = (Get-Content .\VERSION -Raw).Trim()
$out = ".\dist\windows-$version-x64"

if (Test-Path $out) {
    throw "$out already exists. Remove it or choose a fresh output directory."
}

dotnet publish .\windows\app\DiskMap.App\DiskMap.App.csproj `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -o $out `
    -p:Version=$version `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:IncludeAllContentForSelfExtract=true `
    -p:DebugType=None `
    -p:DebugSymbols=false

Rename-Item `
    "$out\DiskMap.App.exe" `
    "freedisk.space-$version-windows-x64.exe"
```

The resulting artifact is:

```text
dist\windows-<version>-x64\freedisk.space-<version>-windows-x64.exe
```

This is a self-contained Windows x64 executable, so the user does not need to
install .NET. `IncludeNativeLibrariesForSelfExtract` and
`IncludeAllContentForSelfExtract` are required to make the WPF publication an
actual single-file executable.

Test the packaged executable:

```powershell
Start-Process ".\dist\windows-$version-x64\freedisk.space-$version-windows-x64.exe"
```

Generate its checksum:

```powershell
$exe = ".\dist\windows-$version-x64\freedisk.space-$version-windows-x64.exe"
Get-FileHash $exe -Algorithm SHA256
```

### Windows signing

The repository does not currently configure Authenticode signing. Unsigned
public downloads may show **Unknown publisher** or Microsoft Defender
SmartScreen warnings. If a Windows code-signing certificate is available,
rename the executable first, sign that final file, and generate the checksum
after signing.

## Build the macOS release

On a Mac, check out the exact same commit used for Windows and run:

```bash
swift build
scripts/test.sh
scripts/build-adhoc.sh
```

This produces a universal Intel and Apple Silicon build:

```text
dist/freedisk.space.app
dist/freedisk.space-<version>.dmg
```

For a public release, sign and notarize the application with an Apple Developer
ID:

```bash
export DEVELOPER_ID='Developer ID Application: Name (TEAMID)'
export NOTARY_PROFILE='diskmap'
scripts/notarize.sh
```

Without Developer ID signing and notarization, the DMG is only ad-hoc signed.
Users must approve it through **System Settings > Privacy & Security > Open
Anyway** on first launch.

For consistent GitHub asset names, rename the notarized DMG before uploading:

```bash
version="$(tr -d '[:space:]' < VERSION)"
mv "dist/freedisk.space-${version}.dmg" \
   "dist/freedisk.space-${version}-macos-universal.dmg"
```

The existing `.github/workflows/release.yml` workflow only builds the macOS
artifact and requires the Apple signing/notarization secrets listed in that
file. It uploads an Actions artifact but does not create a GitHub Release or
build Windows.

## Publish one combined GitHub release

Before tagging, ensure both platforms were built from the same commit:

```bash
git status
git rev-parse HEAD
```

Create and push the version tag:

```bash
version="$(tr -d '[:space:]' < VERSION)"
git tag -a "v${version}" -m "freedisk.space ${version}"
git push origin "v${version}"
```

Create a draft release from Windows and upload the Windows executable:

```powershell
$version = (Get-Content .\VERSION -Raw).Trim()
$exe = ".\dist\windows-$version-x64\freedisk.space-$version-windows-x64.exe"

gh release create "v$version" $exe `
    --verify-tag `
    --draft `
    --title "freedisk.space $version" `
    --generate-notes
```

Upload the notarized macOS DMG to the same draft from the Mac:

```bash
version="$(tr -d '[:space:]' < VERSION)"
gh release upload "v${version}" \
  "dist/freedisk.space-${version}-macos-universal.dmg"
```

Confirm both assets appear in the draft and test-download each one. Publish the
release only after both artifacts pass their final smoke test:

```bash
gh release edit "v${version}" --draft=false
```

Expected assets:

```text
freedisk.space-<version>-macos-universal.dmg
freedisk.space-<version>-windows-x64.exe
```
