import Foundation
import Testing
@testable import FinderUtilitiesKit

struct PathCleanerTests {
    let cleaner = PathCleaner(marker: "shares")

    @Test(arguments: [
        ("/Volumes/users/shares/Media/Foo.mov", "Media/Foo.mov"),
        ("/Volumes/users-1/shares/Media/Foo.mov", "Media/Foo.mov"),
        ("/Volumes/users/SHARES/Media/Foo.mov", "Media/Foo.mov"),
        ("/Volumes/Media/Foo.mov", "Foo.mov"),
        ("/Volumes/users/shares/Media/Folder/", "Media/Folder"),
        // Real paths from Erik's Raycast clipboard history (expected output assumes the Media/ prefix is kept; confirm).
        ("/Volumes/users/shares/Media/ARCHIVE/2020-2029/2026-27/Football/Videoboard/Stadium Vision/_Full Screen", "Media/ARCHIVE/2020-2029/2026-27/Football/Videoboard/Stadium Vision/_Full Screen"),
        ("/Volumes/users/shares/Media/RESOURCES/VIDEOBOARD/Colosseum Content/Backgrounds", "Media/RESOURCES/VIDEOBOARD/Colosseum Content/Backgrounds"),
        ("/Volumes/users/shares/Media/ARCHIVE/2020-2029/2026-27/Multi-Sport/Videoboard/Logo Loop", "Media/ARCHIVE/2020-2029/2026-27/Multi-Sport/Videoboard/Logo Loop"),
        ("/Volumes/users/shares/Media/ARCHIVE/2020-2029/2026-27/Basketball - Men's/Videoboard/Headshots/Exhibition", "Media/ARCHIVE/2020-2029/2026-27/Basketball - Men's/Videoboard/Headshots/Exhibition"),
        ("/Volumes/users/shares/Media/ARCHIVE/2020-2029/2026-27/Basketball - Men's", "Media/ARCHIVE/2020-2029/2026-27/Basketball - Men's"),
        ("/Volumes/users/shares/Media/ARCHIVE/2020-2029/2026-27/Volleyball/Videoboard/Cart Shuffle/_EXPORTS", "Media/ARCHIVE/2020-2029/2026-27/Volleyball/Videoboard/Cart Shuffle/_EXPORTS"),
        ("/Users/erik/Library/CloudStorage/Box-Box/Projects/X.pdf", "Box/Projects/X.pdf"),
        // Real paths from Erik: local and iCloud stay unchanged; Box and Google Drive are shortened.
        ("/Users/user/To Sort/Work Projects", "/Users/user/To Sort/Work Projects"),
        ("/Users/user/Library/Mobile Documents/com~apple~CloudDocs/Personal/05_Home", "/Users/user/Library/Mobile Documents/com~apple~CloudDocs/Personal/05_Home"),
        ("/Users/user/Library/CloudStorage/GoogleDrive-user@example.com/My Drive/Assets/Displacement Maps", "My Drive/Assets/Displacement Maps"),
        ("/Users/user/Library/CloudStorage/Box-Box/Broadcast Package", "Box/Broadcast Package"),
        ("/Users/erik/Library/CloudStorage/GoogleDrive-erik@example.com/My Drive/A/b.txt", "My Drive/A/b.txt"),
        ("/Users/erik/Library/CloudStorage/GoogleDrive-erik@example.com/Shared drives/Team/b.txt", "Shared drives/Team/b.txt"),
        ("/System/Volumes/Data/Users/erik/Desktop/a b.txt", "/Users/erik/Desktop/a b.txt"),
        ("/Users/erik/Desktop/a b.txt", "/Users/erik/Desktop/a b.txt"),
    ])
    func cleans(input: String, expected: String) {
        #expect(cleaner.clean(path: input) == expected)
    }

    @Test func unicodeMarkerMatchesAcrossNormalizationForms() {
        let c = PathCleaner(marker: "Médias")
        let nfd = "/Volumes/users/Me\u{301}dias/Foo.mov"
        #expect(c.clean(path: nfd) == "Foo.mov")
    }

    @Test func multipleURLsAreNewlineJoinedInOrder() {
        let urls = [URL(fileURLWithPath: "/Volumes/users/shares/Media/B.mov"),
                    URL(fileURLWithPath: "/Volumes/users/shares/Media/A.mov")]
        #expect(cleaner.clean(urls) == "Media/B.mov\nMedia/A.mov")
    }
}
