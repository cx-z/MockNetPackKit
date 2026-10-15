//
//  Gzip.swift
//  MockNetPackKit
//
//  L5.2：gzip/zlib 解压（SDK 内置，零侵入采集 zipType=1 包需要）。
//  与 KK `gzipUncompress`（FDExtension，inflateInit2(MAX_WBITS+16)）对齐：
//  windowBits=31 自动检测 gzip/zlib 头；解压失败返回 nil，调用方回退原始字节。
//

import Foundation
import zlib

enum Gzip {

    /// gzip/zlib 解压（方法名避免与 zlib.inflate 同名遮蔽）。
    /// - Parameter data: 压缩字节。
    /// - Returns: 解压后字节；输入空 / 解压失败返回 nil。
    static func gunzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var stream = z_stream()
        // windowBits=31：自动检测 gzip（16+15）与 zlib（15）封装，对齐 KK 实现。
        let initStatus = inflateInit2_(&stream, 31, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let base = raw.baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: base.assumingMemoryBound(to: UInt8.self))
            stream.avail_in = uInt(data.count)

            var output = Data(capacity: data.count * 2)
            var status: Int32 = Z_OK
            while true {
                stream.next_out = buffer
                stream.avail_out = uInt(bufferSize)
                status = zlib.inflate(&stream, Z_SYNC_FLUSH)
                let produced = bufferSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
                if status == Z_STREAM_END {
                    break   // 流结束：单段解压完成（对齐 KK gzipUncompress）
                }
                if status != Z_OK {
                    return nil
                }
                if stream.avail_out > 0 {
                    // 输入已消费且输出未填满：单次解压完成。
                    break
                }
            }
            return output
        }
    }
}
