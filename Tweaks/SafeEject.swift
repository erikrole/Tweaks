import AppKit
import DiskArbitration
import Observation

struct EjectDrive: Equatable, Sendable {
    let device: String
    let name: String
    let volumes: [URL]
    let identity: String
}

struct EjectTopology {
    private var physical: [String: String] = [:]

    init(plist: [String: Any]) throws {
        guard let disks = plist["AllDisksAndPartitions"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        var partitionParents: [String: String] = [:]
        for disk in disks {
            guard let name = disk["DeviceIdentifier"] as? String, SafeEjectEngine.validDevice(name),
                  let content = disk["Content"] as? String else { throw CocoaError(.fileReadCorruptFile) }
            if content == "Apple_APFS_Container" { continue }
            // Unknown virtual/RAID/CoreStorage arrangements must not be guessed.
            guard !content.contains("RAID"), !content.contains("CoreStorage") else { continue }
            physical[name] = name
            for partition in disk["Partitions"] as? [[String: Any]] ?? [] {
                guard let child = partition["DeviceIdentifier"] as? String else { throw CocoaError(.fileReadCorruptFile) }
                partitionParents[child] = name
            }
        }
        for disk in disks where disk["Content"] as? String == "Apple_APFS_Container" {
            guard let name = disk["DeviceIdentifier"] as? String,
                  let stores = disk["APFSPhysicalStores"] as? [[String: Any]], stores.count == 1,
                  let store = stores.first?["DeviceIdentifier"] as? String,
                  let parent = partitionParents[store] ?? physical[store] else { continue }
            physical[name] = parent
        }
    }

    func physicalDevice(for whole: String) -> String? { physical[whole] }
}

enum SafeEjectEngine {
    enum MountSource: Equatable {
        case disk(String), alias(String), pseudo, unsupported
    }

    static func mountSource(_ source: String, type: String) -> MountSource {
        if source.hasPrefix("/dev/disk") { return .disk(source) }
        if ["devicefs", "devfs", "autofs"].contains(type) { return .pseudo }
        if type == "nullfs", source.hasPrefix("/") { return .alias(source) }
        return .unsupported
    }

    struct Backend: Sendable {
        var drives: @Sendable () throws -> [EjectDrive]
        var users: @Sendable (URL) -> [String]?
        var rendering: @Sendable () -> Bool
        var eject: @Sendable (String) throws -> Void
    }

    static func run(_ backend: Backend) -> [String] {
        do {
            let drives = try backend.drives()
            guard !drives.isEmpty else { return ["No eligible external drives are mounted."] }
            guard !backend.rendering() else { return ["A render engine is running. No drives were ejected."] }
            var report: [String] = []
            for drive in drives {
                guard !backend.rendering() else { report.append("Stopped: a render engine started."); break }
                guard let fresh = try backend.drives().first(where: { $0.device == drive.device }), fresh == drive else {
                    report.append("\(drive.name): drive configuration changed; left connected.")
                    continue
                }
                var blockers: [String] = []
                var verified = true
                for volume in drive.volumes {
                    guard let users = backend.users(volume) else { verified = false; break }
                    blockers.append(contentsOf: users)
                }
                guard verified else { report.append("\(drive.name): couldn't verify open files; left connected."); continue }
                guard blockers.isEmpty else {
                    report.append("\(drive.name): in use by \(Set(blockers).sorted().joined(separator: ", ")).")
                    continue
                }
                guard !backend.rendering(), try backend.drives().first(where: { $0.device == drive.device }) == drive else {
                    report.append("\(drive.name): activity or drive configuration changed; left connected.")
                    continue
                }
                do {
                    try backend.eject(drive.device)
                    report.append("Ejected \(drive.name).")
                } catch { report.append("\(drive.name): \(error.localizedDescription)") }
            }
            return report
        } catch { return ["Could not inspect drives: \(error.localizedDescription)"] }
    }

    static func eligible(local: Bool?, root: Bool?, internalDrive: Bool?, ejectable: Bool?, removable: Bool?) -> Bool {
        local == true && root == false && internalDrive == false && (ejectable == true || removable == true)
    }

