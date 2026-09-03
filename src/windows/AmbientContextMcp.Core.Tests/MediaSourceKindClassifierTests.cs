using AmbientContextMcp.Core.Models;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class MediaSourceKindClassifierTests
{
    [Theory]
    [InlineData("Spotify.exe", "music")]
    [InlineData("SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify", "music")]
    [InlineData("AppleInc.iTunes", "music")]
    [InlineData("AppleInc.AppleMusicWin_nzyj5cx40ttqa!AppleMusicWin", "music")]
    [InlineData("AmazonMobileLLC.AmazonMusic_b0xbz8s9n9qvw!App", "music")]
    [InlineData("Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic", "music")]
    // macOS bundle id (大文字小文字は無視される)
    [InlineData("com.apple.Music", "music")]
    [InlineData("com.apple.podcasts", "music")]
    public void Classifies_known_music_apps(string sourceApp, string expected)
    {
        Assert.Equal(expected, MediaSourceKindClassifier.Classify(sourceApp));
    }

    [Theory]
    [InlineData("Netflix.Netflix_mcm4njqhnhss8!Netflix.App", "video")]
    [InlineData("Microsoft.ZuneVideo_8wekyb3d8bbwe!Microsoft.ZuneVideo", "video")]
    [InlineData("AmazonVideo.PrimeVideo_*", "video")]
    [InlineData("hulu.HuluPlus_fphbd361v8tya!App", "video")]
    [InlineData("DisneyPlus.DisneyPlus_*", "video")]
    [InlineData("vlc.exe", "video")]
    [InlineData("mpv.exe", "video")]
    // macOS bundle id
    [InlineData("com.apple.TV", "video")]
    public void Classifies_known_video_apps(string sourceApp, string expected)
    {
        Assert.Equal(expected, MediaSourceKindClassifier.Classify(sourceApp));
    }

    [Theory]
    [InlineData("chrome.exe", "browser")]
    [InlineData("msedge.exe", "browser")]
    [InlineData("firefox.exe", "browser")]
    [InlineData("brave.exe", "browser")]
    [InlineData("vivaldi.exe", "browser")]
    [InlineData("opera.exe", "browser")]
    // macOS bundle id
    [InlineData("com.apple.Safari", "browser")]
    [InlineData("com.microsoft.edgemac", "browser")]
    [InlineData("company.thebrowser.Browser", "browser")]
    public void Classifies_browsers_as_browser(string sourceApp, string expected)
    {
        Assert.Equal(expected, MediaSourceKindClassifier.Classify(sourceApp));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("SomeRandomApp.exe")]
    [InlineData("XSplitBroadcaster.exe")]
    public void Returns_unknown_for_blank_or_unrecognized(string sourceApp)
    {
        Assert.Equal("unknown", MediaSourceKindClassifier.Classify(sourceApp));
    }

    [Fact]
    public void Returns_unknown_for_null_safe()
    {
        Assert.Equal("unknown", MediaSourceKindClassifier.Classify(null!));
    }

    [Fact]
    public void Video_precedes_music_when_both_substrings_present()
    {
        // ZuneVideo は "video" 判定が先に当たる (Zune は music/video 別アプリ)
        Assert.Equal("video", MediaSourceKindClassifier.Classify("Microsoft.ZuneVideo_*"));
        // ZuneMusic は "music" 判定
        Assert.Equal("music", MediaSourceKindClassifier.Classify("Microsoft.ZuneMusic_*"));
    }

    [Fact]
    public void Apple_music_matches_both_windows_and_macos_forms()
    {
        // Windows ストア版の "AppleMusic" と macOS の bundle id "com.apple.music" のどちらも music
        Assert.Equal("music", MediaSourceKindClassifier.Classify("applemusic"));
        Assert.Equal("music", MediaSourceKindClassifier.Classify("com.apple.music"));
        // video 判定が先だが、いずれの音楽 bundle id も video の部分文字列には当たらない
        Assert.Equal("video", MediaSourceKindClassifier.Classify("com.apple.TV"));
    }
}
