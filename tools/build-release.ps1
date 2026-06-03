<#
.SYNOPSIS
    Produces both the zip and the .mcpb release artifacts for Ambient Context MCP.

.DESCRIPTION
    Runs `dotnet build -c Release` for the tray (`AmbientContextMcp.Desktop`) and
    the stdio bridge (`AmbientContextMcp.StdioBridge`) into a shared staging server/
    dir, then assembles two artifacts from the same output. (build, NOT publish:
    `dotnet publish` drops the WinUI 3 compiled XAML (.xbf) and resource index (.pri)
    for unpackaged apps, which broke the settings window in v0.7.0.)

      dist/ambient-context-mcp-v<Version>-win-x64.zip
          Flat layout, same as historical v0.x releases. Suitable for
          `claude mcp add` / Streamable HTTP users; just unzip and run
          ambient-mcp.exe.

      dist/ambient-context-mcp-v<Version>.mcpb
          MCPB bundle with manifest.json at the root and binaries under server/.
          Drag & drop into Claude Desktop.

    Uses the `mcpb` CLI when available to validate the manifest and pack;
    falls back to Compress-Archive otherwise (no manifest validation).

.PARAMETER Version
    Bundle / release version (without leading 'v'). Defaults to the value in
    mcpb/manifest.json. Also forwarded to MSBuild as -p:Version=<value> so the
    produced .exe / .dll embed it.

.PARAMETER Runtime
    .NET RID. Defaults to win-x64.

.PARAMETER SkipZip
    Skip producing the .zip artifact.

.PARAMETER SkipMcpb
    Skip producing the .mcpb artifact.

.EXAMPLE
    pwsh tools\build-release.ps1
    pwsh tools\build-release.ps1 -Version 0.4.0
    pwsh tools\build-release.ps1 -SkipZip   # mcpb only
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$Runtime = "win-x64",
    [switch]$SkipZip,
    [switch]$SkipMcpb
)

$ErrorActionPreference = "Stop"

$repoRoot      = Resolve-Path (Join-Path $PSScriptRoot "..")
$manifestPath  = Join-Path $repoRoot "mcpb\manifest.json"
$trayProject   = Join-Path $repoRoot "src\windows\AmbientContextMcp.Desktop\AmbientContextMcp.Desktop.csproj"
$bridgeProject = Join-Path $repoRoot "src\windows\AmbientContextMcp.StdioBridge\AmbientContextMcp.StdioBridge.csproj"
$distRoot      = Join-Path $repoRoot "dist"
$staging       = Join-Path $distRoot "release-staging"
$serverDir     = Join-Path $staging "server"

if (-not $Version) {
    $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
    $Version  = $manifest.version
}

Write-Host "Building Ambient Context MCP release v$Version ($Runtime)" -ForegroundColor Cyan

if (Test-Path $staging) {
    Remove-Item -Recurse -Force $staging
}
New-Item -ItemType Directory -Force -Path $serverDir | Out-Null
New-Item -ItemType Directory -Force -Path $distRoot  | Out-Null

# Use `dotnet build`, NOT `dotnet publish`. For unpackaged WinUI 3, `dotnet publish`
# drops the compiled XAML (App.xbf / Settings/SettingsWindow.xbf) and the resource
# index (ambient-mcp.pri), so XAML-defined windows throw XamlParseException at runtime
# (this broke the settings window in v0.7.0). `dotnet build` emits them. The app is
# framework-dependent (WindowsPackageType=None / WindowsAppSDKSelfContained=false live
# in the csproj), so the build output is a complete, runnable bundle.
function Invoke-BuildToServer {
    param(
        [string]$Project,
        [string]$OutDir,
        [string[]]$ExtraArgs = @()
    )
    Write-Host "  build $([System.IO.Path]::GetFileNameWithoutExtension($Project))" -ForegroundColor DarkGray
    & dotnet build $Project `
        -c Release `
        -p:Version=$Version `
        -o $OutDir `
        --nologo `
        -v quiet `
        @ExtraArgs
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build failed for $Project"
    }
}

# Both projects build into the SAME server/ directory. The tray is x64-only
# (Platforms=x64); the bridge is AnyCPU. Shared managed DLLs collapse naturally
# (identical NuGet versions), and the tray's win-x64 native DLLs are untouched by the
# AnyCPU bridge build.
Invoke-BuildToServer -Project $trayProject   -OutDir $serverDir -ExtraArgs @('-p:Platform=x64')
Invoke-BuildToServer -Project $bridgeProject -OutDir $serverDir

# Strip pdb/xml docs to keep both artifacts small.
Get-ChildItem $serverDir -Recurse -Include *.pdb,*.xml | Remove-Item -Force

$zipPath  = Join-Path $distRoot "ambient-context-mcp-v$Version-win-x64.zip"
$mcpbPath = Join-Path $distRoot "ambient-context-mcp-v$Version.mcpb"

# --- .zip (flat layout — matches v0.1.0..v0.3.0 releases) -------------------
if (-not $SkipZip) {
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Write-Host "Packing zip..." -ForegroundColor Cyan
    Compress-Archive -Path (Join-Path $serverDir "*") -DestinationPath $zipPath -CompressionLevel Optimal
}

# --- .mcpb (manifest.json + server/) ----------------------------------------
if (-not $SkipMcpb) {
    # Copy manifest into staging (next to server/) for mcpb pack to pick up.
    Copy-Item $manifestPath (Join-Path $staging "manifest.json") -Force
    $iconPath = Join-Path $repoRoot "mcpb\icon.png"
    if (Test-Path $iconPath) {
        Copy-Item $iconPath (Join-Path $staging "icon.png") -Force
    }

    if (Test-Path $mcpbPath) { Remove-Item $mcpbPath -Force }

    $mcpbCli = Get-Command mcpb -ErrorAction SilentlyContinue
    if ($mcpbCli) {
        Write-Host "Packing mcpb with CLI (validates manifest)..." -ForegroundColor Cyan
        Push-Location $staging
        try {
            & mcpb validate manifest.json
            if ($LASTEXITCODE -ne 0) { throw "mcpb validate failed." }
            & mcpb pack . $mcpbPath
            if ($LASTEXITCODE -ne 0) { throw "mcpb pack failed." }
        }
        finally {
            Pop-Location
        }
    } else {
        Write-Host "mcpb CLI not found; falling back to Compress-Archive (no manifest validation)." -ForegroundColor Yellow
        $tmpZip = [System.IO.Path]::ChangeExtension($mcpbPath, ".zip")
        if (Test-Path $tmpZip) { Remove-Item $tmpZip -Force }
        Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $tmpZip -CompressionLevel Optimal
        Move-Item $tmpZip $mcpbPath -Force
    }
}

# --- Summary ----------------------------------------------------------------
Write-Host ""
Write-Host "Artifacts:" -ForegroundColor Green
foreach ($path in @($zipPath, $mcpbPath)) {
    if (-not (Test-Path $path)) { continue }
    $size = (Get-Item $path).Length
    $hash = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host ("  {0}" -f $path)
    Write-Host ("    size:    {0} MB ({1} bytes)" -f ([math]::Round($size / 1MB, 2)), $size)
    Write-Host ("    sha256:  {0}" -f $hash)
}
