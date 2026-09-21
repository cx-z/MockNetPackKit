import Foundation
import zlib

/// 二进制协议 gzip 压缩（M6.1）。
///
/// 与 KK FDExtension `gzipCompress()` 输出格式一致：标准 gzip（1f 8b 头 + deflate +
/// CRC32 + ISIZE）。由 SDK 内置 zlib 产出（deflateInit2 windowBits = MAX_WBITS + 16）。
/// 注意：解压不在 SDK 内——已定（M6）由业务方 decrypt 闭包完成（如 KK 的
/// `decodeAes(data, ungzip: true)`）。
extension Data {
    /// 把本 Data 按标准 gzip 格式压缩；空数据或压缩失败返回 nil。
    func gzipCompressed() -> Data? {
        guard !isEmpty else { return nil }
        let input = [UInt8](self)
        var stream = z_stream()
        let initResult = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION, Z_DEFLATED,
            MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY,
            "1.2.12", Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        var output = Data(capacity: input.count / 2 + 64)
        var outBuffer = [UInt8](repeating: 0, count: 16384)
        var failed = false

        input.withUnsafeBufferPointer { inputPtr in
            stream.next_in = UnsafeMutablePointer(mutating: inputPtr.baseAddress)
            stream.avail_in = uInt(inputPtr.count)
            repeat {
                stream.next_out = outBuffer.withUnsafeMutableBytes {
                    $0.bindMemory(to: Bytef.self).baseAddress
                }
                stream.avail_out = uInt(outBuffer.count)
                let status = deflate(&stream, Z_FINISH)
                guard status == Z_OK || status == Z_STREAM_END else {
                    failed = true
                    return
                }
                let produced = outBuffer.count - Int(stream.avail_out)
                output.append(outBuffer, count: produced)
                if status == Z_STREAM_END { break }
            } while true
        }
        return failed ? nil : output
    }
}
