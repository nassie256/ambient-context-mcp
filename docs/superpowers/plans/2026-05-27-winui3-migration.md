# WinUI 3 Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `src/windows/AmbientContextMcp` の WPF + WinForms UI を破棄し、新規 `AmbientContextMcp.Desktop` (WinUI 3, Windows App SDK) に置き換える。NVIDIA Optimus 機での D3D9 Blocking 警告を解消し、Fluent / Mica の Windows 11 ネイティブ外観へ移行する。

**Architecture:** `Microsoft.NET.Sdk` + `UseWinUI=true` + `FrameworkReference Microsoft.AspNetCore.App` で WinUI 3 と ASP.NET Core MCP サーバを 1 プロセスに同居させる。`Host.CreateApplicationBuilder` を主軸とし、Kestrel/Capture/Tray を `IHostedService` として登録。Unpackaged 配布 + Bootstrapper (Runtime 同梱なし) で zip 解凍運用を維持。

**Tech Stack:** WinUI 3 (`Microsoft.WindowsAppSDK` 1.6.*), `H.NotifyIcon.WinUI` 2.*, ASP.NET Core 8 (FrameworkReference), `Microsoft.Extensions.Hosting`, .resw localization, .NET 8 (`net8.0-windows10.0.19041.0`).

**Reference spec:** `docs/superpowers/specs/2026-05-27-winui3-migration-design.md`

---

## File Structure

### 新規作成

```
src/windows/AmbientContextMcp.Desktop/
├─ AmbientContextMcp.Desktop.csproj
├─ app.manifest                              (現行から移動)
├─ Program.cs                                (Main = STA + Bootstrap + Application.Start)
├─ App.xaml                                  (WinUI 3 Application)
├─ App.xaml.cs                               (Host.CreateApplicationBuilder, DI 登録, Tray 起動)
├─ Bootstrap/
│  └─ RuntimeBootstrap.cs                    (MddBootstrap.TryInitialize ラッパー + MessageBox)
├─ Hosting/
│  └─ McpKestrelHostedService.cs             (WebApplication を IHostedService 化)
├─ Tray/
│  ├─ TrayService.cs                         (TaskbarIcon を保持、メニュー操作 API)
│  └─ TrayIcon.xaml(.cs)                     (H.NotifyIcon.WinUI TaskbarIcon + MenuFlyout)
├─ Settings/
│  ├─ SettingsWindow.xaml                    (Window + Pivot + 各タブ、x:Uid 参照)
│  ├─ SettingsWindow.xaml.cs                 (AppWindow API, DI コンストラクタ, 各イベント)
│  ├─ SettingsWindowPlacement.cs             (現行から移動・WinUI 3 AppWindow API に書き換え)
│  ├─ ClipboardHelper.cs                     (現行から移動・WinUI 3 Clipboard API)
│  ├─ TransmissionGroupViewModel.cs          (現行から移動・無改変)
│  └─ TransmissionOptionViewModel.cs         (現行から移動・無改変)
├─ Resources/
│  ├─ AppIcon.ico                            (現行から移動)
│  ├─ Strings.resw                           (en-US, 既定 fallback)
│  ├─ ja-JP/
│  │  └─ Strings.resw                        (日本語)
│  └─ StringsLoader.cs                       (ResourceLoader ラッパー、コード参照用)
├─ AmbientContext/                           (現行から全ファイル移動・無改変)
├─ Autostart/AutostartManager.cs             (現行から移動・無改変)
├─ Mcp/                                      (現行から全ファイル移動・無改変)
└─ Win32/                                    (現行から全ファイル移動・無改変)
```

### 削除

```
src/windows/AmbientContextMcp/                   (フォルダごと削除)
```

### 変更

```
src/windows/AmbientContextMcp.sln                (AmbientContextMcp → AmbientContextMcp.Desktop)
.github/workflows/release.yml                    (csproj target & artifact 命名)
CLAUDE.local.md                                  (UI 文字列規約を .resw 方式に)
README.md / README.en.md                         (Runtime インストール手順追加)
docs/windows-implementation.md                   (WinUI 3 前提に書き換え)
docs/screenshots/*.png                           (Mica/Fluent で再撮影)
```

---

## Task 1: Feature ブランチ作成と baseline 確認

**Files:**
- なし (環境準備のみ)

- [ ] **Step 1: feature ブランチを切る**

```bash
git checkout main
git pull --ff-only
git checkout -b feature/winui3-migration
```

- [ ] **Step 2: 現行コードのビルド確認 (baseline)**

```bash
dotnet build src/windows/AmbientContextMcp.sln -c Debug
```

Expected: ビルド成功、warning は WFAC010 抑止済み。

- [ ] **Step 3: 現行テスト実行 (baseline)**

```bash
dotnet test src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj -c Debug
```

Expected: 全テストパス。失敗があれば main 側のバグなので、本プランの前に修正。

---

## Task 2: AmbientContextMcp.Desktop csproj スケルトン作成

**Files:**
- Create: `src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj`
- Create: `src/windows/AmbientContextMcp.Desktop/app.manifest` (現行 `src/windows/AmbientContextMcp/app.manifest` をコピー)
- Create: `src/windows/AmbientContextMcp.Desktop/Program.cs`
- Create: `src/windows/AmbientContextMcp.Desktop/App.xaml`
- Create: `src/windows/AmbientContextMcp.Desktop/App.xaml.cs`
- Modify: `src/windows/AmbientContextMcp.sln`

- [ ] **Step 1: csproj を作成**

`src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0-windows10.0.19041.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <OutputType>WinExe</OutputType>
    <UseWinUI>true</UseWinUI>
    <WindowsPackageType>None</WindowsPackageType>
    <WindowsAppSDKSelfContained>false</WindowsAppSDKSelfContained>
    <ApplicationManifest>app.manifest</ApplicationManifest>
    <ApplicationIcon>Resources\AppIcon.ico</ApplicationIcon>
    <AssemblyName>ambient-mcp</AssemblyName>
    <RootNamespace>AmbientContextMcp</RootNamespace>
    <EnableMsixTooling>false</EnableMsixTooling>
  </PropertyGroup>

  <PropertyGroup Condition="'$(Configuration)' == 'Release'">
    <DebugType>none</DebugType>
    <DebugSymbols>false</DebugSymbols>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.WindowsAppSDK" Version="1.6.*" />
    <PackageReference Include="H.NotifyIcon.WinUI" Version="2.*" />
    <PackageReference Include="ModelContextProtocol.AspNetCore" Version="1.2.0" />
    <FrameworkReference Include="Microsoft.AspNetCore.App" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\AmbientContextMcp.Core\AmbientContextMcp.Core.csproj" />
  </ItemGroup>
</Project>
```

- [ ] **Step 2: app.manifest をコピー**

```bash
cp src/windows/AmbientContextMcp/app.manifest src/windows/AmbientContextMcp.Desktop/app.manifest
```

manifest の中身は無変更。PerMonitorV2 宣言は Capture 側で `EnumDisplayMonitors` を使うため引き続き必要。

- [ ] **Step 3: Resources/AppIcon.ico をコピー**

```bash
mkdir -p src/windows/AmbientContextMcp.Desktop/Resources
cp src/windows/AmbientContextMcp/Resources/AppIcon.ico src/windows/AmbientContextMcp.Desktop/Resources/AppIcon.ico
```

- [ ] **Step 4: 最小 App.xaml を作成**

`src/windows/AmbientContextMcp.Desktop/App.xaml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<Application
    x:Class="AmbientContextMcp.App"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <Application.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
                <XamlControlsResources xmlns="using:Microsoft.UI.Xaml.Controls" />
            </ResourceDictionary.MergedDictionaries>
        </ResourceDictionary>
    </Application.Resources>
</Application>
```

- [ ] **Step 5: 最小 App.xaml.cs を作成**

`src/windows/AmbientContextMcp.Desktop/App.xaml.cs`:

```csharp
using Microsoft.UI.Xaml;

namespace AmbientContextMcp;

public partial class App : Application
{
    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Phase 1 では何もしない (Task 4 で Host を組み立てる)
    }
}
```

- [ ] **Step 6: 最小 Program.cs を作成 (Bootstrap は Task 3 で追加)**

`src/windows/AmbientContextMcp.Desktop/Program.cs`:

```csharp
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace AmbientContextMcp;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(
                DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
        return 0;
    }
}
```

- [ ] **Step 7: sln に Desktop プロジェクトを追加**

```bash
dotnet sln src/windows/AmbientContextMcp.sln add src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj
```

- [ ] **Step 8: ビルド確認**

```bash
dotnet build src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj -c Debug
```

Expected: 復元成功、ビルド成功。WinUI 3 関連の警告が多少出る可能性あり (CsWinRT, x86_64 関連) は無視可。

- [ ] **Step 9: Commit**

```bash
git add src/windows/AmbientContextMcp.Desktop/ src/windows/AmbientContextMcp.sln
git commit -m "feat(desktop): scaffold AmbientContextMcp.Desktop WinUI 3 csproj"
```

---

## Task 3: Bootstrapper (RuntimeBootstrap)

**Files:**
- Create: `src/windows/AmbientContextMcp.Desktop/Bootstrap/RuntimeBootstrap.cs`
- Modify: `src/windows/AmbientContextMcp.Desktop/Program.cs`

- [ ] **Step 1: RuntimeBootstrap.cs を作成**

`src/windows/AmbientContextMcp.Desktop/Bootstrap/RuntimeBootstrap.cs`:

```csharp
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Windows.ApplicationModel.DynamicDependency;

namespace AmbientContextMcp.Bootstrap;

public static class RuntimeBootstrap
{
    private const uint MinMajor = 1;
    private const uint MinMinor = 6;
    private const string DownloadUrl =
        "https://aka.ms/windowsappsdk/1.6/latest/windowsappruntimeinstall-x64.exe";

    public static bool TryInitialize(out string? error)
    {
        try
        {
            Microsoft.Windows.ApplicationModel.DynamicDependency.Bootstrap.Initialize(MinMajor);
            error = null;
            return true;
        }
        catch (Exception ex)
        {
            error = $"Windows App Runtime {MinMajor}.{MinMinor}+ is required. ({ex.GetType().Name}: {ex.Message})";
            return false;
        }
    }

    public static void Shutdown()
    {
        try
        {
            Microsoft.Windows.ApplicationModel.DynamicDependency.Bootstrap.Shutdown();
        }
        catch
        {
            // Bootstrapper 未初期化時の Shutdown は無視。
        }
    }

    public static void ShowMissingRuntimeMessage(string error)
    {
        const uint MB_OKCANCEL = 0x00000001;
        const uint MB_ICONERROR = 0x00000010;
        const int IDOK = 1;

        var message =
            "Ambient Context MCP requires Windows App Runtime.\n\n" +
            error + "\n\n" +
            "Press OK to open the download page, or Cancel to exit.";

        var result = MessageBoxW(IntPtr.Zero, message, "Ambient Context MCP", MB_OKCANCEL | MB_ICONERROR);
        if (result == IDOK)
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = DownloadUrl,
                    UseShellExecute = true
                });
            }
            catch
            {
                // ブラウザ起動失敗は無視。ユーザーは URL を README で確認できる。
            }
        }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string lpText, string lpCaption, uint uType);
}
```

- [ ] **Step 2: Program.cs を Bootstrap 統合版に更新**

`src/windows/AmbientContextMcp.Desktop/Program.cs`:

```csharp
using AmbientContextMcp.Bootstrap;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace AmbientContextMcp;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (!RuntimeBootstrap.TryInitialize(out var error))
        {
            RuntimeBootstrap.ShowMissingRuntimeMessage(error ?? "Unknown error");
            return 1;
        }

        try
        {
            Application.Start(_ =>
            {
                var context = new DispatcherQueueSynchronizationContext(
                    DispatcherQueue.GetForCurrentThread());
                SynchronizationContext.SetSynchronizationContext(context);
                _ = new App();
            });
        }
        finally
        {
            RuntimeBootstrap.Shutdown();
        }
        return 0;
    }
}
```

- [ ] **Step 3: ビルド確認**

```bash
dotnet build src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj -c Debug
```

Expected: ビルド成功。

- [ ] **Step 4: 動作確認 (Runtime インストール済み環境)**

```bash
dotnet run --project src/windows/AmbientContextMcp.Desktop -c Debug
```

Expected: 空ウィンドウなし (App.OnLaunched が何もしないため)、プロセスは生きている (Application.Start がブロック)。Ctrl+C で終了。

- [ ] **Step 5: Commit**

