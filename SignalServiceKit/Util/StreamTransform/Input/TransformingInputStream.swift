//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Simple wrapper around an `InputStream` that allows passing data through an
/// array of `StreamTransform` objects to alter the data before being passed
/// back to the caller.
public final class TransformingInputStream: InputStreamable {

    private let transforms: [any StreamTransform]
    private let inputStream: InputStreamable
    private let runLoop: RunLoop?

    private var buffer = Data()

    private var hasInitialized: Bool = false

    public init(
        transforms: [any StreamTransform],
        inputStream: InputStreamable,
        runLoop: RunLoop? = nil
    ) {
        self.transforms = transforms
        self.inputStream = inputStream
        self.runLoop = runLoop
    }

    /// `hasBytesAvailable` should return true if any of the following is true:
    /// 1. inputStream.hasBytesAvailable is true.
    /// 2. Any transforms still have bytes in the input buffers.
    /// 3. Any transfroms have yet to finalize.
    ///
    /// Each of the above places is a source of new bytes to return.
    /// Note that after a transform finalizes, it can still return true
    /// for `hasPendingBytes`.
    public var hasBytesAvailable: Bool {
        return
            inputStream.hasBytesAvailable
            || transforms.contains { $0.hasPendingBytes }
            || transforms.compactMap { $0 as? FinalizableStreamTransform }.contains { !$0.hasFinalized }
    }

    /// Read up to `maxLength` bytes of transformed input stream data.
    /// It should be noted that many transforms work in chunks of data and
    /// the call to `read` will often not return the full `maxLength`
    /// bytes, even if there is data available on either the wrapped input stream
    /// or the transform buffers.  Because of this, callers should not rely on the
    /// input stream returning less than `maxLength` bytes signalling the end
    /// of the input stream.  Instead, `hasBytesAvailable` should be
    /// consulted to see if there is possibly more data to be read from the input stream
    public func read(maxLength len: Int) throws -> Data {
        // Copy over the current data, if that's enough, return
        // otherwise, read data until the buffer is filled.
        // read some bytes, transform them, read some more, until the buffer is full
        if inputStream.hasBytesAvailable {
            let requestedLength = len - buffer.count
            let streamData = try inputStream.read(maxLength: requestedLength)

            // Transform the data.
            let data = try transforms.reduce(streamData) { try $1.transform(data: $0) }
            if data.count > 0 {
                return data
            }
        }

        // If there is no data remaining in the inputStream, read out any
        // remaining data in the transfom buffers, finalize the transforms
        // and read any data resulting from that.
        return try transforms.readNextRemainingBytes()
    }

    public func remove(from runloop: RunLoop, forMode mode: RunLoop.Mode) {
        inputStream.remove(from: runloop, forMode: mode)
    }

    public func schedule(in runloop: RunLoop, forMode mode: RunLoop.Mode) {
        inputStream.schedule(in: runloop, forMode: mode)
    }

    public func close() throws {
        try inputStream.close()
    }
}
