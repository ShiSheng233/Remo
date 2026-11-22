import Foundation

/// Reed-Solomon repair fragments over GF(256). A message of `count` data fragments plus any
/// number of repair fragments is rebuilt from any `count` of them.
///
/// The code is a Cauchy matrix: repair row `j` weighs data fragment `i` by `1 / (x(j) ^ i)`
/// with `x(j) = 255 - j`. Every square part of such a matrix is invertible, and a row depends
/// only on its own index, so the receiver need not know how many repair fragments were made.
enum Repair {
    /// Data and repair fragments of one message must name distinct field elements.
    static let maxData = 128
    static let maxRepair = 127

    private static let tables: (exp: [UInt8], log: [UInt8]) = {
        var exp = [UInt8](repeating: 0, count: 510)
        var log = [UInt8](repeating: 0, count: 256)
        var value = 1
        for power in 0..<255 {
            exp[power] = UInt8(value)
            exp[power + 255] = UInt8(value)
            log[value] = UInt8(power)
            value <<= 1
            if value & 0x100 != 0 { value ^= 0x11D }
        }
        return (exp, log)
    }()

    /// Full 256×256 GF(256) multiplication table (64 KB), built once so `accumulate` never
    /// allocates per fragment or recomputes a row table on the hot path.
    private static let multiplyTable: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256 * 256)
        for weight in 1..<256 {
            let shift = Int(tables.log[weight])
            let base = weight << 8
            for byte in 1..<256 {
                table[base | byte] = tables.exp[Int(tables.log[byte]) + shift]
            }
        }
        return table
    }()

    private static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        multiplyTable[(Int(a) << 8) | Int(b)]
    }

    private static func inverse(_ a: UInt8) -> UInt8 {
        tables.exp[255 - Int(tables.log[Int(a)])]
    }

    private static func weight(repair: Int, data: Int) -> UInt8 {
        inverse(UInt8(255 - repair) ^ UInt8(data))
    }

    /// `target ^= weight * source`, over as many bytes as the two share.
    private static func accumulate(
        _ source: UnsafeBufferPointer<UInt8>, times weight: UInt8, into target: inout [UInt8]
    ) {
        guard weight != 0 else { return }
        let count = min(source.count, target.count)
        guard count > 0, let src = source.baseAddress else { return }
        target.withUnsafeMutableBufferPointer { dst in
            guard let out = dst.baseAddress else { return }
            if weight == 1 {
                for offset in 0..<count { out[offset] ^= src[offset] }
                return
            }
            multiplyTable.withUnsafeBufferPointer { table in
                let row = table.baseAddress! + (Int(weight) << 8)
                for offset in 0..<count { out[offset] ^= row[Int(src[offset])] }
            }
        }
    }

    private static func accumulate(_ source: Data, times weight: UInt8, into target: inout [UInt8]) {
        guard weight != 0 else { return }
        source.withUnsafeBytes { bytes in
            accumulate(bytes.bindMemory(to: UInt8.self), times: weight, into: &target)
        }
    }

    /// Repair fragments for data fragments of `length` bytes each, the last one zero-padded.
    static func encode(_ fragments: [Data], repair: Int, length: Int) -> [Data] {
        (0..<repair).map { row in
            var parity = [UInt8](repeating: 0, count: length)
            for (index, fragment) in fragments.enumerated() {
                accumulate(fragment, times: weight(repair: row, data: index), into: &parity)
            }
            return Data(parity)
        }
    }

    /// Rebuilds the missing data fragments. `parts` holds `count` fragments by index, repair
    /// fragments numbered from `count`. Rebuilt fragments are `length` bytes: the caller trims
    /// the last one. Returns nil if `parts` cannot determine the message.
    static func decode(_ parts: [Int: Data], count: Int, length: Int) -> [Data]? {
        let missing = (0..<count).filter { parts[$0] == nil }
        let rows = parts.keys.filter { $0 >= count }.sorted().prefix(missing.count).map { $0 - count }
        guard rows.count == missing.count, rows.allSatisfy({ $0 < maxRepair }) else { return nil }
        guard !missing.isEmpty else { return (0..<count).map { parts[$0]! } }

        // Take what the present data fragments contributed out of each repair fragment. What
        // is left is the missing fragments, mixed by a square part of the matrix.
        var mixed = rows.map { row -> [UInt8] in
            var bytes = [UInt8](repeating: 0, count: length)
            accumulate(parts[count + row]!, times: 1, into: &bytes)
            for index in 0..<count {
                guard let fragment = parts[index] else { continue }
                accumulate(fragment, times: weight(repair: row, data: index), into: &bytes)
            }
            return bytes
        }
        var matrix = rows.map { row in missing.map { weight(repair: row, data: $0) } }

        // Gauss-Jordan elimination, applying each row operation to the fragments as well.
        let size = missing.count
        for column in 0..<size {
            guard let pivot = (column..<size).first(where: { matrix[$0][column] != 0 }) else { return nil }
            matrix.swapAt(column, pivot)
            mixed.swapAt(column, pivot)
            let scale = inverse(matrix[column][column])
            if scale != 1 {
                matrix[column] = matrix[column].map { multiply($0, scale) }
                let rowOffset = Int(scale) << 8
                mixed[column].withUnsafeMutableBufferPointer { dst in
                    multiplyTable.withUnsafeBufferPointer { table in
                        let row = table.baseAddress! + rowOffset
                        for offset in 0..<dst.count { dst[offset] = row[Int(dst[offset])] }
                    }
                }
            }
            let source = mixed[column]
            source.withUnsafeBufferPointer { sourceBytes in
                for row in 0..<size where row != column && matrix[row][column] != 0 {
                    let factor = matrix[row][column]
                    for index in 0..<size { matrix[row][index] ^= multiply(matrix[column][index], factor) }
                    accumulate(sourceBytes, times: factor, into: &mixed[row])
                }
            }
        }
        var rebuilt: [Int: Data] = [:]
        for (position, index) in missing.enumerated() { rebuilt[index] = Data(mixed[position]) }
        return (0..<count).map { parts[$0] ?? rebuilt[$0]! }
    }
}
