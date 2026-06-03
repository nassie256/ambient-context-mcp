<#
.SYNOPSIS
    Produces both the zip and the .mcpb release artifacts for Ambient Context MCP.

.DESCRIPTION
    Runs `dotnet publish` once for the tray (`AmbientContextMcp`) and the stdio
    bridge (`AmbientContextMcp.StdioBridge`) into a shared staging server/ dir,
    then assembles two artifacts from the same output:

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

function Invoke-Publish {
    param(
        [string]$Project,
        [string]$OutDir
    )
    Write-Host "  publish $([System.IO.Path]::GetFileNameWithoutExtension($Project))" -ForegroundColor DarkGray
    & dotnet publish $Project `
        -c Release `
        -r $Runtime `
        --self-contained false `
        -p:PublishSingleFile=false `
        -p:WindowsPackageType=None `
        -p:WindowsAppSDKSelfContained=false `
        -p:PublishReadyToRun=false `
        -p:Version=$Version `
        -o $OutDir `
        --nologo `
        -v quiet
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed for $Project"
    }
}

# Both projects publish into the SAME server/ directory. Shared DLLs collapse
# naturally; mismatched versions of the same DLL would surface as a build error,
# which we want to see rather than silently mask.
Invoke-Publish -Project $trayProject   -OutDir $serverDir
Invoke-Publish -Project $bridgeProject -OutDir $serverDir

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