```bash
git add src/windows/AmbientContextMcp.Desktop/Bootstrap/ src/windows/AmbientContextMcp.Desktop/Program.cs
git commit -m "feat(desktop): add Windows App Runtime bootstrapper"
```

---

## Task 4: 既存コードの移植 (無改変分)

**Files:** 全てコピー (rename ではなく copy。元ファイルは Task 13 で削除)

- Create (copy from existing):
  - `src/windows/AmbientContextMcp.Desktop/AmbientContext/*.cs` (14 ファイル)
  - `src/windows/AmbientContextMcp.Desktop/Autostart/AutostartManager.cs`
  - `src/windows/AmbientContextMcp.Desktop/Mcp/McpAuthenticationMiddleware.cs`
  - `src/windows/AmbientContextMcp.Desktop/Mcp/McpClientSnippets.cs`
  - `src/windows/AmbientContextMcp.Desktop/Mcp/McpServerHost.cs`
  - `src/windows/AmbientContextMcp.Desktop/Win32/DisplayEnumerator.cs`
  - `src/windows/AmbientContextMcp.Desktop/Win32/MessageOnlyWindow.cs`
  - `src/windows/AmbientContextMcp.Desktop/Win32/MessageWindowSynchronizationContext.cs`
  - `src/windows/AmbientContextMcp.Desktop/Settings/TransmissionGroupViewModel.cs`
  - `src/windows/AmbientContextMcp.Desktop/Settings/TransmissionOptionViewModel.cs`

- [ ] **Step 1: ディレクトリを作成してファイルをコピー**

```bash
cd src/windows/AmbientContextMcp.Desktop
mkdir -p AmbientContext Autostart Mcp Win32 Settings

cp ../AmbientContextMcp/AmbientContext/*.cs AmbientContext/
cp ../AmbientContextMcp/Autostart/*.cs Autostart/
cp ../AmbientContextMcp/Mcp/*.cs Mcp/
cp ../AmbientContextMcp/Win32/*.cs Win32/
cp ../AmbientContextMcp/Settings/TransmissionGroupViewModel.cs Settings/
cp ../AmbientContextMcp/Settings/TransmissionOptionViewModel.cs Settings/

cd ../../..
```

- [ ] **Step 2: ビルド確認 (現時点では namespace 衝突で失敗する)**

```bash
dotnet build src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj -c Debug
```

Expected: コンパイルエラー多数。**両 csproj が同じ namespace `AmbientContextMcp.*` で同じクラスを定義しているため**、sln 全体ビルドで重複エラーが出る可能性。Desktop csproj 単体ビルドは通る (元の csproj は参照していないため)。

- [ ] **Step 3: ファイル内の `using AmbientContextMcp.Resources;` を一旦コメントアウト**

`Mcp/McpClientSnippets.cs` などで `using AmbientContextMcp.Resources;` を参照している箇所はある場合に備え grep:

```bash
grep -rn "using AmbientContextMcp.Resources" src/windows/AmbientContextMcp.Desktop/
```

ヒットしたファイルは Task 6 (Strings 移植) まで一時的にコメントアウト。 `Strings.XXX` 参照箇所は同様にコメントアウト or 仮文字列に置換。

実際のヒット: `Tray/TrayHost.cs` と `Settings/SettingsWindow.xaml.cs` (これらは Desktop には未コピーなので影響なし)、`Program.cs` (旧版、Desktop の Program.cs ではない)。

確認後、Desktop 側で参照箇所がないか:

```bash
grep -rn "AmbientContextMcp\.Resources\|Strings\." src/windows/AmbientContextMcp.Desktop/ --include="*.cs"
```

Expected: ヒットなし (TrayHost / SettingsWindow / Program は未コピー)。

- [ ] **Step 4: Desktop 単体ビルド確認**

```bash
dotnet build src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj -c Debug
```

Expected: ビルド成功 (移植コードは AmbientContextMcp.Core への参照のみで完結している)。

- [ ] **Step 5: sln 全体ビルドを試す (失敗想定)**

```bash
dotnet build src/windows/AmbientContextMcp.sln -c Debug
```

Expected: 失敗。同じ型を 2 つの csproj で定義しているため。これは Task 13 で旧 csproj 削除時に解消する。**この時点では Desktop 単体ビルドが通れば OK**。

- [ ] **Step 6: Commit**

```bash
git add src/windows/AmbientContextMcp.Desktop/AmbientContext/ src/windows/AmbientContextMcp.Desktop/Autostart/ src/windows/AmbientContextMcp.Desktop/Mcp/ src/windows/AmbientContextMcp.Desktop/Win32/ src/windows/AmbientContextMcp.Desktop/Settings/
git commit -m "feat(desktop): port unchanged code (AmbientContext, Mcp, Win32, Autostart, ViewModels)"
```

---

## Task 5: Generic Host と DI 統合

**Files:**
- Modify: `src/windows/AmbientContextMcp.Desktop/App.xaml.cs`

- [ ] **Step 1: App.xaml.cs に Host 構築ロジックを追加**

`src/windows/AmbientContextMcp.Desktop/App.xaml.cs` を以下に置換:

```csharp
using System.Globalization;
using AmbientContextMcp.AmbientContext;
using AmbientContextMcp.Autostart;
using AmbientContextMcp.Core.Diagnostics;
using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Settings;
using AmbientContextMcp.Mcp;
using AmbientContextMcp.Win32;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.UI.Xaml;

namespace AmbientContextMcp;

public partial class App : Application
{
    private IHost? _host;

    public App()
    {
        InitializeComponent();
    }

    public IServiceProvider Services => _host?.Services
        ?? throw new InvalidOperationException("Host not started.");

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var settingsStore = new JsonFileSettingsStore();
        AppDiagnosticLog.Configure(settingsStore.SettingsPath);
        AppDiagnosticLog.Log("app", "startup", new Dictionary<string, object?>
        {
            ["settingsPath"] = settingsStore.SettingsPath
        });

        ApplyUiCulture(settingsStore.LoadUiSettings());

        var mcpHost = new McpServerHost(settingsStore);

        var builder = Host.CreateApplicationBuilder();
        builder.Services.AddSingleton<ISettingsStore>(settingsStore);
        builder.Services.AddSingleton(mcpHost);
        builder.Services.AddSingleton<MessageOnlyWindow>();
        builder.Services.AddSingleton<LocalContextHub>();
        builder.Services.AddSingleton<WindowsAmbientContextService>();
        builder.Services.AddSingleton<AutostartManager>();
        builder.Services.AddHostedService<AmbientContextHostedService>();
        // Tray / Kestrel は後続 Task で追加

        _host = builder.Build();
        WireSnapshotForwarding(_host.Services);
        await _host.StartAsync();
    }

    private static void ApplyUiCulture(UiSettings ui)
    {
        if (string.IsNullOrWhiteSpace(ui.Language)) return;
        try
        {
            var culture = CultureInfo.GetCultureInfo(ui.Language);
            CultureInfo.DefaultThreadCurrentUICulture = culture;
            Thread.CurrentThread.CurrentUICulture = culture;
        }
        catch (CultureNotFoundException)
        {
        }
    }

    private static void WireSnapshotForwarding(IServiceProvider services)
    {
        var collector = services.GetRequiredService<WindowsAmbientContextService>();
        var hub = services.GetRequiredService<LocalContextHub>();
        // Tray の Pause 状態は Task 7 で接続。現時点は無条件 Ingest。
        collector.SnapshotUpdated += (_, snapshot) => hub.Ingest(snapshot);
    }
}
```

- [ ] **Step 2: ビルド確認**

```bash
dotnet build src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj -c Debug
```

Expected: ビルド成功。

- [ ] **Step 3: 動作確認 (Capture が動作するか)**

```bash
dotnet run --project src/windows/AmbientContextMcp.Desktop -c Debug
```

別ターミナルから `%LOCALAPPDATA%\AmbientContextMcp\ambient-context.json` を確認:

```bash
ls -la "$env:LOCALAPPDATA/AmbientContextMcp/"
```

Expected: `ambient-context.json` が更新されている (60 秒以内に capture が走る)。Ctrl+C で終了。

- [ ] **Step 4: Commit**

```bash
git add src/windows/AmbientContextMcp.Desktop/App.xaml.cs
git commit -m "feat(desktop): wire Generic Host with Capture/Autostart/Settings DI"
```

---

## Task 6: ローカライズ - Strings.resw + StringsLoader

**Files:**
- Create: `src/windows/AmbientContextMcp.Desktop/Resources/Strings.resw`
- Create: `src/windows/AmbientContextMcp.Desktop/Resources/ja-JP/Strings.resw`
- Create: `src/windows/AmbientContextMcp.Desktop/Resources/StringsLoader.cs`

70 個のリソースキーを 2 ロケール分作成する。キー名は現行 `Strings.cs` のプロパティ名を踏襲。

- [ ] **Step 1: Strings.resw (en-US, 既定) を作成**

