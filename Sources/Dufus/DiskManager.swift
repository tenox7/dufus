import Foundation
import IOKit

struct DiskInfo: Identifiable, Hashable {
    let id: String
    let devicePath: String
    let size: UInt64
    let mediaName: String
    let isRemovable: Bool

    var formattedSize: String {
        let gb = Double(size) / 1_000_000_000
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        return String(format: "%.0f MB", Double(size) / 1_000_000)
    }

    var displayName: String {
        let label = mediaName.isEmpty ? "Unknown" : mediaName
        return "\(devicePath) — \(label) (\(formattedSize))"
    }
}

class DiskManager: ObservableObject {
    @Published var disks: [DiskInfo] = []

    func refresh() {
        disks = Self.listPhysicalDisks()
    }

    private static func listPhysicalDisks() -> [DiskInfo] {
        guard let matching = IOServiceMatching("IOMedia") as NSMutableDictionary? else { return [] }
        matching["Whole"] = true

        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [DiskInfo] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard isPhysicalDisk(entry), !isSynthesized(entry) else { continue }
            guard let props = properties(of: entry) else { continue }

            let bsdName = props["BSD Name"] as? String ?? "unknown"
            guard bsdName != "disk0" else { continue }
            let size = props["Size"] as? UInt64 ?? 0
            let mediaName = props["IOMediaIcon"]
                .flatMap { ($0 as? [String: Any])?["CFBundleIdentifier"] as? String }
                .map { _ in props["Model"] as? String ?? "" }
                ?? (props["MediaName"] as? String ?? "")
            let removable = props["Removable"] as? Bool ?? false

            result.append(DiskInfo(
                id: bsdName,
                devicePath: "/dev/\(bsdName)",
                size: size,
                mediaName: deviceModel(for: entry) ?? mediaName,
                isRemovable: removable
            ))
        }
        return result.sorted { $0.id < $1.id }
    }

    private static func isPhysicalDisk(_ entry: io_object_t) -> Bool {
        var parent: io_object_t = 0
        var current = entry
        IOObjectRetain(current)

        while true {
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if current != entry { IOObjectRelease(current) }
            guard kr == KERN_SUCCESS else { return false }

            if IOObjectConformsTo(parent, "IOBlockStorageDevice") != 0 {
                let physical = isPhysicalInterconnect(parent)
                IOObjectRelease(parent)
                return physical
            }
            current = parent
        }
    }

    private static func isSynthesized(_ entry: io_object_t) -> Bool {
        var parent: io_object_t = 0
        let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
        guard kr == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        var className = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(parent, &className)
        let name = String(cString: className)
        return name.contains("APFS")
    }

    private static func isPhysicalInterconnect(_ device: io_object_t) -> Bool {
        guard let props = properties(of: device),
              let proto = props["Protocol Characteristics"] as? [String: Any],
              let interconnect = proto["Physical Interconnect"] as? String else {
            return false
        }
        let virtual = ["Disk Image", "Virtual Interface"]
        return !virtual.contains(interconnect)
    }

    private static func deviceModel(for entry: io_object_t) -> String? {
        var parent: io_object_t = 0
        var current = entry
        IOObjectRetain(current)

        while true {
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if current != entry { IOObjectRelease(current) }
            guard kr == KERN_SUCCESS else { return nil }

            if let props = properties(of: parent),
               let model = props["Model"] as? Data ?? props["Model"] as? Data {
                IOObjectRelease(parent)
                return String(data: model, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
            }
            if let props = properties(of: parent),
               let name = props["Device Characteristics"] as? [String: Any],
               let model = name["Product Name"] as? String {
                IOObjectRelease(parent)
                return model
            }
            current = parent
        }
    }

    private static func properties(of entry: io_object_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS else { return nil }
        return props?.takeRetainedValue() as? [String: Any]
    }
}
