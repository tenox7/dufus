import Foundation
import CDecompressors
import CLzip

enum Compression {
    case none, gzip, xz, bz2, lzip

    init?(ext: String) {
        switch ext.lowercased() {
        case "gz": self = .gzip
        case "xz": self = .xz
        case "bz2": self = .bz2
        case "lz": self = .lzip
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
    private var lzDec = CLzmaDec()
    private var lzAvailIn = 0
    private var lzInOffset = 0

    var compressedBytesRead: UInt64 { fileHandle.offsetInFile }

    init?(url: URL) {
        let ext = url.pathExtension.lowercased()
        compression = Compression(ext: ext) ?? .none

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
        case .lzip:  return readLzip()
        }
    }

    func close() {
        switch compression {
        case .none:  break
        case .gzip:  inflateEnd(&zStrm)
        case .xz:    lzma_end(&xzStrm)
        case .bz2:   BZ2_bzDecompressEnd(&bzStrm)
        case .lzip:  LzmaDec_Free(&lzDec)
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
        case .lzip:
            return initLzipMember()
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

    // MARK: - Lzip

    private func initLzipMember() -> Bool {
        let hdr = fileHandle.readData(ofLength: 6)
        guard hdr.count == 6,
              hdr[0] == 0x4C, hdr[1] == 0x5A, hdr[2] == 0x49, hdr[3] == 0x50,
              hdr[4] == 1 else { return false }
        var ds = UInt32(1) << (hdr[5] & 0x1F)
        if ds > UInt32(min_dictionary_size) {
            ds -= (ds / 16) * UInt32((hdr[5] >> 5) & 7)
        }
        var props: [UInt8] = [93,
            UInt8(ds & 0xFF), UInt8((ds >> 8) & 0xFF),
            UInt8((ds >> 16) & 0xFF), UInt8((ds >> 24) & 0xFF)]
        return LzmaDec_Init(&lzDec, &props)
    }

    private func nextLzipMember() -> Bool {
        LzmaDec_Free(&lzDec)
        lzDec = CLzmaDec()
        let pos = fileHandle.offsetInFile - UInt64(lzAvailIn)
        fileHandle.seek(toFileOffset: pos + 20)
        lzAvailIn = 0
        lzInOffset = 0
        return initLzipMember()
    }

    private func readLzip() -> Data? {
        while true {
            if lzAvailIn == 0 {
                let data = fileHandle.readData(ofLength: inputBufSize)
                if data.isEmpty { finished = true; return nil }
                data.copyBytes(to: inputBuf, count: data.count)
                lzInOffset = 0
                lzAvailIn = data.count
            }
            var srcLen = UInt32(lzAvailIn)
            var destLen = UInt32(outputBufSize)
            var status = LZMA_STATUS_NOT_SPECIFIED
            let ok = LzmaDec_DecodeToBuf(&lzDec, outputBuf, &destLen,
                                          inputBuf.advanced(by: lzInOffset), &srcLen,
                                          LZMA_FINISH_ANY, &status)
            lzInOffset += Int(srcLen)
            lzAvailIn -= Int(srcLen)

            if status == LZMA_STATUS_FINISHED_WITH_MARK {
                if !nextLzipMember() { finished = true }
            }
            if destLen > 0 { return Data(bytes: outputBuf, count: Int(destLen)) }
            if !ok { finished = true; return nil }
        }
    }
}