`src/windows/AmbientContextMcp.Desktop/Resources/Strings.resw`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<root>
  <resheader name="resmimetype"><value>text/microsoft-resx</value></resheader>
  <resheader name="version"><value>2.0</value></resheader>
  <resheader name="reader"><value>System.Resources.ResXResourceReader, System.Windows.Forms</value></resheader>
  <resheader name="writer"><value>System.Resources.ResXResourceWriter, System.Windows.Forms</value></resheader>

  <!-- Window / Tabs (XAML から x:Uid 経由で参照) -->
  <data name="WindowTitle.Text"><value>Ambient Context MCP — Settings</value></data>
  <data name="TabMcpServer.Header"><value>MCP Server</value></data>
  <data name="TabTransmission.Header"><value>Transmission</value></data>

  <!-- MCP Server group -->
  <data name="McpServerGroup.Text"><value>MCP Server</value></data>
  <data name="LabelStatus.Text"><value>Status</value></data>
  <data name="LabelEndpoint.Text"><value>Endpoint</value></data>
  <data name="LabelToken.Text"><value>Token</value></data>
  <data name="LabelPort.Text"><value>Port</value></data>
  <data name="ButtonCopyEndpoint.Content"><value>Copy</value></data>
  <data name="ButtonCopyToken.Content"><value>Copy</value></data>
  <data name="PortChangeNote.Text"><value>Changes apply after restart</value></data>
  <data name="AutoStartCheckbox.Content"><value>Start automatically on Windows login</value></data>
  <data name="PersistEventLogCheckbox.Content"><value>Persist event history to disk</value></data>
  <data name="PersistEventLogNote.Text"><value>Keeps history across restarts within the retention window.</value></data>
  <data name="CopyClaudeCodeSnippetButton.Content"><value>Copy Claude Code config snippet</value></data>

  <!-- Language picker -->
  <data name="LabelLanguage.Text"><value>Display language</value></data>
  <data name="LanguageSystemDefault.Content"><value>System default</value></data>
  <data name="LanguageJapanese.Content"><value>Japanese (日本語)</value></data>
  <data name="LanguageEnglish.Content"><value>English</value></data>

  <!-- Transmission tab -->
  <data name="TransmissionExplanation.Text"><value>Check the contexts you allow MCP clients to read. Unchecked items are never transmitted, even if a client requests a higher scope.</value></data>
  <data name="AllowAllCheckbox.Content"><value>Allow every context</value></data>
  <data name="EventHistoryGroup.Text"><value>Event history</value></data>
  <data name="LabelRetention.Text"><value>Retention</value></data>
  <data name="LabelMaxCount.Text"><value>Max events</value></data>
  <data name="Retention1Hour.Content"><value>1 hour</value></data>
  <data name="Retention6Hours.Content"><value>6 hours</value></data>
  <data name="Retention24Hours.Content"><value>24 hours</value></data>
  <data name="Retention7Days.Content"><value>7 days</value></data>
  <data name="Count100.Content"><value>100</value></data>
  <data name="Count500.Content"><value>500</value></data>
  <data name="Count1000.Content"><value>1,000</value></data>
  <data name="Count5000.Content"><value>5,000</value></data>

  <!-- Bottom buttons -->
  <data name="ButtonSave.Content"><value>Save</value></data>
  <data name="ButtonClose.Content"><value>Close</value></data>

  <!-- Code から取得するもの (StringsLoader 経由) -->
  <data name="StatusSaved"><value>Saved. Transmission settings take effect at the next context refresh. Port changes apply after restart.</value></data>
  <data name="StatusSavedNeedsRestart"><value>Saved. Language and port changes take effect after restart.</value></data>
  <data name="StatusClaudeCodeCopied"><value>Copied the Claude Code command to the clipboard.</value></data>
  <data name="StatusMcpRunningFormat"><value>Running :{0}</value></data>

  <!-- Tray menu -->
  <data name="TraySettings"><value>Settings...</value></data>
  <data name="TrayCopyMcpUrl"><value>Copy MCP URL</value></data>
  <data name="TrayCopyMcpToken"><value>Copy MCP token</value></data>
  <data name="TrayCopyClaudeCodeSnippet"><value>Copy Claude Code config</value></data>
  <data name="TrayPause"><value>Pause</value></data>
  <data name="TrayResume"><value>Resume</value></data>
  <data name="TrayPausedSuffix"><value> (paused)</value></data>
  <data name="TrayExit"><value>Exit</value></data>

  <!-- Transmission groups -->
  <data name="TxGroupForegroundApp"><value>Foreground app</value></data>
  <data name="TxGroupActivity"><value>Work rhythm</value></data>
  <data name="TxGroupMedia"><value>Media</value></data>
  <data name="TxGroupEnvironment"><value>Environment</value></data>

  <!-- Transmission UI labels -->
  <data name="TxUiForegroundIdentity"><value>Work category, name, and process (current value + switch notifications)</value></data>
  <data name="TxUiForegroundTitleSummary"><value>Title summary (current value + change history)</value></data>
  <data name="TxUiForegroundRawTitle"><value>Raw title (current value + change history)</value></data>
  <data name="TxUiActivitySwitchRate"><value>Switch rate (current value)</value></data>
  <data name="TxUiActivitySwitchBurst"><value>Switch burst (notification)</value></data>
  <data name="TxUiMediaOverview"><value>Playback presence, status, and source (current value + playback notifications)</value></data>
  <data name="TxUiMediaTitle"><value>Title (current value + change history)</value></data>
  <data name="TxUiMediaArtist"><value>Artist (current value + change history)</value></data>
  <data name="TxUiMediaAlbum"><value>Album (current value + change history)</value></data>
  <data name="TxUiEnvironmentTimezone"><value>Time zone (current value + change notifications)</value></data>
  <data name="TxUiEnvironmentDisplays"><value>Display layout (current value + change notifications)</value></data>

  <!-- Legacy per-path labels (TxOpt*) -->
  <data name="TxOptForegroundCategory"><value>Foreground app work category</value></data>
  <data name="TxOptForegroundAppName"><value>Foreground app name</value></data>
  <data name="TxOptForegroundProcessName"><value>Foreground app process name</value></data>
  <data name="TxOptForegroundTitleSummary"><value>Foreground window title summary</value></data>
  <data name="TxOptForegroundRawWindowTitle"><value>Foreground window raw title</value></data>
  <data name="TxOptEventForegroundChanged"><value>Foreground app switch event (includes app and process name)</value></data>
  <data name="TxOptEventForegroundTitleChanged"><value>Foreground window title change event (includes app context)</value></data>
  <data name="TxOptEventForegroundTitleChangedSummary"><value>Foreground window title change event: summary</value></data>
  <data name="TxOptEventForegroundTitleChangedRaw"><value>Foreground window title change event: raw title</value></data>
  <data name="TxOptActivityContextSwitches"><value>Foreground app switch rate</value></data>
  <data name="TxOptEventContextSwitchBurst"><value>Foreground app switch burst event</value></data>
  <data name="TxOptMediaIsAvailable"><value>Media session presence</value></data>
  <data name="TxOptMediaPlaybackStatus"><value>Media playback status</value></data>
  <data name="TxOptMediaSourceApp"><value>Media source app</value></data>
  <data name="TxOptMediaTitle"><value>Media title</value></data>
  <data name="TxOptMediaArtist"><value>Media artist</value></data>
  <data name="TxOptMediaAlbumTitle"><value>Media album</value></data>
  <data name="TxOptEventMediaPlaybackStarted"><value>Media playback started event</value></data>
  <data name="TxOptEventMediaPlaybackPaused"><value>Media playback paused event</value></data>
  <data name="TxOptEventMediaSessionChanged"><value>Media session changed event</value></data>
  <data name="TxOptEventMediaSessionChangedTitle"><value>Media session changed: title</value></data>
  <data name="TxOptEventMediaSessionChangedArtist"><value>Media session changed: artist</value></data>
  <data name="TxOptEventMediaSessionChangedAlbumTitle"><value>Media session changed: album</value></data>
  <data name="TxOptSystemTimeZone"><value>Time zone</value></data>
  <data name="TxOptDisplayCount"><value>Display count</value></data>
  <data name="TxOptDisplays"><value>Display layout</value></data>

  <!-- Startup error -->
  <data name="StartupErrorFormat"><value>Ambient Context MCP failed to start.

{0}

Port {1} may be in use by another process. Edit mcpServer.port in %LOCALAPPDATA%\AmbientContextMcp\settings.json, or delete the file and restart.</value></data>
</root>
```

- [ ] **Step 2: ja-JP/Strings.resw を作成 (日本語)**

`src/windows/AmbientContextMcp.Desktop/Resources/ja-JP/Strings.resw`:

en-US と同じキーで、`<value>` を日本語にする。具体的な対応は現行 `Strings.cs:T("日本語", "English")` の左側を採用。例:

```xml
<?xml version="1.0" encoding="utf-8"?>
<root>
  <resheader name="resmimetype"><value>text/microsoft-resx</value></resheader>
  <resheader name="version"><value>2.0</value></resheader>
  <resheader name="reader"><value>System.Resources.ResXResourceReader, System.Windows.Forms</value></resheader>
  <resheader name="writer"><value>System.Resources.ResXResourceWriter, System.Windows.Forms</value></resheader>

  <data name="WindowTitle.Text"><value>Ambient Context MCP 設定</value></data>
  <data name="TabMcpServer.Header"><value>MCPサーバ</value></data>
  <data name="TabTransmission.Header"><value>送信設定</value></data>
  <data name="McpServerGroup.Text"><value>MCP サーバ</value></data>
  <data name="LabelStatus.Text"><value>状態</value></data>
  <data name="LabelEndpoint.Text"><value>Endpoint</value></data>
  <data name="LabelToken.Text"><value>Token</value></data>
  <data name="LabelPort.Text"><value>ポート</value></data>
  <data name="ButtonCopyEndpoint.Content"><value>コピー</value></data>
  <data name="ButtonCopyToken.Content"><value>コピー</value></data>
  <data name="PortChangeNote.Text"><value>変更はアプリ再起動後に反映</value></data>
  <data name="AutoStartCheckbox.Content"><value>Windows ログイン時に自動起動</value></data>
  <data name="PersistEventLogCheckbox.Content"><value>イベント履歴をディスクに保存する</value></data>
  <data name="PersistEventLogNote.Text"><value>再起動後も保持期間内の履歴を保てます。</value></data>
  <data name="CopyClaudeCodeSnippetButton.Content"><value>Claude Code 用設定スニペットをコピー</value></data>

  <data name="LabelLanguage.Text"><value>表示言語</value></data>
  <data name="LanguageSystemDefault.Content"><value>システムに従う</value></data>
  <data name="LanguageJapanese.Content"><value>日本語</value></data>
  <data name="LanguageEnglish.Content"><value>English</value></data>

  <data name="TransmissionExplanation.Text"><value>MCPクライアントへ公開してよいコンテキストにチェックを入れてください。未チェックの項目は、クライアントが高い権限を要求しても送信されません。</value></data>
  <data name="AllowAllCheckbox.Content"><value>すべてのコンテキストを許可する</value></data>
  <data name="EventHistoryGroup.Text"><value>イベント履歴</value></data>
  <data name="LabelRetention.Text"><value>保持期間</value></data>
  <data name="LabelMaxCount.Text"><value>最大件数</value></data>
  <data name="Retention1Hour.Content"><value>1時間</value></data>
  <data name="Retention6Hours.Content"><value>6時間</value></data>
  <data name="Retention24Hours.Content"><value>24時間</value></data>
  <data name="Retention7Days.Content"><value>7日</value></data>
  <data name="Count100.Content"><value>100件</value></data>
  <data name="Count500.Content"><value>500件</value></data>
  <data name="Count1000.Content"><value>1000件</value></data>
  <data name="Count5000.Content"><value>5000件</value></data>

  <data name="ButtonSave.Content"><value>保存</value></data>
  <data name="ButtonClose.Content"><value>閉じる</value></data>

  <data name="StatusSaved"><value>保存しました。送信設定は次回の文脈更新から反映されます。ポート変更はアプリ再起動後に有効になります。</value></data>
  <data name="StatusSavedNeedsRestart"><value>保存しました。言語とポートの変更はアプリ再起動後に反映されます。</value></data>
  <data name="StatusClaudeCodeCopied"><value>Claude Code 用のコマンドをクリップボードにコピーしました。</value></data>
  <data name="StatusMcpRunningFormat"><value>起動中 :{0}</value></data>

  <data name="TraySettings"><value>設定...</value></data>
  <data name="TrayCopyMcpUrl"><value>MCP URL をコピー</value></data>
  <data name="TrayCopyMcpToken"><value>MCP トークンをコピー</value></data>
  <data name="TrayCopyClaudeCodeSnippet"><value>Claude Code 用設定をコピー</value></data>
  <data name="TrayPause"><value>一時停止</value></data>
  <data name="TrayResume"><value>再開</value></data>
  <data name="TrayPausedSuffix"><value> (一時停止中)</value></data>
  <data name="TrayExit"><value>終了</value></data>

  <data name="TxGroupForegroundApp"><value>フォアグラウンドアプリ</value></data>
  <data name="TxGroupActivity"><value>作業リズム</value></data>
  <data name="TxGroupMedia"><value>メディア</value></data>
  <data name="TxGroupEnvironment"><value>環境</value></data>

  <data name="TxUiForegroundIdentity"><value>作業カテゴリ・名前・プロセス名（現在値 + 切替通知）</value></data>
  <data name="TxUiForegroundTitleSummary"><value>タイトル要約（現在値 + 変更履歴）</value></data>
  <data name="TxUiForegroundRawTitle"><value>タイトル原文（現在値 + 変更履歴）</value></data>
  <data name="TxUiActivitySwitchRate"><value>切替頻度（現在値）</value></data>
  <data name="TxUiActivitySwitchBurst"><value>切替急増（通知）</value></data>
  <data name="TxUiMediaOverview"><value>再生の有無・状態・再生元（現在値 + 再生通知）</value></data>
  <data name="TxUiMediaTitle"><value>タイトル（現在値 + 変更履歴）</value></data>
  <data name="TxUiMediaArtist"><value>アーティスト（現在値 + 変更履歴）</value></data>
  <data name="TxUiMediaAlbum"><value>アルバム（現在値 + 変更履歴）</value></data>
  <data name="TxUiEnvironmentTimezone"><value>タイムゾーン（現在値 + 変更通知）</value></data>
  <data name="TxUiEnvironmentDisplays"><value>ディスプレイ構成（現在値 + 変更通知）</value></data>

  <data name="TxOptForegroundCategory"><value>フォアグラウンドアプリの作業カテゴリ</value></data>
  <data name="TxOptForegroundAppName"><value>フォアグラウンドアプリ名</value></data>
  <data name="TxOptForegroundProcessName"><value>フォアグラウンドアプリのプロセス名</value></data>
  <data name="TxOptForegroundTitleSummary"><value>フォアグラウンドウィンドウのタイトル要約</value></data>
  <data name="TxOptForegroundRawWindowTitle"><value>フォアグラウンドウィンドウのタイトル原文</value></data>
  <data name="TxOptEventForegroundChanged"><value>フォアグラウンドアプリ切替イベント (アプリ名・プロセス名込み)</value></data>
  <data name="TxOptEventForegroundTitleChanged"><value>フォアグラウンドウィンドウのタイトル変更イベント (アプリ文脈込み)</value></data>
  <data name="TxOptEventForegroundTitleChangedSummary"><value>フォアグラウンドウィンドウのタイトル変更イベント: 要約</value></data>
  <data name="TxOptEventForegroundTitleChangedRaw"><value>フォアグラウンドウィンドウのタイトル変更イベント: 原文</value></data>
  <data name="TxOptActivityContextSwitches"><value>フォアグラウンドアプリ切替頻度</value></data>
  <data name="TxOptEventContextSwitchBurst"><value>フォアグラウンドアプリ切替増加イベント</value></data>
  <data name="TxOptMediaIsAvailable"><value>メディアセッション有無</value></data>
  <data name="TxOptMediaPlaybackStatus"><value>メディア再生状態</value></data>
  <data name="TxOptMediaSourceApp"><value>メディア再生元アプリ</value></data>
  <data name="TxOptMediaTitle"><value>メディアタイトル</value></data>
  <data name="TxOptMediaArtist"><value>メディアアーティスト</value></data>
  <data name="TxOptMediaAlbumTitle"><value>メディアアルバム</value></data>
  <data name="TxOptEventMediaPlaybackStarted"><value>メディア再生開始イベント</value></data>
  <data name="TxOptEventMediaPlaybackPaused"><value>メディア一時停止イベント</value></data>
  <data name="TxOptEventMediaSessionChanged"><value>メディアセッション変更イベント</value></data>
  <data name="TxOptEventMediaSessionChangedTitle"><value>メディアセッション変更イベント: タイトル</value></data>
  <data name="TxOptEventMediaSessionChangedArtist"><value>メディアセッション変更イベント: アーティスト</value></data>
  <data name="TxOptEventMediaSessionChangedAlbumTitle"><value>メディアセッション変更イベント: アルバム</value></data>
  <data name="TxOptSystemTimeZone"><value>タイムゾーン</value></data>
  <data name="TxOptDisplayCount"><value>ディスプレイ数</value></data>
  <data name="TxOptDisplays"><value>ディスプレイ構成</value></data>

  <data name="StartupErrorFormat"><value>Ambient Context MCP の起動に失敗しました。

