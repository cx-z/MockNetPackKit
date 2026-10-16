//
//  PayloadPreview.swift
//  MockNetPackKit
//
//  L6.5d：长连接 payload 通用解码链（公开工具）。
//
//  背景：各业务方接入长连接 hook 时，「包体 Data → Web 可读文本」有一套
//  通用样板（gzip 嗅探解压 → JSON 美化 → UTF-8 原文 → 字节数兜底），此前
//  每个接入方都要在自己工程里抄一遍。SDK 下沉为公开静态工具：
//  - gzip 嗅探与具体框架的 zipType 字段无关（按标准 1f 8b 头判断）；
//  - JSON pretty / UTF-8 兜底与框架无关；
//  - 框架特有解码（如某推送协议的嵌套 protobuf 剥层）仍由业务方经
//    LongConnHookSpec.customPayloadDecoder 前置提供，失败则 fallthrough
//    到本通用链。
//
//  纯函数无状态；Swift 6 并发安全。

import Foundation
import zlib

/// 长连接 payload 通用解码链（公开）。
public enum MNPPayloadPreview {

    /// Data → 可读文本：① gzip 嗅探解压 → ② JSON 对象/数组美化（key 排序）
    /// → ③ UTF-8 原文。都失败返回 nil（调用方按字节数兜底）。
    public static func text(of data: Data) -> String? {
        let inflated = gzipInflatedIfNeeded(data)
        // JSON 对象。
        if let dict = (try? JSONSerialization.jsonObject(with: inflated)) as? [String: Any],
           let s = string(from: dict) {
            return s
        }
        // JSON 数组。
        if let arr = (try? JSONSerialization.jsonObject(with: inflated)) as? [Any],
           JSONSerialization.isValidJSONObject(arr),
           let d = try? JSONSerialization.data(withJSONObject: arr,
                                               options: [.sortedKeys, .prettyPrinted]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        // UTF-8 原文。
        return String(data: inflated, encoding: .utf8)
    }

    /// 字典 → 排序 pretty JSON 文本（业务 customPayloadDecoder 解出字典后调用）；
    /// 不可 JSON 化返回 nil。
    public static func string(from dict: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(dict),
              let d = try? JSONSerialization.data(withJSONObject: dict,
                                                  options: [.sortedKeys, .prettyPrinted]),
              let s = String(data: d, encoding: .utf8) else {
            return nil
        }
        return s
    }

    // MARK: - gzip 嗅探解压（zlib inflate，标准 gzip 格式）

    /// 标准 gzip 解压：数据前两字节为 1f 8b 时按 gzip 解压，否则原样返回。
    /// 解压失败也原样返回（调用方继续走后续解码分支）。
    static func gzipInflatedIfNeeded(_ data: Data) -> Data {
        guard data.count >= 2 else { return data }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x1f, bytes[1] == 0x8b else { return data }

        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 16, "1.2.12",
                             Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return data
        }
        defer { inflateEnd(&stream) }

        var output = Data(capacity: data.count * 4)
        var outBuffer = [UInt8](repeating: 0, count: 16384)
        var failed = false

        let input = [UInt8](data)
        input.withUnsafeBufferPointer { inputPtr in
            stream.next_in = UnsafeMutablePointer(mutating: inputPtr.baseAddress)
            stream.avail_in = uInt(inputPtr.count)
            repeat {
                stream.next_out = outBuffer.withUnsafeMutableBytes {
                    $0.bindMemory(to: Bytef.self).baseAddress
                }
                stream.avail_out = uInt(outBuffer.count)
                let status = inflate(&stream, Z_NO_FLUSH)
                guard status == Z_OK || status == Z_STREAM_END else {
                    failed = true
                    return
                }
                let produced = outBuffer.count - Int(stream.avail_out)
                output.append(outBuffer, count: produced)
                if status == Z_STREAM_END { break }
            } while stream.avail_out == 0
        }
        return failed ? data : output
    }
}
