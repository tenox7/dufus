import Foundation
import CDecompressors

enum Compression {
    case none, gzip, xz, bz2

    init?(ext: String) {
        switch ext.lowercased() {
        case "gz": self = .gzip
        case "xz": self = .xz
        case "bz2": self = .bz2
        default: return nil
        }
    }

    static let rawExtensions: Set<String> = ["img", "iso", "raw", "dd", "dsk", "cdr"]
}

class ImageReader {
    let compression: Compression
    let compressedSize: UInt64
    private let fileHandle: FileHandle
    private let inputBufSize = 256 * 1024
    private let outputBufSize = 1024 * 1024
    private var inputBuf: UnsafeMutablePointer<UInt8>
    private var outputBuf: UnsafeMutablePointer<UInt8>
    private var finished = false

    private var zStrm = z_stream()
    private var xzStrm = lzma_stream()
    private var bzStrm = bz_stream()

    var compressedBytesRead: UInt64 { fileHandle.offsetInFile }

    init?(url: URL) {
        let ext = url.pathExtension.lowercased()
        let stripped = url.deletingPathExtension().pathExtension.lowercased()

        if let c = Compression(ext: ext),
           Compression.rawExtensions.contains(stripped) || !stripped.isEmpty {
            compression = c
        } else if Compression.rawExtensions.contains(ext) || Compression(ext: ext) == nil {
            compression = .none
        } else {
            compression = .none
        }

        guard let fh = FileHandle(forReadingAtPath: url.path) else { return nil }
        fileHandle = fh

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        compressedSize = attrs?[.size] as? UInt64 ?? 0

        inputBuf = .allocate(capacity: inputBufSize)
        outputBuf = .allocate(capacity: outputBufSize)

        if !initDecompressor() {
            fileHandle.closeFile()
            inputBuf.deallocate()
            outputBuf.deallocate()
            return nil
        }
    }

    func readChunk() -> Data? {
        if finished { return nil }
        switch compression {
        case .none:  return readRaw()
        case .gzip:  return readGzip()
        case .xz:    return readXz()
        case .bz2:   return readBz2()
        }
    }

    func close() {
        switch compression {
        case .none:  break
        case .gzip:  inflateEnd(&zStrm)
        case .xz:    lzma_end(&xzStrm)
        case .bz2:   BZ2_bzDecompressEnd(&bzStrm)
        }
        fileHandle.closeFile()
        inputBuf.deallocate()
        outputBuf.deallocate()
    }

    // MARK: - Init

    private func initDecompressor() -> Bool {
        switch compression {
        case .none:
            return true
        case .gzip:
            return inflateInit2_(&zStrm, MAX_WBITS + 16,
                                 ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        case .xz:
            return lzma_stream_decoder(&xzStrm, UInt64.max, UInt32(LZMA_CONCATENATED)) == LZMA_OK
        case .bz2:
            return BZ2_bzDecompressInit(&bzStrm, 0, 0) == BZ_OK
        }
    }

    // MARK: - Raw

    private func readRaw() -> Data? {
        let data = fileHandle.readData(ofLength: outputBufSize)
        if data.isEmpty { finished = true; return nil }
        return data
    }

    // MARK: - Gzip

    private func readGzip() -> Data? {
        while true {
            if zStrm.avail_in == 0 {
                let data = fileHandle.readData(ofLength: inputBufSize)
                if data.isEmpty { finished = true; return nil }
                data.copyBytes(to: inputBuf, count: data.count)
                zStrm.next_in = inputBuf
                zStrm.avail_in = uInt(data.count)
            }
            zStrm.next_out = outputBuf
            zStrm.avail_out = uInt(outputBufSize)

            let ret = inflate(&zStrm, Z_NO_FLUSH)
            let produced = outputBufSize - Int(zStrm.avail_out)

            if ret == Z_STREAM_END { finished = true }
            if produced > 0 { return Data(bytes: outputBuf, count: produced) }
            if ret != Z_OK { finished = true; return nil }
        }
    }

    // MARK: - XZ

    private func readXz() -> Data? {
        while true {
            if xzStrm.avail_in == 0 {
                let data = fileHandle.readData(ofLength: inputBufSize)
                if data.isEmpty { finished = true; return nil }
                data.copyBytes(to: inputBuf, count: data.count)
                xzStrm.next_in = UnsafePointer(inputBuf)
                xzStrm.avail_in = data.count
            }
            xzStrm.next_out = outputBuf
            xzStrm.avail_out = outputBufSize

            let ret = lzma_code(&xzStrm, LZMA_RUN)
            let produced = outputBufSize - xzStrm.avail_out

            if ret == LZMA_STREAM_END { finished = true }
            if produced > 0 { return Data(bytes: outputBuf, count: Int(produced)) }
            if ret != LZMA_OK { finished = true; return nil }
        }
    }

    // MARK: - Bzip2

    private func readBz2() -> Data? {
        while true {
            if bzStrm.avail_in == 0 {
                let data = fileHandle.readData(ofLength: inputBufSize)
                if data.isEmpty { finished = true; return nil }
                data.copyBytes(to: inputBuf, count: data.count)
                bzStrm.next_in = UnsafeMutablePointer<CChar>(OpaquePointer(inputBuf))
                bzStrm.avail_in = UInt32(data.count)
            }
            bzStrm.next_out = UnsafeMutablePointer<CChar>(OpaquePointer(outputBuf))
            bzStrm.avail_out = UInt32(outputBufSize)

            let ret = BZ2_bzDecompress(&bzStrm)
            let produced = outputBufSize - Int(bzStrm.avail_out)

            if ret == BZ_STREAM_END { finished = true }
            if produced > 0 { return Data(bytes: outputBuf, count: produced) }
            if ret != BZ_OK { finished = true; return nil }
        }
    }
}
