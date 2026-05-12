<#
.SYNOPSIS
    Builds the Ambient Context MCP MCPB bundle (framework-dependent, win-x64).

.DESCRIPTION
    Publishes the tray app and the stdio bridge as framework-dependent
    binaries (.NET 8 Desktop Runtime / Runtime must be installed on the
    target machine), assembles the MCPB layout under dist/mcpb-staging,
    and packs it into dist/ambient-context-mcp-<version>.mcpb.

    Prefers `mcpb pack` from @anthropic-ai/mcpb if available; falls back
    to Compress-Archive otherwise.

.PARAMETER Version
    Bundle version. Defaults to the value in mcpb/manifest.json.

.PARAMETER Runtime
    .NET RID. Defaults to win-x64. (Tray currently targets net8.0-windows
    so only win-x64 / win-arm64 are meaningful.)

.EXAMPLE
    pwsh tools\build-mcpb.ps1
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$Runtime = "win-x64"
)

$ErrorActionPreference = "Stop"

$repoRoot      = Resolve-Path (Join-Path $PSScriptRoot "..")
$manifestPath  = Join-Path $repoRoot "mcpb\manifest.json"
$trayProject   = Join-Path $repoRoot "src\windows\AmbientContextMcp\AmbientContextMcp.csproj"
$bridgeProject = Join-Path $repoRoot "src\windows\AmbientContextMcp.StdioBridge\AmbientContextMcp.StdioBridge.csproj"
$staging       = Join-Path $repoRoot "dist\mcpb-staging"
$serverDir     = Join-Path $staging "server"
$distRoot      = Join-Path $repoRoot "dist"

if (-not $Version) {
    $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
    $Version  = $manifest.version
}

Write-Host "Building MCPB bundle ambient-context-mcp v$Version ($Runtime)" -ForegroundColor Cyan

if (Test-Path $staging) {
    Remove-Item -Recurse -Force $staging
}
New-Item -ItemType Directory -Force -Path $serverDir | Out-Null

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
        -o $OutDir `
        --nologo `
        -v quiet
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed for $Project"
    }
}

# Both projects publish into the SAME server/ directory. Shared DLLs collapse
# naturally; mismatched versions of the same DLL would be a build error we'd
# want to see, not silently mask.
Invoke-Publish -Project $trayProject   -OutDir $serverDir
Invoke-Publish -Project $bridgeProject -OutDir $serverDir

# Strip pdb/xml docs to keep the bundle small.
Get-ChildItem $serverDir -Recurse -Include *.pdb,*.xml | Remove-Item -Force

# Copy manifest. (icon.png is optional and not yet present.)
Copy-Item $manifestPath (Join-Path $staging "manifest.json") -Force
$iconPath = Join-Path $repoRoot "mcpb\icon.png"
if (Test-Path $iconPath) {
    Copy-Item $iconPath (Join-Path $staging "icon.png") -Force
}

$bundlePath = Join-Path $distRoot "ambient-context-mcp-$Version.mcpb"
if (Test-Path $bundlePath) {
    Remove-Item $bundlePath -Force
}

$mcpbCli = Get-Command mcpb -ErrorAction SilentlyContinue
if ($mcpbCli) {
    Write-Host "Packing with mcpb CLI..." -ForegroundColor Cyan
    Push-Location $staging
    try {
        & mcpb validate manifest.json
        if ($LASTEXITCODE -ne 0) { throw "mcpb validate failed." }
        & mcpb pack . $bundlePath
        if ($LASTEXITCODE -ne 0) { throw "mcpb pack failed." }
    }
    finally {
        Pop-Location
    }
} else {
    Write-Host "mcpb CLI not found; falling back to Compress-Archive (no manifest validation)." -ForegroundColor Yellow
    $zipPath = [System.IO.Path]::ChangeExtension($bundlePath, ".zip")
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zipPath -CompressionLevel Optimal
    Move-Item $zipPath $bundlePath -Force
}

$bundleSize = (Get-Item $bundlePath).Length
$sha256     = (Get-FileHash $bundlePath -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Host ""
Write-Host "Bundle:  $bundlePath" -ForegroundColor Green
Write-Host "Size:    $([math]::Round($bundleSize / 1MB, 2)) MB ($bundleSize bytes)"
Write-Host "SHA-256: $sha256"
