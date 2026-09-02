import Testing
@testable import AmbientContextCore

@Suite("MediaSourceKindClassifier")
struct MediaSourceKindClassifierTests {
    @Test("Classifies_known_music_apps", arguments: [
        "Spotify.exe",
        "SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify",
        "AppleInc.iTunes",
        "AppleInc.AppleMusicWin_nzyj5cx40ttqa!AppleMusicWin",
        "AmazonMobileLLC.AmazonMusic_b0xbz8s9n9qvw!App",
        "Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"
    ])
    func classifiesKnownMusicApps(sourceApp: String) {
        #expect(MediaSourceKindClassifier.classify(sourceApp) == "music")
    }

    @Test("Classifies_known_video_apps", arguments: [
        "Netflix.Netflix_mcm4njqhnhss8!Netflix.App",
        "Microsoft.ZuneVideo_8wekyb3d8bbwe!Microsoft.ZuneVideo",
        "AmazonVideo.PrimeVideo_*",
        "hulu.HuluPlus_fphbd361v8tya!App",
        "DisneyPlus.DisneyPlus_*",
        "vlc.exe",
        "mpv.exe"
    ])
    func classifiesKnownVideoApps(sourceApp: String) {
        #expect(MediaSourceKindClassifier.classify(sourceApp) == "video")
    }

    @Test("Classifies_browsers_as_browser", arguments: [
        "chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "vivaldi.exe", "opera.exe"
    ])
    func classifiesBrowsersAsBrowser(sourceApp: String) {
        #expect(MediaSourceKindClassifier.classify(sourceApp) == "browser")
    }

    @Test("Returns_unknown_for_blank_or_unrecognized", arguments: [
        "", "   ", "SomeRandomApp.exe", "XSplitBroadcaster.exe"
    ])
    func returnsUnknownForBlankOrUnrecognized(sourceApp: String) {
        #expect(MediaSourceKindClassifier.classify(sourceApp) == "unknown")
    }

    @Test("Returns_unknown_for_null_safe")
    func returnsUnknownForNullSafe() {
        #expect(MediaSourceKindClassifier.classify(nil) == "unknown")
    }

    @Test("Video_precedes_music_when_both_substrings_present")
    func videoPrecedesMusicWhenBothSubstringsPresent() {
        // ZuneVideo は "video" 判定が先に当たる (Zune は music/video 別アプリ)
        #expect(MediaSourceKindClassifier.classify("Microsoft.ZuneVideo_*") == "video")
        // ZuneMusic は "music" 判定
        #expect(MediaSourceKindClassifier.classify("Microsoft.ZuneMusic_*") == "music")
    }
}