{0}

ポート {1} が他プロセスで使用中の可能性があります。
%LOCALAPPDATA%\AmbientContextMcp\settings.json の mcpServer.port を変更するか、同ファイルを削除して再起動してください。</value></data>
</root>
```

- [ ] **Step 3: StringsLoader.cs を作成 (コード参照用ラッパー)**

`src/windows/AmbientContextMcp.Desktop/Resources/StringsLoader.cs`:

```csharp
using Microsoft.Windows.ApplicationModel.Resources;

namespace AmbientContextMcp.Resources;

/// <summary>
/// .resw リソースをコードから取得するヘルパー。XAML は x:Uid で直接参照するため
/// ここでは Tray / Status / StartupError などコードから必要なキーのみ提供。
/// </summary>
public static class StringsLoader
{
    // 既定の resource map (`Strings.resw`) を読む。引数なしコンストラクタが既定の
    // "Resources" subtree を解決する。`Resources/Strings.resw` および
    // `Resources/ja-JP/Strings.resw` は自動的に発見される。
    private static readonly ResourceLoader Loader = new ResourceLoader();

    public static string Get(string key) => Loader.GetString(key);

    public static string StatusSaved => Get("StatusSaved");
    public static string StatusSavedNeedsRestart => Get("StatusSavedNeedsRestart");
    public static string StatusClaudeCodeCopied => Get("StatusClaudeCodeCopied");
    public static string StatusMcpRunningFormat => Get("StatusMcpRunningFormat");

    public static string TraySettings => Get("TraySettings");
    public static string TrayCopyMcpUrl => Get("TrayCopyMcpUrl");
    public static string TrayCopyMcpToken => Get("TrayCopyMcpToken");
    public static string TrayCopyClaudeCodeSnippet => Get("TrayCopyClaudeCodeSnippet");
    public static string TrayPause => Get("TrayPause");
    public static string TrayResume => Get("TrayResume");
    public static string TrayPausedSuffix => Get("TrayPausedSuffix");
    public static string TrayExit => Get("TrayExit");

    public static string StartupErrorFormat => Get("StartupErrorFormat");

    // TransmissionGroupViewModel から参照する分
    public static string TxGroupForegroundApp => Get("TxGroupForegroundApp");
    public static string TxGroupActivity => Get("TxGroupActivity");
    public static string TxGroupMedia => Get("TxGroupMedia");
    public static string TxGroupEnvironment => Get("TxGroupEnvironment");
    public static string TxUiForegroundIdentity => Get("TxUiForegroundIdentity");
    public static string TxUiForegroundTitleSummary => Get("TxUiForegroundTitleSummary");
    public static string TxUiForegroundRawTitle => Get("TxUiForegroundRawTitle");
    public static string TxUiActivitySwitchRate => Get("TxUiActivitySwitchRate");
    public static string TxUiActivitySwitchBurst => Get("TxUiActivitySwitchBurst");
    public static string TxUiMediaOverview => Get("TxUiMediaOverview");
    public static string TxUiMediaTitle => Get("TxUiMediaTitle");
    public static string TxUiMediaArtist => Get("TxUiMediaArtist");
    public static string TxUiMediaAlbum => Get("TxUiMediaAlbum");
    public static string TxUiEnvironmentTimezone => Get("TxUiEnvironmentTimezone");
    public static string TxUiEnvironmentDisplays => Get("TxUiEnvironmentDisplays");
}
```

- [ ] **Step 4: TransmissionGroupViewModel.cs / TransmissionOptionViewModel.cs を StringsLoader 参照に書き換え**

両ファイルで `using AmbientContextMcp.Resources;` を保ち、`Strings.XXX` 参照を `StringsLoader.XXX` に置換 (1:1)。

```bash
grep -n "Strings\." src/windows/AmbientContextMcp.Desktop/Settings/TransmissionGroupViewModel.cs
```

ヒットした各 `Strings.XXX` を `StringsLoader.XXX` に置換。

- [ ] **Step 5: ビルド確認**

```bash
dotnet build src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj -c Debug
```

Expected: ビルド成功。

- [ ] **Step 6: スモークテスト (en-US / ja-JP 切替)**

```bash
dotnet run --project src/windows/AmbientContextMcp.Desktop -c Debug
```

起動後 (Capture が走ったら) `%LOCALAPPDATA%\AmbientContextMcp\settings.json` を編集して `"ui": { "language": "ja" }` を入れ、再起動。アプリ自体の UI はまだないので、`TransmissionGroupViewModel.CreateAll()` を一時的に Program.cs から呼んで結果をログ出力する検証は省略可。**.resw のロード自体は Task 9 の SettingsWindow 表示で確認**。

- [ ] **Step 7: Commit**

```bash
git add src/windows/AmbientContextMcp.Desktop/Resources/ src/windows/AmbientContextMcp.Desktop/Settings/TransmissionGroupViewModel.cs src/windows/AmbientContextMcp.Desktop/Settings/TransmissionOptionViewModel.cs
git commit -m "feat(desktop): add .resw localization (en-US, ja-JP) with StringsLoader"
```

---

## Task 7: TrayService (H.NotifyIcon.WinUI) - 構造と 8 メニュー

**Files:**
- Create: `src/windows/AmbientContextMcp.Desktop/Tray/TrayIcon.xaml`
- Create: `src/windows/AmbientContextMcp.Desktop/Tray/TrayIcon.xaml.cs`
- Create: `src/windows/AmbientContextMcp.Desktop/Tray/TrayService.cs`
- Modify: `src/windows/AmbientContextMcp.Desktop/App.xaml.cs`

- [ ] **Step 1: TrayIcon.xaml を作成**

`src/windows/AmbientContextMcp.Desktop/Tray/TrayIcon.xaml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<UserControl
    x:Class="AmbientContextMcp.Tray.TrayIcon"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:tb="using:H.NotifyIcon">
    <tb:TaskbarIcon
        x:Name="Icon"
        IconSource="ms-appx:///Resources/AppIcon.ico"
        ToolTipText="Ambient Context MCP"
        LeftClickCommand="{x:Bind OpenSettingsCommand}"
        NoLeftClickDelay="True">
        <tb:TaskbarIcon.ContextFlyout>
            <MenuFlyout>
                <MenuFlyoutItem x:Name="StatusItem" IsEnabled="False" />
                <MenuFlyoutSeparator />
                <MenuFlyoutItem x:Name="SettingsItem" Click="OnSettingsClick" />
                <MenuFlyoutSeparator />
                <MenuFlyoutItem x:Name="CopyUrlItem" Click="OnCopyUrlClick" />
                <MenuFlyoutItem x:Name="CopyTokenItem" Click="OnCopyTokenClick" />
                <MenuFlyoutItem x:Name="CopySnippetItem" Click="OnCopySnippetClick" />
                <MenuFlyoutSeparator />
                <MenuFlyoutItem x:Name="PauseResumeItem" Click="OnPauseResumeClick" />
                <MenuFlyoutSeparator />
                <MenuFlyoutItem x:Name="ExitItem" Click="OnExitClick" />
            </MenuFlyout>
        </tb:TaskbarIcon.ContextFlyout>
    </tb:TaskbarIcon>
</UserControl>
```

- [ ] **Step 2: TrayIcon.xaml.cs を作成**

`src/windows/AmbientContextMcp.Desktop/Tray/TrayIcon.xaml.cs`:

```csharp
using System.Globalization;
using System.Windows.Input;
using AmbientContextMcp.Core.Diagnostics;
using AmbientContextMcp.Mcp;
using AmbientContextMcp.Resources;
using Microsoft.UI.Xaml.Controls;

namespace AmbientContextMcp.Tray;

public sealed partial class TrayIcon : UserControl
{
    private readonly McpServerHost _mcpHost;
    private readonly Action _openSettings;
    private readonly Action _requestExit;
    private bool _paused;

    public TrayIcon(McpServerHost mcpHost, Action openSettings, Action requestExit)
    {
        _mcpHost = mcpHost;
        _openSettings = openSettings;
        _requestExit = requestExit;
        InitializeComponent();
        ApplyLabels();
        RefreshStatusText();
        OpenSettingsCommand = new RelayCommand(_ => _openSettings());
    }

    public ICommand OpenSettingsCommand { get; }

    public bool IsPaused => _paused;

    public void RefreshStatusText()
    {
        StatusItem.Text = GetStatusText();
    }

    private void ApplyLabels()
    {
        SettingsItem.Text = StringsLoader.TraySettings;
        CopyUrlItem.Text = StringsLoader.TrayCopyMcpUrl;
        CopyTokenItem.Text = StringsLoader.TrayCopyMcpToken;
        CopySnippetItem.Text = StringsLoader.TrayCopyClaudeCodeSnippet;
        PauseResumeItem.Text = _paused ? StringsLoader.TrayResume : StringsLoader.TrayPause;
        ExitItem.Text = StringsLoader.TrayExit;
    }

    private string GetStatusText()
    {
        var suffix = _paused ? StringsLoader.TrayPausedSuffix : "";
        return $"Ambient Context MCP — :{_mcpHost.Settings.Port}{suffix}";
    }

    private void OnSettingsClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        AppDiagnosticLog.Log("tray", "menu_settings_click");
        _openSettings();
    }

    private void OnCopyUrlClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e) =>
        ClipboardCopy.Safe(_mcpHost.McpUrl);

    private void OnCopyTokenClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e) =>
        ClipboardCopy.Safe(_mcpHost.Token);

    private void OnCopySnippetClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e) =>
        ClipboardCopy.Safe(McpClientSnippets.BuildClaudeCodeSnippet(_mcpHost.McpUrl, _mcpHost.Token));

    private void OnPauseResumeClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        _paused = !_paused;
        PauseResumeItem.Text = _paused ? StringsLoader.TrayResume : StringsLoader.TrayPause;
        RefreshStatusText();
    }

    private void OnExitClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        AppDiagnosticLog.Log("tray", "menu_exit_click");
        _requestExit();
    }

    private sealed class RelayCommand : ICommand
    {
        private readonly Action<object?> _execute;
        public RelayCommand(Action<object?> execute) => _execute = execute;
        public event EventHandler? CanExecuteChanged;
        public bool CanExecute(object? parameter) => true;
        public void Execute(object? parameter) => _execute(parameter);
    }
}

internal static class ClipboardCopy
{
    public static void Safe(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        try
        {
            var dp = new Windows.ApplicationModel.DataTransfer.DataPackage();
            dp.SetText(value);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(dp);
        }
        catch
        {
            // クリップボード排他に失敗した場合は best-effort で諦める。
        }
    }
}
```

- [ ] **Step 3: TrayService.cs を作成**

`src/windows/AmbientContextMcp.Desktop/Tray/TrayService.cs`:

```csharp
using AmbientContextMcp.Mcp;
using Microsoft.Extensions.Hosting;

namespace AmbientContextMcp.Tray;

public sealed class TrayService
{
    private readonly McpServerHost _mcpHost;
    private readonly IHostApplicationLifetime _lifetime;
    private TrayIcon? _icon;
    private Action? _openSettings;

    public TrayService(McpServerHost mcpHost, IHostApplicationLifetime lifetime)
    {
        _mcpHost = mcpHost;
        _lifetime = lifetime;
    }

    public bool IsPaused => _icon?.IsPaused ?? false;

