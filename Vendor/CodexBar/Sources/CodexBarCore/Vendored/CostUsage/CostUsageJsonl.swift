import Foundation

enum CostUsageJsonl {
    struct Line {
        let bytes: Data
        let wasTruncated: Bool
    }

    struct ScanOutcome {
        let parsedBytes: Int64
        let stoppedEarly: Bool
        let discardingTruncatedLine: Bool
    }

    @discardableResult
    static func scan(
        fileURL: URL,
        offset: Int64 = 0,
        maxLineBytes: Int,
        prefixBytes: Int,
        onLine: (Line) -> Void) throws
        -> Int64
    {
        try self.scanResumable(
            fileURL: fileURL,
            offset: offset,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            checkCancellation: nil,
            onLine: onLine).parsedBytes
    }

    @discardableResult
    static func scan(
        fileURL: URL,
        offset: Int64 = 0,
        maxLineBytes: Int,
        prefixBytes: Int,
        checkCancellation: (() throws -> Void)? = nil,
        onLine: (Line) -> Void) throws
        -> Int64
    {
        try self.scanResumable(
            fileURL: fileURL,
            offset: offset,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            checkCancellation: checkCancellation,
            onLine: onLine).parsedBytes
    }

    /// Stops only at a resumable byte boundary. If the current chunk ends in
    /// the middle of a JSONL record, the returned offset rewinds to that
    /// record's first byte so the next pass never drops a partial line.
    static func scanResumable(
        fileURL: URL,
        offset: Int64 = 0,
        endOffset: Int64? = nil,
        maxLineBytes: Int,
        prefixBytes: Int,
        checkCancellation: (() throws -> Void)? = nil,
        shouldStop: (() -> Bool)? = nil,
        discardingTruncatedLine initialDiscardingTruncatedLine: Bool = false,
        withinRoot root: URL? = nil,
        onLine: (Line) -> Void) throws
        -> ScanOutcome
    {
        let handle = try CostUsageScanner.codexOpenRegularFileForReading(
            fileURL: fileURL,
            withinRoot: root)
        defer { try? handle.close() }

        let startOffset = max(0, offset)
        let boundedEndOffset = endOffset.map { max(startOffset, $0) }
        if startOffset > 0 {
            try handle.seek(toOffset: UInt64(startOffset))
        }

        var current = Data()
        current.reserveCapacity(4 * 1024)
        var lineBytes = 0
        var truncated = false
        var discardingTruncatedLine = initialDiscardingTruncatedLine
        var bytesRead: Int64 = 0

        func appendSegment(_ bytes: UnsafePointer<UInt8>, count: Int) {
            guard count > 0 else { return }
            lineBytes += count
            if current.count < prefixBytes {
                let appendCount = min(prefixBytes - current.count, count)
                if appendCount > 0 {
                    current.append(bytes, count: appendCount)
                }
            }
            if lineBytes > maxLineBytes || lineBytes > prefixBytes {
                truncated = true
            }
        }

        func flushLine() {
            guard lineBytes > 0 else { return }
            let line = Line(bytes: current, wasTruncated: truncated)
            onLine(line)
            current.removeAll(keepingCapacity: true)
            lineBytes = 0
            truncated = false
        }

        func stoppedOutcome() -> ScanOutcome {
            if discardingTruncatedLine {
                return ScanOutcome(
                    parsedBytes: startOffset + bytesRead,
                    stoppedEarly: true,
                    discardingTruncatedLine: true)
            }
            if truncated {
                // The parser will ignore this oversized logical line. Emit its
                // bounded prefix once, then checkpoint inside discard mode so
                // later passes can advance to the newline instead of rewinding
                // forever to the line's first byte.
                flushLine()
                discardingTruncatedLine = true
                return ScanOutcome(
                    parsedBytes: startOffset + bytesRead,
                    stoppedEarly: true,
                    discardingTruncatedLine: true)
            }
            return ScanOutcome(
                parsedBytes: startOffset + bytesRead - Int64(lineBytes),
                stoppedEarly: true,
                discardingTruncatedLine: false)
        }

        while true {
            try checkCancellation?()
            if shouldStop?() == true {
                return stoppedOutcome()
            }
            let reachedEOF = try autoreleasepool {
                let readSize: Int
                if let boundedEndOffset {
                    let remaining = boundedEndOffset - (startOffset + bytesRead)
                    guard remaining > 0 else {
                        if discardingTruncatedLine {
                            // This is the authoritative frozen EOF. The line
                            // was already classified oversized and emitted once,
                            // so finishing discard mode cannot create a suffix.
                            discardingTruncatedLine = false
                        } else {
                            flushLine()
                        }
                        return true
                    }
                    readSize = Int(min(Int64(256 * 1024), remaining))
                } else {
                    readSize = 256 * 1024
                }
                let chunk = try handle.read(upToCount: readSize) ?? Data()
                if chunk.isEmpty {
                    if discardingTruncatedLine {
                        discardingTruncatedLine = false
                    } else {
                        flushLine()
                    }
                    return true
                }

                try checkCancellation?()
                bytesRead += Int64(chunk.count)
                chunk.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                    var segmentStart = 0
                    var index = 0
                    while index < rawBuffer.count {
                        if base[index] == 0x0A {
                            if discardingTruncatedLine {
                                discardingTruncatedLine = false
                                current.removeAll(keepingCapacity: true)
                                lineBytes = 0
                                truncated = false
                            } else {
                                appendSegment(base.advanced(by: segmentStart), count: index - segmentStart)
                                flushLine()
                            }
                            segmentStart = index + 1
                        }
                        index += 1
                    }
                    if segmentStart < rawBuffer.count, !discardingTruncatedLine {
                        appendSegment(base.advanced(by: segmentStart), count: rawBuffer.count - segmentStart)
                    }
                }
                return false
            }
            if reachedEOF { break }
            try checkCancellation?()
            if shouldStop?() == true {
                return stoppedOutcome()
            }
        }

        return ScanOutcome(
            parsedBytes: startOffset + bytesRead,
            stoppedEarly: false,
            discardingTruncatedLine: discardingTruncatedLine)
    }
}
