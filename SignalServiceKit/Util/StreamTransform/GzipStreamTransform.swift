//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import zlib

public class GzipStreamTransform: StreamTransform, FinalizableStreamTransform {

    public enum Operation {
        case compress
        case decompress
    }

    public enum GzipError: Swift.Error {
        case initializeFailed
        case streamError
        case dataError
        case outOfMemoryError
        case bufferError
        case transformFailed
        case finalizeFailed
    }

    private enum Constants {
        static let BufferSize: Int = 32_768

        // Use the maximum memory window (32K) for compressing the data
        static let MaxWindowBits = MAX_WBITS

        // adding 16 to the window bits will signal the gzip header should be written
        static let GzipDeflateHeaderWindowBits: Int32 = 16

        // adding 32 to the window bits will signal the gzip header/footer should be read
        static let GzipInflateHeaderWindowBits: Int32 = 32
    }

    public private(set) var hasFinalized = false

    private var outputCount: Int = 0

    private var stream: z_stream
    private let operation: Operation

    init(_ operation: Operation) throws {
        self.operation = operation
        self.stream = z_stream()

        var status = Z_OK
        switch operation {
        case .compress:
            status = deflateInit2_(
                &stream,
                Z_BEST_COMPRESSION,
                Z_DEFLATED,
                Constants.MaxWindowBits + Constants.GzipDeflateHeaderWindowBits,
                MAX_MEM_LEVEL,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
        case .decompress:
            status = inflateInit2_(
                &stream,
                Constants.MaxWindowBits + Constants.GzipInflateHeaderWindowBits,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
        }

        // Set the amount of space available to start processing
        stream.avail_out = UInt32(Constants.BufferSize)

        guard status == Z_OK else {
            throw GzipError.initializeFailed
        }
    }

    /// Pass the supplied `data` to zlib for processing and return any data that results.
    /// Note that there is no guarantee that data will be retuned from the transform since compression/decompression
    /// will buffer internally.
    public func transform(data: Data) throws -> Data {
        try process(data: data, finalize: false)
    }

    private func process(data: Data, finalize: Bool) throws -> Data {

        let flags: Int32 = finalize ? Z_FINISH : Z_NO_FLUSH
        var status: Int32 = Z_OK

        var returnData = Data()
        var buffer = Data(count: Constants.BufferSize)
        var bufferWritten: UInt = 0

        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in

            // Initialized the input buffer.
            // Set stream.next_in to point at the passed in data buffer.
            // Then move the pointer forward the amount of data that's aready been passed to deflate()
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: ptr.bindMemory(to: Bytef.self).baseAddress!)
            // Set stream.avail_in to the size of the remaining passed in data
            stream.avail_in = UInt32(clamping: data.count)

            repeat {
                // From zlib docs:
                // "If inflate (or deflate) returns Z_OK and with zero avail_out, it must be called again
                // after making room in the output buffer because there might be more output pending."
                //
                // If this is encountered, move the current buffer into `returnData` and reset to an empty buffer
                if stream.avail_out == 0 {
                    returnData.append(buffer)
                    buffer = Data(count: Constants.BufferSize)
                    bufferWritten = 0
                    stream.avail_out = UInt32(Constants.BufferSize)
                }

                buffer.withUnsafeMutableBytes { (outputPtr: UnsafeMutableRawBufferPointer) in
                    // Set stream.next_out to point at the output buffer and move the pointer
                    // forward the amount of data that's already been written to the output buffer.
                    // In most use cases `bufferWritten` should be '0', but there is nothing preventing
                    // inflate/deflate from returning without having processed the entire input.
                    // If this happens, and `avail_out` > 0, we should attempt to append to the output
                    // buffer on subsequent calls into inflate/deflate
                    stream.next_out = outputPtr.bindMemory(to: Bytef.self).baseAddress!.advanced(by: Int(clamping: bufferWritten))

                    switch operation {
                    case .compress:
                        status = deflate(&stream, flags)
                    case .decompress:
                        status = inflate(&stream, flags)
                    }

                    // stream.avail_out should never be greater than Constants.BufferSize, but clamp just to be sure.
                    bufferWritten = UInt(clamping: Constants.BufferSize - Int(stream.avail_out))
                    stream.next_out = nil
                }

                // Continue to call deflate/inflate as long as the status remains Z_OK and one of the
                // following is true:
                //   a) The stream reports that the output buffer is full (avail_out == 0). This signals
                //      that there may be additional output available, but the output buffer ran out of room.
                //   b) There is still data available to pass into inflate/deflate (avail_in > 0). The
                //      situations where this occurs should be less frequent (e.g. - input larger
                //      than inflate/deflate can handle in one call) or happen in association
                //      with (a) above.
                //
                // From the zlib docs:
                //   "If not all input can be processed (because there is not enough room in the output
                //    buffer), then next_in and avail_in are updated accordingly, and processing will
                //    resume at this point for the next call of inflate (or deflate)."
            } while (stream.avail_out == 0 || stream.avail_in > 0) && status == Z_OK
        }

        switch status {
        case Z_OK, Z_STREAM_END:
            break
        case Z_STREAM_ERROR:
            throw GzipError.streamError
        case Z_DATA_ERROR:
            throw GzipError.dataError
        case Z_MEM_ERROR:
            throw GzipError.outOfMemoryError
        case Z_BUF_ERROR:
            throw GzipError.bufferError
        default:
            throw GzipError.transformFailed
        }

        // Append the remaining buffer to the return data and reset the stream field.
        returnData.append(buffer.subdata(in: 0..<Int(clamping: bufferWritten)))
        buffer = Data(count: Constants.BufferSize)
        bufferWritten = 0
        stream.avail_out = UInt32(Constants.BufferSize)

        outputCount += returnData.count
        return returnData
    }

    public func finalize() throws -> Data {
        hasFinalized = true

        // Finalize the gzip and return any remaining data
        var finalData = try process(data: Data(), finalize: true)
        outputCount += finalData.count

        switch operation {
        case .compress:
            // Pad the gzip similar to how attachments are padded.
            // gzip will ignore this trailing data during decompression.
            let unpaddedSize = UInt(bitPattern: outputCount)
            let paddedSize = Cryptography.paddedSize(unpaddedSize: unpaddedSize)
            if paddedSize > unpaddedSize {
                finalData.append(Data(repeating: 0, count: Int(paddedSize - unpaddedSize)))
            }
        case .decompress:
            break
        }

        // Close the zlib stream
        var status = Z_OK
        switch operation {
        case .compress:
            status = deflateEnd(&stream)
        case .decompress:
            status = inflateEnd(&stream)
        }
        guard status == Z_OK else {
            throw GzipError.finalizeFailed
        }

        return finalData
    }
}