    public void Show(Action openSettings)
    {
        _openSettings = openSettings;
        _icon = new TrayIcon(_mcpHost, openSettings, () => _lifetime.StopApplication());
    }

    public void RefreshStatus() => _icon?.RefreshStatusText();
}
```

- [ ] **Step 4: App.xaml.cs に TrayService 登録と起動を追加**

`OnLaunched` に追記:

```csharp
builder.Services.AddSingleton<TrayService>();
// (中略)
_host = builder.Build();
WireSnapshotForwarding(_host.Services);
await _host.StartAsync();
var tray = _host.Services.GetRequiredService<TrayService>();
tray.Show(OpenSettings);
```

そして `WireSnapshotForwarding` を Pause 対応に修正:

```csharp
private void WireSnapshotForwarding(IServiceProvider services)
{
    var collector = services.GetRequiredService<WindowsAmbientContextService>();
    var hub = services.GetRequiredService<LocalContextHub>();
    var tray = services.GetRequiredService<TrayService>();
    collector.SnapshotUpdated += (_, snapshot) =>
    {
        if (!tray.IsPaused) hub.Ingest(snapshot);
    };
}
```

`OpenSettings` メソッドのスタブを追加 (実装は Task 9 で):

```csharp
private void OpenSettings()
{
    // Task 9 で SettingsWindow を生成・表示
}
```

- [ ] **Step 5: ビルド確認**

```bash
dotnet build src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj -c Debug
```

Expected: ビルド成功。

- [ ] **Step 6: 動作確認**

```bash
dotnet run --project src/windows/AmbientContextMcp.Desktop -c Debug
```

Expected:
- トレイにアイコンが現れる
- 右クリックで 8 メニューが表示される (Settings... は押しても何も起きない)
- Copy URL / Copy Token / Copy Snippet が動作 (クリップボードに値が入る)
- Pause / Resume が切替わり、メニュー項目テキストと StatusItem が更新される
- Exit でアプリ終了

- [ ] **Step 7: Commit**

```bash
git add src/windows/AmbientContextMcp.Desktop/Tray/ src/windows/AmbientContextMcp.Desktop/App.xaml.cs
git commit -m "feat(desktop): add H.NotifyIcon.WinUI tray with 8-item menu"
```

---

## Task 8: McpKestrelHostedService

**Files:**
- Create: `src/windows/AmbientContextMcp.Desktop/Hosting/McpKestrelHostedService.cs`
- Modify: `src/windows/AmbientContextMcp.Desktop/App.xaml.cs`

- [ ] **Step 1: McpKestrelHostedService.cs を作成**

`src/windows/AmbientContextMcp.Desktop/Hosting/McpKestrelHostedService.cs`:

```csharp
using AmbientContextMcp.Core.Mcp;
using AmbientContextMcp.Core.Settings;
using AmbientContextMcp.Mcp;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace AmbientContextMcp.Hosting;

public sealed class McpKestrelHostedService : IHostedService
{
    private readonly McpServerHost _mcpHost;
    private readonly ISettingsStore _settingsStore;
    private WebApplication? _app;

    public McpKestrelHostedService(McpServerHost mcpHost, ISettingsStore settingsStore)
    {
        _mcpHost = mcpHost;
        _settingsStore = settingsStore;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        var builder = WebApplication.CreateBuilder();
        builder.WebHost.UseUrls(_mcpHost.BaseUrl);

        // 共有依存を Kestrel 側 DI にもシングルトン登録 (ブリッジ)
        builder.Services.AddSingleton(_mcpHost);
        builder.Services.AddSingleton(_settingsStore);

        builder.Services.AddMcpServer()
            .WithHttpTransport(options => options.Stateless = true)
            .WithTools<ContextTools>();

        _app = builder.Build();
        _app.UseMiddleware<McpAuthenticationMiddleware>();
        _app.MapMcp("/mcp");

        _app.Lifetime.ApplicationStarted.Register(() => _mcpHost.WriteDiscoveryFile());
        _app.Lifetime.ApplicationStopping.Register(McpServerHost.TryDeleteDiscoveryFile);

        await _app.StartAsync(cancellationToken);
    }

    public Task StopAsync(CancellationToken cancellationToken) =>
        _app?.StopAsync(cancellationToken) ?? Task.CompletedTask;
}
```

- [ ] **Step 2: App.xaml.cs で McpKestrelHostedService を登録**

`OnLaunched` の `builder.Services.AddHostedService<AmbientContextHostedService>();` の下に追記:

```csharp
builder.Services.AddHostedService<McpKestrelHostedService>();
```

- [ ] **Step 3: ビルド確認**

```bash
dotnet build src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj -c Debug
```

Expected: ビルド成功。

- [ ] **Step 4: 動作確認 (MCP エンドポイント)**

```bash
dotnet run --project src/windows/AmbientContextMcp.Desktop -c Debug
```

別ターミナルで:

```bash
curl -v http://127.0.0.1:<port>/mcp
```

Port は `%LOCALAPPDATA%\AmbientContextMcp\settings.json` の `mcpServer.port` で確認。

Expected: 401 か MCP プロトコル応答。`McpAuthenticationMiddleware` が動いていれば 401。

- [ ] **Step 5: Commit**

```bash
git add src/windows/AmbientContextMcp.Desktop/Hosting/ src/windows/AmbientContextMcp.Desktop/App.xaml.cs
git commit -m "feat(desktop): wrap Kestrel + MCP server as IHostedService"
```

---

## Task 9: SettingsWindow - 基本構造 (Window + Pivot + Mica + AppWindow)

**Files:**
- Create: `src/windows/AmbientContextMcp.Desktop/Settings/SettingsWindow.xaml`
- Create: `src/windows/AmbientContextMcp.Desktop/Settings/SettingsWindow.xaml.cs`
- Create: `src/windows/AmbientContextMcp.Desktop/Settings/SettingsWindowPlacement.cs` (WinUI 3 AppWindow API ベース)
- Create: `src/windows/AmbientContextMcp.Desktop/Settings/ClipboardHelper.cs`
- Modify: `src/windows/AmbientContextMcp.Desktop/App.xaml.cs` (OpenSettings 実装)

- [ ] **Step 1: SettingsWindow.xaml の骨格を作成 (タブの中身は Task 10/11 で埋める)**

`src/windows/AmbientContextMcp.Desktop/Settings/SettingsWindow.xaml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<Window
    x:Class="AmbientContextMcp.Settings.SettingsWindow"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <Grid Padding="12" RowSpacing="0">
        <Grid.RowDefinitions>
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" MinHeight="22" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <Pivot Grid.Row="0">
            <PivotItem x:Uid="TabMcpServer">
                <!-- Task 10 で内容を実装 -->
                <Grid x:Name="McpServerTabRoot" Padding="12" />
            </PivotItem>
            <PivotItem x:Uid="TabTransmission">
                <!-- Task 11 で内容を実装 -->
                <Grid x:Name="TransmissionTabRoot" Padding="12" />
            </PivotItem>
        </Pivot>

        <TextBlock Grid.Row="1"
                   x:Name="SettingsStatusText"
                   TextWrapping="Wrap"
                   VerticalAlignment="Center"
                   Margin="0,10,0,4" />

        <StackPanel Grid.Row="2"
                    Orientation="Horizontal"
                    HorizontalAlignment="Right"
                    Spacing="8"
                    Margin="0,4,0,0">
            <Button x:Name="SaveButton"
                    x:Uid="ButtonSave"
                    Click="OnSaveClick"
                    MinWidth="96"
                    Style="{ThemeResource AccentButtonStyle}" />
            <Button x:Name="CloseButton"
                    x:Uid="ButtonClose"
                    Click="OnCloseClick"
                    MinWidth="96" />
        </StackPanel>
    </Grid>
</Window>
```

- [ ] **Step 2: ClipboardHelper.cs を作成**

`src/windows/AmbientContextMcp.Desktop/Settings/ClipboardHelper.cs`:

```csharp
namespace AmbientContextMcp.Settings;

public static class ClipboardHelper
{
    public static void SafeCopy(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        try
        {
            var dp = new Windows.ApplicationModel.DataTransfer.DataPackage();
            dp.SetText(value);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(dp);
        }
        catch
        {
            // best-effort
        }
    }
}
```

- [ ] **Step 3: SettingsWindowPlacement.cs を WinUI 3 AppWindow ベースで作成**

`src/windows/AmbientContextMcp.Desktop/Settings/SettingsWindowPlacement.cs`:

```csharp
using AmbientContextMcp.Core.Settings;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;
using WinRT.Interop;

namespace AmbientContextMcp.Settings;

public static class SettingsWindowPlacement
{
    private const int DefaultWidth = 600;
    private const int DefaultHeight = 540;
    private const int MinWidth = 600;
    private const int MinHeight = 540;

    public static void Apply(Window window, ISettingsStore store)
    {
        var hwnd = WindowNative.GetWindowHandle(window);
        var id = Win32Interop.GetWindowIdFromWindow(hwnd);
        var appWindow = AppWindow.GetFromWindowId(id);

        // アイコンを設定
        appWindow.SetIcon("Resources/AppIcon.ico");

        // サイズを 600x540 に
        appWindow.Resize(new SizeInt32(DefaultWidth, DefaultHeight));

        // 中央配置
        var area = DisplayArea.GetFromWindowId(id, DisplayAreaFallback.Primary);
        var workArea = area.WorkArea;
        var x = workArea.X + (workArea.Width - DefaultWidth) / 2;
        var y = workArea.Y + (workArea.Height - DefaultHeight) / 2;
        appWindow.Move(new PointInt32(x, y));

        // Presenter
        if (appWindow.Presenter is OverlappedPresenter p)
        {
            p.IsResizable = true;
            p.IsMaximizable = false;
            p.IsMinimizable = false;
        }
    }

    public static void EnsureVisible(Window window)
    {
        var hwnd = WindowNative.GetWindowHandle(window);
        var id = Win32Interop.GetWindowIdFromWindow(hwnd);
        var appWindow = AppWindow.GetFromWindowId(id);
        if (appWindow.Presenter is OverlappedPresenter p && p.State == OverlappedPresenterState.Minimized)
        {
            p.Restore();
        }
        window.Activate();
    }
}
```

- [ ] **Step 4: SettingsWindow.xaml.cs を骨格作成**

`src/windows/AmbientContextMcp.Desktop/Settings/SettingsWindow.xaml.cs`:

```csharp
using AmbientContextMcp.AmbientContext;
using AmbientContextMcp.Autostart;
using AmbientContextMcp.Core.Diagnostics;
using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Settings;
using AmbientContextMcp.Mcp;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace AmbientContextMcp.Settings;

public sealed partial class SettingsWindow : Window
{
    private readonly ISettingsStore _settingsStore;
    private readonly McpServerHost _mcpHost;
    private readonly LocalContextHub _hub;
    private readonly WindowsAmbientContextService _collector;
    private readonly AutostartManager _autostart;
    private string _initialLanguage = "";

    public SettingsWindow(
        ISettingsStore settingsStore,
        McpServerHost mcpHost,
        LocalContextHub hub,
        WindowsAmbientContextService collector,
        AutostartManager autostart)
    {
        _settingsStore = settingsStore;
        _mcpHost = mcpHost;
        _hub = hub;
        _collector = collector;
        _autostart = autostart;

        InitializeComponent();
        SystemBackdrop = new MicaBackdrop();
        SettingsWindowPlacement.Apply(this, _settingsStore);

        // タブ内容は Task 10/11 で実装
        AppDiagnosticLog.Log("settings", "window_created");
        Closed += OnClosed;
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        AppDiagnosticLog.Log("settings", "window_closing");
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        // Task 12 で実装
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        Close();
    }
}
```

- [ ] **Step 5: App.xaml.cs の OpenSettings を実装**

`App.xaml.cs` に追記:

```csharp
using AmbientContextMcp.Settings;
using Microsoft.Extensions.DependencyInjection;

// (中略 OnLaunched 内 _host = builder.Build(); の直前)

private SettingsWindow? _settingsWindow;

