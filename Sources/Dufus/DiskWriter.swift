import Foundation
import DiskArbitration
import Security
import CWipefs

class DiskWriter {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func write(image: URL, to disk: DiskInfo, wipe: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.run(image: image, disk: disk, wipe: wipe)
        }
    }

    func eject(disk: DiskInfo) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.setStatus("Ejecting…")
            guard let session = DASessionCreate(kCFAllocatorDefault),
                  let daDisk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, disk.id) else {
                self.setStatus("Eject failed"); return
            }
            DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            let ok = self.waitDA { cb, ctx in DADiskEject(daDisk, DADiskEjectOptions(kDADiskEjectOptionDefault), cb, ctx) }
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            self.setStatus(ok ? "Ejected" : "Eject failed")
        }
    }

    private func run(image: URL, disk: DiskInfo, wipe: Bool) {
        appState.cancelled = false
        DispatchQueue.main.async { self.appState.writing = true }
        defer { DispatchQueue.main.async { self.appState.writing = false } }

        setStatus("Unmounting…")
        guard unmount(disk: disk) else { setStatus("Failed to unmount"); return }

        let rawPath = "/dev/r\(disk.id)"
        setStatus("Requesting authorization…")
        guard let fd = openWithAuth(rawPath) else { setStatus("Failed to open \(rawPath)"); return }
        defer { close(fd) }

        if wipe {
            setStatus("Wiping signatures…")
            var ctx: OpaquePointer?
            var err = wipefs_alloc(fd, 0, &ctx)
            guard err == 0, let wipeCtx = ctx else { setStatus("wipefs init failed"); return }
            err = wipefs_wipe(wipeCtx)
            var mctx: OpaquePointer? = wipeCtx
            wipefs_free(&mctx)
            guard err == 0 else { setStatus("wipefs failed: \(err)"); return }
        }

        guard let reader = ImageReader(url: image) else { setStatus("Cannot open image"); return }
        defer { reader.close() }

        setStatus("Writing…")
        setProgress(0)
        var written: UInt64 = 0
        let blockSize = 1024 * 1024
        let diskSize = disk.size
        var buf = Data()
        let startTime = Date()

        while let chunk = reader.readChunk() {
            buf.append(chunk)
            while buf.count >= blockSize {
                if written + UInt64(blockSize) > diskSize {
                    setStatus("Image too large for disk"); return
                }
                let block = buf.prefix(blockSize)
                guard writeChunk(block, fd: fd, offset: written) else {
                    setStatus("Write error at offset \(written): \(errnoMessage())")
                    return
                }
                written += UInt64(blockSize)
                buf.removeFirst(blockSize)
                updateWriteStatus(written: written, reader: reader, startTime: startTime)
                if appState.cancelled { setStatus("Cancelled at \(formatBytes(written))"); return }
            }
        }

        if !buf.isEmpty {
            let aligned = (buf.count + 511) & ~511
            let toWrite = min(aligned, Int(diskSize - written))
            buf.append(contentsOf: [UInt8](repeating: 0, count: max(0, toWrite - buf.count)))
            buf = buf.prefix(toWrite)
            guard writeChunk(buf, fd: fd, offset: written) else {
                setStatus("Write error at offset \(written): \(errnoMessage())")
                return
            }
            written += UInt64(buf.count)
        }

        _ = fcntl(fd, F_FULLFSYNC)
        setProgress(1)
        setStatus("Done — \(formatBytes(written)) written")
    }

    private func writeChunk(_ data: Data, fd: Int32, offset: UInt64) -> Bool {
        data.withUnsafeBytes { ptr in
            var remaining = data.count
            var off = 0
            while remaining > 0 {
                let n = pwrite(fd, ptr.baseAddress! + off, remaining, off_t(offset) + off_t(off))
                if n <= 0 { return false }
                off += n
                remaining -= n
            }
            return true
        }
    }

    private func unmount(disk: DiskInfo) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let daDisk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, disk.id) else { return false }
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let ok = waitDA { cb, ctx in DADiskUnmount(daDisk, DADiskUnmountOptions(kDADiskUnmountOptionWhole | kDADiskUnmountOptionForce), cb, ctx) }
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        return ok
    }

    typealias DACallback = @convention(c) (DADisk, DADissenter?, UnsafeMutableRawPointer?) -> Void
    typealias DAOp = (DACallback, UnsafeMutableRawPointer) -> Void

    private func waitDA(op: DAOp) -> Bool {
        let ctx = UnsafeMutablePointer<Bool?>.allocate(capacity: 1)
        ctx.initialize(to: nil)
        defer { ctx.deallocate() }
        let cb: DACallback = { _, dissenter, context in
            context!.assumingMemoryBound(to: Bool?.self).pointee = (dissenter == nil)
        }
        op(cb, ctx)
        let deadline = Date().addingTimeInterval(10)
        while ctx.pointee == nil, Date() < deadline {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.1, true)
        }
        return ctx.pointee ?? false
    }

    private func openWithAuth(_ path: String) -> Int32? {
        let right = "sys.openfile.readwrite.\(path)"
        var authRef: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &authRef)
        guard status == errAuthorizationSuccess, let auth = authRef else { return nil }
        defer { AuthorizationFree(auth, []) }

        let authorized: Bool = right.withCString { ptr in
            var item = AuthorizationItem(name: ptr, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                let flags: AuthorizationFlags = [.interactionAllowed, .extendRights]
                return AuthorizationCopyRights(auth, &rights, nil, flags, nil) == errAuthorizationSuccess
            }
        }
        guard authorized else { return nil }

        var extForm = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(auth, &extForm) == errAuthorizationSuccess else { return nil }

        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }

        let stdinPipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
        proc.arguments = ["-stdoutpipe", "-extauth", "-o", "2", path]
        proc.standardOutput = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
        proc.standardInput = stdinPipe

        do { try proc.run() } catch { close(fds[0]); close(fds[1]); return nil }
        close(fds[1])

        withUnsafeBytes(of: &extForm) { buf in
            stdinPipe.fileHandleForWriting.write(Data(buf))
        }
        stdinPipe.fileHandleForWriting.closeFile()

        let fd = recv_fd(fds[0])
        close(fds[0])
        proc.waitUntilExit()

        guard proc.terminationStatus == 0, fd >= 0 else { return nil }
        return fd
    }

    private var smoothedETA: Double = 0

    private func updateWriteStatus(written: UInt64, reader: ImageReader, startTime: Date) {
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed > 0.5 else { return }
        let speed = Double(written) / elapsed
        let speedMB = speed / 1_000_000
        let writtenMB = Double(written) / 1_000_000

        var progress = 0.0
        var eta = ""
        if reader.compressedSize > 0 {
            progress = Double(reader.compressedBytesRead) / Double(reader.compressedSize)
            if progress > 0.01 {
                let rawETA = (1.0 - progress) / progress * elapsed
                if rawETA.isFinite && rawETA > 0 {
                    smoothedETA = smoothedETA > 0 ? smoothedETA * 0.9 + rawETA * 0.1 : rawETA
                    eta = " — ETA \(formatDuration(smoothedETA))"
                }
            }
        }

        setProgress(progress)
        setStatus(String(format: "Writing… %.0f MB @ %.1f MB/s%@", writtenMB, speedMB, eta))
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    private func errnoMessage() -> String {
        let err = errno
        return "\(String(cString: strerror(err))) (\(err))"
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.appState.status = s }
    }

    private func setProgress(_ p: Double) {
        DispatchQueue.main.async { self.appState.progress = min(p, 1.0) }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}
