import Foundation

struct BoundedTextResult: Equatable, Sendable {
    var value: String
    var wasTruncated: Bool
}

enum TextInputPolicy {
    // Keep interactive text comfortably below the point where AppKit layout,
    // request encoding, and local-provider argument handling become expensive.
    static let maximumMessageUTF16Units = 30_000

    static func bounded(
        _ value: String,
        maximumUTF16Units: Int = maximumMessageUTF16Units
    ) -> String {
        boundedResult(value, maximumUTF16Units: maximumUTF16Units).value
    }

    static func boundedResult(
        _ value: String,
        maximumUTF16Units: Int = maximumMessageUTF16Units
    ) -> BoundedTextResult {
        guard maximumUTF16Units > 0 else {
            return BoundedTextResult(value: "", wasTruncated: !value.isEmpty)
        }

        let scalars = value.unicodeScalars
        var end = scalars.startIndex
        var usedUnits = 0
        while end < scalars.endIndex {
            let scalar = scalars[end]
            let scalarUnits = scalar.value > 0xFFFF ? 2 : 1
            guard usedUnits + scalarUnits <= maximumUTF16Units else {
                return BoundedTextResult(
                    value: String(scalars[..<end]),
                    wasTruncated: true
                )
            }
            usedUnits += scalarUnits
            end = scalars.index(after: end)
        }
        return BoundedTextResult(value: value, wasTruncated: false)
    }

    static func preparedMessage(
        _ value: String,
        maximumUTF16Units: Int = maximumMessageUTF16Units
    ) -> String? {
        let prepared = bounded(value, maximumUTF16Units: maximumUTF16Units)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prepared.isEmpty ? nil : prepared
    }
}