private void OpenSettings()
{
    if (_settingsWindow is not null)
    {
        SettingsWindowPlacement.EnsureVisible(_settingsWindow);
        return;
    }
    _settingsWindow = ActivatorUtilities.CreateInstance<SettingsWindow>(_host!.Services);
    _settingsWindow.Closed += (_, _) => _settingsWindow = null;
    _settingsWindow.Activate();
}
```

- [ ] **Step 6: ビルド確認**

```bash
dotnet build src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj -c Debug
```

Expected: ビルド成功。

- [ ] **Step 7: 動作確認**

```bash
dotnet run --project src/windows/AmbientContextMcp.Desktop -c Debug
```

トレイの Settings... をクリック。

Expected:
- 600x540 のウィンドウが画面中央に表示
- Mica マテリアル背景
- タブ 2 つ (MCP Server / Transmission) が表示、中身は空
- Save / Close ボタンが下部に表示
- 多重クリックしても 1 つしか開かない、閉じてから再度開ける

- [ ] **Step 8: Commit**

```bash
git add src/windows/AmbientContextMcp.Desktop/Settings/ src/windows/AmbientContextMcp.Desktop/App.xaml.cs
git commit -m "feat(desktop): scaffold SettingsWindow with Mica + AppWindow placement"
```

---

## Task 10: SettingsWindow - MCP Server タブ

**Files:**
- Modify: `src/windows/AmbientContextMcp.Desktop/Settings/SettingsWindow.xaml`
- Modify: `src/windows/AmbientContextMcp.Desktop/Settings/SettingsWindow.xaml.cs`

- [ ] **Step 1: McpServer タブの XAML を実装**

`SettingsWindow.xaml` の `<Grid x:Name="McpServerTabRoot" Padding="12" />` を以下に置換:

```xml
<Grid x:Name="McpServerTabRoot" Padding="12" RowSpacing="0">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto" />
        <RowDefinition Height="Auto" />
    </Grid.RowDefinitions>

    <Border Grid.Row="0"
            BorderBrush="{ThemeResource CardStrokeColorDefaultBrush}"
            BorderThickness="1"
            CornerRadius="4"
            Padding="12">
        <Grid RowSpacing="8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="140" />
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
            </Grid.RowDefinitions>

            <TextBlock x:Uid="McpServerGroup" Grid.Row="0" Grid.ColumnSpan="3" FontWeight="SemiBold" Margin="0,0,0,4" />

            <TextBlock x:Uid="LabelStatus" Grid.Row="1" Grid.Column="0" VerticalAlignment="Center" />
            <TextBlock Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" x:Name="McpStatusText" VerticalAlignment="Center" />

            <TextBlock x:Uid="LabelEndpoint" Grid.Row="2" Grid.Column="0" VerticalAlignment="Center" />
            <TextBox Grid.Row="2" Grid.Column="1" x:Name="McpEndpointBox" IsReadOnly="True" Margin="0,0,8,0" />
            <Button x:Uid="ButtonCopyEndpoint" Grid.Row="2" Grid.Column="2" Click="OnCopyEndpointClick" MinWidth="64" />

            <TextBlock x:Uid="LabelToken" Grid.Row="3" Grid.Column="0" VerticalAlignment="Center" />
            <TextBox Grid.Row="3" Grid.Column="1" x:Name="McpTokenBox" IsReadOnly="True" Margin="0,0,8,0" />
            <Button x:Uid="ButtonCopyToken" Grid.Row="3" Grid.Column="2" Click="OnCopyTokenClick" MinWidth="64" />

            <TextBlock x:Uid="LabelPort" Grid.Row="4" Grid.Column="0" VerticalAlignment="Center" />
            <TextBox Grid.Row="4" Grid.Column="1" x:Name="McpPortBox" Margin="0,0,8,0" />
            <TextBlock x:Uid="PortChangeNote" Grid.Row="4" Grid.Column="2" VerticalAlignment="Center" FontSize="11" Foreground="{ThemeResource TextFillColorTertiaryBrush}" />

            <CheckBox x:Uid="AutoStartCheckbox" Grid.Row="5" Grid.ColumnSpan="3" x:Name="McpAutoStartCheckBox" Margin="0,4,0,0" />
            <CheckBox x:Uid="PersistEventLogCheckbox" Grid.Row="6" Grid.ColumnSpan="3" x:Name="PersistEventLogCheckBox" Margin="0,4,0,0" />
            <TextBlock x:Uid="PersistEventLogNote" Grid.Row="7" Grid.ColumnSpan="3" Margin="28,0,0,4" FontSize="11" Foreground="{ThemeResource TextFillColorTertiaryBrush}" />

            <Button x:Uid="CopyClaudeCodeSnippetButton" Grid.Row="8" Grid.ColumnSpan="3" x:Name="CopySnippetButton" Click="OnCopyClaudeCodeSnippetClick" HorizontalAlignment="Left" MinWidth="240" Margin="0,4,0,0" />
        </Grid>
    </Border>

    <Grid Grid.Row="1" Margin="0,12,0,0">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="140" />
            <ColumnDefinition Width="*" />
        </Grid.ColumnDefinitions>
        <TextBlock x:Uid="LabelLanguage" Grid.Column="0" VerticalAlignment="Center" />
        <ComboBox Grid.Column="1" x:Name="UiLanguageBox" SelectedValuePath="Tag" MinWidth="220" HorizontalAlignment="Left">
            <ComboBoxItem x:Uid="LanguageSystemDefault" Tag="" />
            <ComboBoxItem x:Uid="LanguageJapanese" Tag="ja" />
            <ComboBoxItem x:Uid="LanguageEnglish" Tag="en" />
        </ComboBox>
    </Grid>
</Grid>
```

- [ ] **Step 2: SettingsWindow.xaml.cs に MCP Server タブのロジックを実装**

`SettingsWindow.xaml.cs` の `SettingsWindow` ctor 内、`InitializeComponent()` の後に追加:

```csharp
LoadLocalContextSettings();
LoadUiSettings();
_initialLanguage = GetSelectedLanguage();
McpAutoStartCheckBox.IsChecked = _autostart.IsEnabled();
McpPortBox.Text = _mcpHost.Settings.Port.ToString(System.Globalization.CultureInfo.InvariantCulture);
RefreshMcpStatus();
```

メソッド追加:

```csharp
private void RefreshMcpStatus()
{
    McpStatusText.Text = string.Format(
        System.Globalization.CultureInfo.InvariantCulture,
        Resources.StringsLoader.StatusMcpRunningFormat,
        _mcpHost.Settings.Port);
    McpEndpointBox.Text = _mcpHost.McpUrl;
    McpTokenBox.Text = _mcpHost.Token;
}

private void OnCopyEndpointClick(object sender, RoutedEventArgs e) =>
    ClipboardHelper.SafeCopy(McpEndpointBox.Text);

private void OnCopyTokenClick(object sender, RoutedEventArgs e) =>
    ClipboardHelper.SafeCopy(McpTokenBox.Text);

private void OnCopyClaudeCodeSnippetClick(object sender, RoutedEventArgs e)
{
    ClipboardHelper.SafeCopy(McpClientSnippets.BuildClaudeCodeSnippet(_mcpHost.McpUrl, _mcpHost.Token));
    SettingsStatusText.Text = Resources.StringsLoader.StatusClaudeCodeCopied;
}

private void LoadLocalContextSettings()
{
    var settings = _settingsStore.LoadLocalContextSettings();
    PersistEventLogCheckBox.IsChecked = settings.PersistEventLog;
    // Retention / Count は Transmission タブで参照される
}

private void LoadUiSettings()
{
    var settings = _settingsStore.LoadUiSettings();
    var target = settings.Language ?? "";
    foreach (var item in UiLanguageBox.Items.OfType<Microsoft.UI.Xaml.Controls.ComboBoxItem>())
    {
        if (string.Equals(item.Tag?.ToString() ?? "", target, StringComparison.OrdinalIgnoreCase))
        {
            UiLanguageBox.SelectedItem = item;
            return;
        }
    }
    UiLanguageBox.SelectedIndex = 0;
}

private string GetSelectedLanguage() =>
    UiLanguageBox.SelectedValue?.ToString() ?? "";

private static int ParsePort(string text, int fallback)
{
    return int.TryParse(text, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var port) && port is > 0 and < 65536
        ? port : fallback;
}
```

必要な `using`:

```csharp
using AmbientContextMcp.Mcp;
using Microsoft.UI.Xaml.Controls;
```

- [ ] **Step 3: ビルド確認**

```bash
dotnet build src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj -c Debug
```

Expected: ビルド成功。

- [ ] **Step 4: 動作確認**

```bash
dotnet run --project src/windows/AmbientContextMcp.Desktop -c Debug
```

トレイ→ Settings... を開く。

Expected:
- MCP Server タブ: Status, Endpoint, Token, Port, AutoStart, PersistEventLog, Snippet コピー, 言語選択が表示
- Copy ボタンでクリップボードに値がコピーされる
- ja/en 切替で表示が変わる (起動時の locale により)

- [ ] **Step 5: Commit**

```bash
git add src/windows/AmbientContextMcp.Desktop/Settings/
git commit -m "feat(desktop): implement MCP Server tab in SettingsWindow"
```

---

## Task 11: SettingsWindow - Transmission タブ

**Files:**
- Modify: `src/windows/AmbientContextMcp.Desktop/Settings/SettingsWindow.xaml`
- Modify: `src/windows/AmbientContextMcp.Desktop/Settings/SettingsWindow.xaml.cs`

- [ ] **Step 1: Transmission タブの XAML を実装**

`SettingsWindow.xaml` の `<Grid x:Name="TransmissionTabRoot" Padding="12" />` を置換:

```xml
<Grid x:Name="TransmissionTabRoot" Padding="12" RowSpacing="0">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto" />
        <RowDefinition Height="Auto" />
        <RowDefinition Height="Auto" />
        <RowDefinition Height="*" />
    </Grid.RowDefinitions>

    <TextBlock x:Uid="TransmissionExplanation" Grid.Row="0" TextWrapping="Wrap" Margin="0,0,0,10" />

    <CheckBox x:Uid="AllowAllCheckbox"
              Grid.Row="1"
              x:Name="SelectAllTransmissionCheckBox"
              Click="OnToggleAllTransmissionClick"
              HorizontalAlignment="Left"
              Margin="0,0,0,8" />

    <Border Grid.Row="2"
            BorderBrush="{ThemeResource CardStrokeColorDefaultBrush}"
            BorderThickness="1"
            CornerRadius="4"
            Padding="10"
            Margin="0,0,0,10">
        <Grid>
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto" />
                <ColumnDefinition Width="150" />
                <ColumnDefinition Width="24" />
                <ColumnDefinition Width="Auto" />
                <ColumnDefinition Width="150" />
            </Grid.ColumnDefinitions>

            <TextBlock x:Uid="EventHistoryGroup" Grid.ColumnSpan="5" FontWeight="SemiBold" Margin="0,0,0,4" />
            <TextBlock x:Uid="LabelRetention" Grid.Column="0" VerticalAlignment="Center" Margin="0,16,8,0" />
            <ComboBox x:Name="EventRetentionHoursBox" Grid.Column="1" SelectedValuePath="Tag" MinWidth="130" Margin="0,16,0,0">
                <ComboBoxItem x:Uid="Retention1Hour" Tag="1" />
                <ComboBoxItem x:Uid="Retention6Hours" Tag="6" />
                <ComboBoxItem x:Uid="Retention24Hours" Tag="24" />
                <ComboBoxItem x:Uid="Retention7Days" Tag="168" />
            </ComboBox>
            <TextBlock x:Uid="LabelMaxCount" Grid.Column="3" VerticalAlignment="Center" Margin="0,16,8,0" />
            <ComboBox x:Name="EventRetentionCountBox" Grid.Column="4" SelectedValuePath="Tag" MinWidth="130" Margin="0,16,0,0">
                <ComboBoxItem x:Uid="Count100" Tag="100" />
                <ComboBoxItem x:Uid="Count500" Tag="500" />
                <ComboBoxItem x:Uid="Count1000" Tag="1000" />
                <ComboBoxItem x:Uid="Count5000" Tag="5000" />
            </ComboBox>
        </Grid>
    </Border>

    <Border Grid.Row="3"
            BorderBrush="{ThemeResource CardStrokeColorDefaultBrush}"
            BorderThickness="1"
            CornerRadius="4">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
            <ItemsControl x:Name="TransmissionGroupsList" Margin="8,8,14,8">
                <ItemsControl.ItemTemplate>
                    <DataTemplate>
                        <Border BorderBrush="{ThemeResource CardStrokeColorDefaultBrush}" BorderThickness="0,0,0,1" Padding="8,10,8,6" Margin="0,0,0,10">
                            <StackPanel>
                                <TextBlock Text="{Binding Title}" FontWeight="SemiBold" Margin="0,0,0,4" />
                                <ItemsControl ItemsSource="{Binding Options}">
                                    <ItemsControl.ItemTemplate>
                                        <DataTemplate>
                                            <Grid Padding="4,7" BorderThickness="0,0,0,1" BorderBrush="{ThemeResource ControlStrokeColorDefaultBrush}">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="Auto" />
                                                    <ColumnDefinition Width="*" />
                                                    <ColumnDefinition Width="88" />
                                                </Grid.ColumnDefinitions>
                                                <CheckBox Grid.Column="0"
                                                          IsChecked="{Binding IsAllowed, Mode=TwoWay}"
                                                          Click="OnTransmissionOptionClick"
                                                          VerticalAlignment="Center"
                                                          HorizontalAlignment="Left"
                                                          MinWidth="0"
                                                          Margin="0,0,10,0" />
                                                <TextBlock Grid.Column="1"
                                                           Text="{Binding Label}"
                                                           TextWrapping="Wrap"
                                                           VerticalAlignment="Center"
                                                           Margin="0,0,12,0" />
                                                <TextBlock Grid.Column="2"
                                                           Text="{Binding Sensitivity}"
                                                           HorizontalAlignment="Right"
                                                           VerticalAlignment="Center"
                                                           Margin="0,0,8,0" />
                                            </Grid>
                                        </DataTemplate>
                                    </ItemsControl.ItemTemplate>
                                </ItemsControl>
                            </StackPanel>
                        </Border>
                    </DataTemplate>
                </ItemsControl.ItemTemplate>
            </ItemsControl>
        </ScrollViewer>
    </Border>