    static func inventory() throws -> [EjectDrive] {
        guard let session = DASessionCreate(nil) else { throw CocoaError(.fileReadUnknown) }
        let topology = try EjectTopology(plist: diskList())
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey,
                                       .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeUUIDStringKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: []) else {
            throw CocoaError(.fileReadUnknown)
        }
        struct Volume { let url: URL; let uuid: String; let eligible: Bool }
        var groups: [String: [Volume]] = [:]
        for url in urls {
            let values = try url.resourceValues(forKeys: keys)
            guard let local = values.volumeIsLocal else { throw CocoaError(.fileReadUnknown) }
            guard local else { continue }
            var mount = statfs()
            guard statfs(url.path, &mount) == 0 else { throw CocoaError(.fileReadUnknown) }
            let source = withUnsafeBytes(of: mount.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let type = withUnsafeBytes(of: mount.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let deviceSource: String
            switch mountSource(source, type: type) {
            case .pseudo: continue
            case .disk(let name): deviceSource = name
            case .alias(let path):
                // macOS uses nullfs for iOS app wrappers. Include the alias in its
                // backing disk's group so an alias never hides a busy sibling.
                var backing = statfs()
                guard statfs(path, &backing) == 0 else { throw CocoaError(.fileReadUnknown) }
                let name = withUnsafeBytes(of: backing.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                guard name.hasPrefix("/dev/disk") else { throw CocoaError(.fileReadUnknown) }
                deviceSource = name
            case .unsupported: throw CocoaError(.fileReadUnknown)
            }
            guard let disk = DADiskCreateFromBSDName(nil, session, deviceSource),
                  let whole = DADiskCopyWholeDisk(disk), let bsd = DADiskGetBSDName(whole),
                  let device = topology.physicalDevice(for: String(cString: bsd)),
                  let physical = DADiskCreateFromBSDName(nil, session, device),
                  let description = DADiskCopyDescription(physical) as? [String: Any] else {
                // Omitting an unknown mounted volume could omit a busy sibling.
                throw CocoaError(.fileReadUnknown)
            }
            let connection = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
            let isVirtual = connection == nil || connection == "Disk Image" || connection == "Virtual Interface"
            let allowed = !isVirtual && eligible(local: local, root: values.volumeIsRootFileSystem,
                internalDrive: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool,
                ejectable: description[kDADiskDescriptionMediaEjectableKey as String] as? Bool,
                removable: description[kDADiskDescriptionMediaRemovableKey as String] as? Bool)
            groups[device, default: []].append(Volume(url: url, uuid: values.volumeUUIDString ?? "", eligible: allowed))
        }
        return groups.compactMap { device, volumes in
            guard volumes.allSatisfy({ $0.eligible && !$0.uuid.isEmpty }) else { return nil }
            let sorted = volumes.sorted { $0.url.path < $1.url.path }
            return EjectDrive(device: device, name: sorted.map { $0.url.lastPathComponent }.joined(separator: " / "),
                              volumes: sorted.map(\.url), identity: sorted.map { $0.uuid }.joined(separator: "|"))
        }.sorted { $0.device < $1.device }
    }

    private static func diskList() throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/diskutil")
        process.arguments = ["list", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let list = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.fileReadUnknown)
        }
        return list
    }

    static func validDevice(_ value: String) -> Bool {
        value.hasPrefix("disk") && value.count > 4 && value.dropFirst(4).allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func eject(_ device: String) throws {
        guard validDevice(device) else { throw CocoaError(.fileWriteNoPermission) }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/diskutil")
        // diskutil asks Disk Arbitration to unmount/eject normally. Never use force.
        process.arguments = ["eject", "/dev/" + device]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Tweaks.SafeEject", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: data.prefix(2048), as: UTF8.self)])
        }
    }
}

@MainActor
@Observable
final class SafeEject {
    private(set) var busy = false
    private(set) var results: [String] = []
    private let queue = DispatchQueue(label: "Tweaks.safe-eject", qos: .utility)

    func ejectIdleDrives(notify: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        results = ["Checking external drives and open files…"]
        let backend = SafeEjectEngine.Backend(drives: SafeEjectEngine.inventory,
                                             users: { OpenFiles.usersOfVolume($0.path) },
                                             rendering: RenderProcesses.anyRunning, eject: SafeEjectEngine.eject)
        results = (try? await FileWork.run(on: queue) { SafeEjectEngine.run(backend) }) ?? ["Could not check drives."]
        if notify { Notifier.post(title: "Safe eject", body: results.joined(separator: "\n")) }
    }
}
