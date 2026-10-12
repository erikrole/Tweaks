import Testing
@testable import FinderUtilitiesKit

@Suite struct ScopeRootsTests {
    let home = "/Users/user"

    @Test func includesRootVolumesAndCloudFolders() {
        let r = ScopeRoots.compute(
            mountPoints: ["/", "/System/Volumes/Data", "/Volumes/users", "/Volumes/users-1/"],
            cloudStorageEntries: ["Box-Box", "GoogleDrive-user@example.com", ".DS_Store"],
            home: home)
        #expect(r == [
            "/",
            "/Users/user/Library/CloudStorage/Box-Box",
            "/Users/user/Library/CloudStorage/GoogleDrive-user@example.com",
            "/Users/user/Library/Mobile Documents",
            "/Volumes/users",
            "/Volumes/users-1",
        ])
    }

    @Test func ignoresNonVolumeMountsAndBareVolumesDir() {
        let r = ScopeRoots.compute(mountPoints: ["/Volumes/", "/dev", "/System/Volumes/VM"], cloudStorageEntries: [], home: home)
        #expect(r == ["/", "/Users/user/Library/Mobile Documents"])
    }

    @Test func changeDetectionIgnoresOrder() {
        #expect(!ScopeRoots.hasChanged(old: ["/", "/Volumes/a"], new: ["/Volumes/a", "/"]))
        #expect(ScopeRoots.hasChanged(old: ["/"], new: ["/", "/Volumes/a"]))
    }
}