</Grid>
```

- [ ] **Step 2: SettingsWindow.xaml.cs に Transmission タブのロジックを実装**

ctor 内に追加:

```csharp
_transmissionGroups = TransmissionGroupViewModel.CreateAll();
_transmissionOptions = _transmissionGroups.SelectMany(g => g.Options).ToList();
TransmissionGroupsList.ItemsSource = _transmissionGroups;
LoadTransmissionSettings();
RefreshSelectAllTransmissionCheckBox();

// イベント履歴 ComboBox の値設定
var localCtx = _settingsStore.LoadLocalContextSettings();
SelectComboBoxValue(EventRetentionHoursBox, localCtx.MaxEventAgeHours);
SelectComboBoxValue(EventRetentionCountBox, localCtx.MaxEventCount);
```

フィールド追加:

```csharp
private readonly List<TransmissionGroupViewModel> _transmissionGroups = new();
private readonly List<TransmissionOptionViewModel> _transmissionOptions = new();
```

メソッド追加:

```csharp
private void OnToggleAllTransmissionClick(object sender, RoutedEventArgs e)
{
    var allow = SelectAllTransmissionCheckBox.IsChecked == true;
    foreach (var option in _transmissionOptions) option.IsAllowed = allow;
    RefreshSelectAllTransmissionCheckBox();
}

private void OnTransmissionOptionClick(object sender, RoutedEventArgs e) =>
    RefreshSelectAllTransmissionCheckBox();

private void RefreshSelectAllTransmissionCheckBox()
{
    SelectAllTransmissionCheckBox.IsChecked =
        _transmissionOptions.Count > 0 && _transmissionOptions.All(o => o.IsAllowed);
}

private void LoadTransmissionSettings()
{
    var settings = _settingsStore.LoadAmbientTransmissionSettings();
    foreach (var option in _transmissionOptions)
    {
        option.IsAllowed = TransmissionUiSettingsMerge.IsOptionEnabled(
            option.PrimaryPath, settings.PathTransmitOverrides);
    }
}

private static void SelectComboBoxValue(Microsoft.UI.Xaml.Controls.ComboBox comboBox, int value)
{
    foreach (var item in comboBox.Items.OfType<Microsoft.UI.Xaml.Controls.ComboBoxItem>())
    {
        if (int.TryParse(item.Tag?.ToString(), out var tag) && tag == value)
        {
            comboBox.SelectedItem = item;
            return;
        }
    }
    comboBox.SelectedIndex = 0;
}

private static int GetComboBoxIntValue(Microsoft.UI.Xaml.Controls.ComboBox comboBox, int fallback)
{
    if (comboBox.SelectedValue is not null &&
        int.TryParse(comboBox.SelectedValue.ToString(), out var v)) return v;
    return fallback;
}
```

必要な using:

```csharp
using AmbientContextMcp.Core.Policy;
```

(`TransmissionUiSettingsMerge` は Core 側にある)

- [ ] **Step 3: ビルド確認**

```bash
dotnet build src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj -c Debug
```

Expected: ビルド成功。

- [ ] **Step 4: 動作確認**

```bash
dotnet run --project src/windows/AmbientContextMcp.Desktop -c Debug
```

設定→ Transmission タブに切替。

Expected:
- 説明文・全許可チェック・Retention/MaxCount ComboBox・グループ一覧が表示
- 各 CheckBox がトグル可能
- 全許可を切替えると個別もすべて切替わる
- スクロール可能

- [ ] **Step 5: Commit**

```bash
git add src/windows/AmbientContextMcp.Desktop/Settings/
git commit -m "feat(desktop): implement Transmission tab in SettingsWindow"
```

---

## Task 12: SettingsWindow - 保存・言語切替

**Files:**
- Modify: `src/windows/AmbientContextMcp.Desktop/Settings/SettingsWindow.xaml.cs`

- [ ] **Step 1: OnSaveClick を実装**

`SettingsWindow.xaml.cs` の `OnSaveClick` を置換:

```csharp
private void OnSaveClick(object sender, RoutedEventArgs e)
{
    AppDiagnosticLog.Log("settings", "save_begin");
    var startedAt = Environment.TickCount64;

    SaveMcpSettings();
    SaveTransmissionSettings();
    SaveLocalContextSettings();
    SaveUiSettings();
    ApplyAutostart();

    _collector.ReloadTransmissionPolicy();
    _hub.ReloadSettings();
    _mcpHost.ReloadSettings();

    var langChanged = !string.Equals(GetSelectedLanguage(), _initialLanguage, StringComparison.OrdinalIgnoreCase);
    SettingsStatusText.Text = langChanged
        ? Resources.StringsLoader.StatusSavedNeedsRestart
        : Resources.StringsLoader.StatusSaved;
    RefreshMcpStatus();

    AppDiagnosticLog.Log("settings", "save_end", new Dictionary<string, object?>
    {
        ["durationMs"] = Environment.TickCount64 - startedAt,
        ["languageChanged"] = langChanged
    });
}

private void SaveMcpSettings()
{
    var current = _mcpHost.Settings;
    var port = ParsePort(McpPortBox.Text, current.Port);
    _settingsStore.SaveMcpServerSettings(new McpServerSettings
    {
        SchemaVersion = 1,
        AutoStart = McpAutoStartCheckBox.IsChecked == true,
        Port = port,
        Token = current.Token
    });
}

private void ApplyAutostart()
{
    var enabled = McpAutoStartCheckBox.IsChecked == true;
    if (enabled) _autostart.Enable(AutostartManager.GetExecutablePath());
    else _autostart.Disable();
}

private void SaveTransmissionSettings()
{
    var settings = _settingsStore.LoadAmbientTransmissionSettings();
    var enabledIds = _transmissionOptions.Where(o => o.IsAllowed).Select(o => o.Id)
        .ToHashSet(StringComparer.OrdinalIgnoreCase);
    var catalogOptions = AmbientContextCatalog.GetTransmissionUiGroups()
        .SelectMany(g => g.Options).ToList();
    var overrides = TransmissionUiSettingsMerge.MergeOverrides(
        settings.PathTransmitOverrides, catalogOptions, enabledIds);

    AmbientTransmissionPolicy.Save(_settingsStore,
        new AmbientTransmissionSettings { SchemaVersion = 1, PathTransmitOverrides = overrides },
        WindowsAmbientContextService.GetPrivacyClassificationsForUi());
}

private void SaveLocalContextSettings()
{
    _settingsStore.SaveLocalContextSettings(new LocalContextSettings
    {
        SchemaVersion = 1,
        MaxEventAgeHours = GetComboBoxIntValue(EventRetentionHoursBox, 24),
        MaxEventCount = GetComboBoxIntValue(EventRetentionCountBox, 500),
        PersistEventLog = PersistEventLogCheckBox.IsChecked == true
    });
}

private void SaveUiSettings()
{
    var lang = GetSelectedLanguage();
    _settingsStore.SaveUiSettings(new UiSettings
    {
        SchemaVersion = 1,
        Language = lang
    });
    // 次回起動時に反映 (現在のウィンドウへは即時反映しない仕様 = 現行踏襲)
    Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride = lang ?? "";
}
```

必要な using:

```csharp
using AmbientContextMcp.Core.Models;
using AmbientContextMcp.Core.Policy;
using AmbientContextMcp.AmbientContext;
```

- [ ] **Step 2: ビルド確認**

```bash
dotnet build src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj -c Debug
```

Expected: ビルド成功。

- [ ] **Step 3: 動作確認 (保存と言語切替)**

```bash
dotnet run --project src/windows/AmbientContextMcp.Desktop -c Debug
```

Expected:
- 保存ボタンで設定が `%LOCALAPPDATA%\AmbientContextMcp\settings.json` に書き込まれる
- 言語を ja/en 切替えて保存→「再起動後反映」ステータス表示
- アプリ再起動後、UI 言語が切替わっている
- AutoStart 切替で `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` が更新
- Transmission タブの変更が `%LOCALAPPDATA%\AmbientContextMcp\settings.json` に反映

- [ ] **Step 4: Commit**

```bash
git add src/windows/AmbientContextMcp.Desktop/Settings/SettingsWindow.xaml.cs
git commit -m "feat(desktop): implement Save logic with language hot-restart marker"
```

---

## Task 13: 旧 AmbientContextMcp プロジェクトを削除

**Files:**
- Delete: `src/windows/AmbientContextMcp/` (フォルダ全体)
- Modify: `src/windows/AmbientContextMcp.sln`

- [ ] **Step 1: sln から旧 csproj を削除**

```bash
dotnet sln src/windows/AmbientContextMcp.sln remove src/windows/AmbientContextMcp/AmbientContextMcp.csproj
```

- [ ] **Step 2: 旧プロジェクトフォルダを削除**

```bash
git rm -r src/windows/AmbientContextMcp/
```

- [ ] **Step 3: sln 全体ビルド確認**

```bash
dotnet build src/windows/AmbientContextMcp.sln -c Debug
dotnet build src/windows/AmbientContextMcp.sln -c Release
```

Expected: 両構成ともビルド成功。

- [ ] **Step 4: テスト実行**

```bash
dotnet test src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj -c Debug
```

Expected: 全テストパス。

- [ ] **Step 5: Commit**

```bash
git add src/windows/AmbientContextMcp.sln
git commit -m "chore(desktop): remove legacy WPF AmbientContextMcp project"
```

---

## Task 14: GitHub Actions release.yml 更新

**Files:**
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: 現状の release.yml を確認**

```bash
cat .github/workflows/release.yml
```

ターゲット csproj 指定箇所 (`dotnet publish` コマンドや `path` 指定) を特定。

- [ ] **Step 2: csproj path を Desktop に置換**

`.github/workflows/release.yml` 内の以下を置換:

- `src/windows/AmbientContextMcp/AmbientContextMcp.csproj` → `src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj`
- `dotnet publish` コマンドのオプションを以下に統一:

```yaml
- name: Publish Desktop (WinUI 3)
  run: |
    dotnet publish src/windows/AmbientContextMcp.Desktop/AmbientContextMcp.Desktop.csproj `
      -c Release -r win-x64 `
      --self-contained true `
      /p:WindowsPackageType=None `
      /p:WindowsAppSDKSelfContained=false `
      /p:PublishReadyToRun=false `
      /p:PublishSingleFile=false `
      -o ${{ github.workspace }}/publish
```

- [ ] **Step 3: artifact 命名と zip 化コマンド更新**

zip 化の input ディレクトリは `publish/` のまま。出力ファイル名は `ambient-mcp-${{ github.ref_name }}-win-x64.zip` を維持。

- [ ] **Step 4: NuGet キャッシュキー更新**

`actions/cache@v4` の key に `Microsoft.WindowsAppSDK` を含めるよう、`hashFiles` 対象に Desktop の csproj を追加:

```yaml
key: nuget-${{ runner.os }}-${{ hashFiles('src/windows/**/*.csproj') }}
```

(既存と等価かもしれないが、Desktop csproj が確実に含まれることを確認)

- [ ] **Step 5: workflow 構文確認**

```bash
# act が入っていれば dry-run
act -j release --dry-run 2>/dev/null || echo "act not installed, skip dry-run"
```

少なくとも YAML 構文として通っているか:

```bash
python -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" && echo OK
```

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci(release): point release workflow at AmbientContextMcp.Desktop"
```

---

## Task 15: ドキュメント更新

**Files:**
- Modify: `CLAUDE.local.md`
- Modify: `README.md`
- Modify: `README.en.md`
- Modify: `docs/windows-implementation.md`

- [ ] **Step 1: CLAUDE.local.md を WinUI 3 / .resw 規約に更新**

`CLAUDE.local.md` 内の「UI 文字列のローカライズ」セクションを以下に置換:

```markdown
## UI 文字列のローカライズ

- アプリ内の表示文字列は `src/windows/AmbientContextMcp.Desktop/Resources/Strings.resw` (英語、既定) と `Resources/ja-JP/Strings.resw` (日本語) の 2 ファイルで管理する。
- 新規追加・変更は必ず両方のファイルに同じキーで追加する。片方だけ追加しない。
- XAML からは `x:Uid="<Key>"` で参照する (`Key.Text`, `Key.Content`, `Key.Header` などプロパティ別)。生文字列を書かない。
- コードからは `AmbientContextMcp.Resources.StringsLoader` 経由で取得する (例: `StringsLoader.StatusSaved`)。
- `PrivacyClassification.Reason` のような診断メッセージも同じく両ファイルで用意する。
- ロケールフォールバック方針: 日本語 OS 環境のみ日本語、それ以外は英語。明示切替は設定ダイアログ「表示言語」から (要再起動、`Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride` を設定)。
```

- [ ] **Step 2: README.md に Runtime インストール手順を追加**

`README.md` の「インストール」セクション (または近い見出し) に追記:

```markdown
### 前提: Windows App Runtime

Ambient Context MCP は Microsoft Windows App Runtime 1.6 以上を必要とします。
未インストールの場合、初回起動時にダイアログでダウンロードページを案内します。

事前に手動で入れる場合は以下から x64 版をインストールしてください:

https://aka.ms/windowsappsdk/1.6/latest/windowsappruntimeinstall-x64.exe
```

- [ ] **Step 3: README.en.md に同じ内容を英語で追加**

`README.en.md` の対応セクションに:

```markdown
### Prerequisite: Windows App Runtime

Ambient Context MCP requires Microsoft Windows App Runtime 1.6 or later.
On first launch, a dialog will direct you to the official download page if
the runtime is not installed.

To install it manually in advance, get the x64 installer here:

https://aka.ms/windowsappsdk/1.6/latest/windowsappruntimeinstall-x64.exe
```

- [ ] **Step 4: docs/windows-implementation.md を WinUI 3 ベースに更新**

WPF/WinForms 前提の記述を WinUI 3 + Generic Host + Unpackaged Bootstrapper に書き換える。具体的な diff は記述量が多いため、書き換え方針のみ:

- 「UI スタック: WPF (`SettingsWindow`) + WinForms (`NotifyIcon`)」→「UI スタック: WinUI 3 (`SettingsWindow`) + H.NotifyIcon.WinUI (`TaskbarIcon`)」
- 「起動: `WebApplication.CreateBuilder` 主軸 + WPF 別 STA スレッド」→「起動: `Program.Main` で `MddBootstrap.Initialize` → `Application.Start` → `App.OnLaunched` で `Host.CreateApplicationBuilder`、`McpKestrelHostedService` で Kestrel」
- 「ローカライズ: `Resources/Strings.cs` の `T()` ペア」→「ローカライズ: `Resources/Strings.resw` (en-US) と `Resources/ja-JP/Strings.resw` を `x:Uid` / `StringsLoader` で参照」
- 「配布: zip 同梱 self-contained」→「配布: zip 同梱 self-contained (.NET 8) + Windows App Runtime は別途インストール (Bootstrapper が誘導)」

- [ ] **Step 5: ドキュメント整合性確認**

```bash
grep -rn "WPF\|WinForms\|Strings\.cs\|TrayHost\|TrayHostedService" docs/ CLAUDE.local.md README.md README.en.md --include="*.md"
```

ヒットしたら、Step 1-4 で対処漏れがないか確認。歴史的な記述として残すべきものは「v0.6 以前は WPF だったが v0.7 で WinUI 3 に移行」のような形で残してもよい。

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.local.md README.md README.en.md docs/windows-implementation.md
git commit -m "docs: update for WinUI 3 migration (localization, runtime, architecture)"
```

---

## Task 16: スクリーンショット再撮影

**Files:**
- Modify: `docs/screenshots/*.png` (撮り直し)

- [ ] **Step 1: 現状のスクリーンショット一覧を確認**

```bash
ls docs/screenshots/ 2>/dev/null || ls docs/ | grep -i screenshot
```

存在する PNG ファイル名を控える。README で参照しているファイル名は変えない。

- [ ] **Step 2: アプリを起動して新 UI をキャプチャ**

手動作業:

1. `dotnet run --project src/windows/AmbientContextMcp.Desktop -c Release`
2. トレイから設定ダイアログを開く
3. MCP Server タブと Transmission タブそれぞれをキャプチャ (`Win+Shift+S` or Snipping Tool)
4. 既存ファイル名と同じ名前で `docs/screenshots/` に上書き

- [ ] **Step 3: README の画像参照が壊れていないか確認**

```bash
grep -E "\!\[.*\]\(docs/screenshots/" README.md README.en.md
```

参照ファイルが全て存在するかチェック:

```bash
for f in $(grep -oE "docs/screenshots/[^)]+" README.md | sort -u); do
  test -f "$f" && echo "OK: $f" || echo "MISSING: $f"
done
```

- [ ] **Step 4: Commit**

```bash
git add docs/screenshots/
git commit -m "docs(screenshots): retake with WinUI 3 (Mica/Fluent) UI"
```

---

## Task 17: 受け入れテスト (9 項目)

**Files:** なし (検証のみ)

仕様書 `docs/superpowers/specs/2026-05-27-winui3-migration-design.md` 末尾の「受け入れ条件」を全てチェックする。問題があれば該当 Task に戻って修正・追加 commit。

- [ ] **Step 1: Runtime 未インストール環境テスト**

別 Windows マシン (or VM) で:
1. Windows App Runtime 未インストール状態を確認
2. ambient-mcp.exe (zip 解凍版) を起動
3. MessageBox で「Runtime が必要」と表示され、OK で DL ページが開く

Expected: 仕様どおりの誘導。プロセスは exit 1 で終了。

- [ ] **Step 2: Runtime インストール済み環境テスト**

Runtime をインストール後に再度起動。

Expected: 正常起動、トレイにアイコン常駐、ウィンドウは表示されない (タスクトレイ常駐モード)。

- [ ] **Step 3: トレイメニュー 8 項目動作**

右クリックメニューから:
1. 状態 (`Ambient Context MCP — :<port>`) が表示 (無効化済み)
2. Settings... → 設定ウィンドウが開く
3. MCP URL コピー → クリップボードに URL
4. MCP トークンコピー → クリップボードにトークン
5. Claude Code スニペットコピー → クリップボードに `claude mcp add ...` コマンド
6. 一時停止 → メニュー項目が「再開」に変化、StatusItem に `(paused)` 追加、Hub への ingest 停止
7. 再開 → 元に戻る
8. 終了 → アプリ終了

- [ ] **Step 4: 設定ダイアログ 2 タブ動作**

MCP Server タブ:
- Status, Endpoint, Token, Port, AutoStart, PersistEventLog, Claude Code Snippet, 言語選択が全て表示
- Copy ボタン 2 個 + Snippet コピーボタンが動作
- Port を変更して保存 → 再起動後反映確認
- AutoStart チェック ON → レジストリ `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` に登録、OFF で削除

Transmission タブ:
- 説明文、全許可チェック、Retention/MaxCount コンボ、グループ別リストが表示
- 個別 CheckBox トグル、全許可で全 ON/OFF
- 保存して `%LOCALAPPDATA%\AmbientContextMcp\settings.json` を確認

- [ ] **Step 5: 言語切替**

ja → en → System default を切替えて保存・再起動。各回で UI 文字列が切り替わる。

- [ ] **Step 6: AutoStart**

設定で AutoStart 有効化 → サインアウト/再ログイン → アプリが自動起動。

- [ ] **Step 7: Claude Code MCP 接続**

Claude Code に MCP サーバを追加し、`claude mcp list` で接続成功を確認。実際にコンテキストを取得して内容を確認 (`ambient_get_context` 等の tool 呼び出し)。

- [ ] **Step 8: Optimus 警告非発生 (主目的)**

NVIDIA Optimus 機 (RTX 4070 等) で:
1. ambient-mcp.exe を起動
2. **設定ダイアログを一度開いて閉じる** (D3D 初期化させる)
3. Xbox アプリから Forza Horizon 6 を起動
4. NVIDIA Container ログ `%ProgramData%\NVIDIA Corporation\NVIDIA app\UXD\Log.nvcontainer.exe.log` を確認

Expected:
- 「画面モードを切り替えできません」ダイアログが**出ない**
- ログに `Blocking APP: ambient-mcp.exe` が**出ない**
- D3D11 ベースの WinUI 3 は `isDx9on12 = 0` 判定の対象外

- [ ] **Step 9: Core ユニットテスト**

```bash
dotnet test src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj -c Release
```

Expected: 全テストパス。

- [ ] **Step 10: 修正 commit (必要な場合)**

受け入れ条件で問題があれば該当 Task に戻り、追加 commit。問題なければスキップ。

---

## Task 18: PR 作成

**Files:** なし (GitHub 操作のみ)

- [ ] **Step 1: feature branch を push**

```bash
git push -u origin feature/winui3-migration
```

- [ ] **Step 2: 変更内容を確認**

```bash
git log main..HEAD --oneline
git diff main..HEAD --stat
```

- [ ] **Step 3: PR を作成**

```bash
gh pr create --title "feat: migrate UI stack from WPF/WinForms to WinUI 3" --body "$(cat <<'EOF'
## Summary

- Replace `AmbientContextMcp` (WPF + WinForms) with `AmbientContextMcp.Desktop` (WinUI 3, Windows App SDK)
- Resolve NVIDIA Optimus "画面モードを切り替えできません" warning by eliminating native Direct3D 9Ex device retention
- Adopt Fluent / Mica visual style, `.resw` localization, `Host.CreateApplicationBuilder` startup, `H.NotifyIcon.WinUI` tray
- Unpackaged distribution + Bootstrapper (Runtime not bundled, ~100-120 MB zip)

Design: `docs/superpowers/specs/2026-05-27-winui3-migration-design.md`
Plan: `docs/superpowers/plans/2026-05-27-winui3-migration.md`

## Test plan

- [x] Runtime 未インストール環境で MessageBox + DL ページ誘導
- [x] Runtime インストール済み環境で正常起動
- [x] トレイ 8 メニュー全動作
- [x] 設定 2 タブ (MCP / Transmission) 全機能
- [x] 言語切替 ja/en/System default
- [x] AutoStart 有効/無効反映
- [x] Claude Code から MCP 接続成功
- [x] **Optimus 警告が発生しない** (主目的)
- [x] AmbientContextMcp.Core ユニットテスト全パス

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: PR URL を控える**

```bash
gh pr view --json url -q .url
```

返却された URL を control center に記録。CI のグリーンを待ってからマージ。

---

## Self-Review Notes

実装担当が混乱しがちな点:

1. **Task 4 後の sln 全体ビルドは失敗する**: 旧 csproj と新 csproj が同じ namespace + 同じ型を定義しているため。Task 13 で旧を削除するまで sln 全体ビルドは試さない。**Desktop csproj 単体ビルドのみで確認する**。
2. **`Strings.cs` への参照が残っていないか**: Task 6 で ViewModel の `Strings.XXX` を `StringsLoader.XXX` に置換するが、grep で取り残しを確認。
3. **`x:Uid` のキー命名**: `.resw` のキーは `<x:Uid 値>.<XAML プロパティ>` の形式。プロパティ名 (`.Text`, `.Content`, `.Header`) を間違えると実行時に空文字になる。Task 10/11 で動作確認時に「ラベルが空っぽ」現象が出たら命名ミスを疑う。
4. **`H.NotifyIcon.WinUI` の Unpackaged 動作**: もし Unpackaged で動作不安定なら、`<EnableMsixTooling>false</EnableMsixTooling>` を csproj に明示。
5. **MddBootstrap の引数**: `Initialize` の overload は複数。`Initialize(MinMajor)` が最も互換性が高い。バージョン制約を厳しくしたい場合は `Initialize(MinMajor, MinMinor)` 等。
6. **`WindowNative.GetWindowHandle` の using**: `using WinRT.Interop;` が必要。
