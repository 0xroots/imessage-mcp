import Foundation

// Fail-closed, deliberately narrow synthetic typedstream subset. This is not a
// general NSArchiver parser and is not approved for Messages data. Class and
// reference bytes are fixed by the accepted grammar: there is no object graph
// traversal, dynamic class loading, keyed unarchiving, or recursive parsing.
enum BodyDecoder {
    static let limit = 16_384
    enum Result: Equatable {
        case decoded(String)
        case unsupported
        case invalid
        case limitExceeded
    }
    private static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { i in
            let a = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[a..<hex.index(a, offsetBy: 2)], radix: 16)!
        }
    }
    private static let prefix = bytes("040b73747265616d747970656481e803840140848484194e534d757461626c6541747472696275746564537472696e67008484124e5341747472696275746564537472696e67008484084e534f626a6563740085928484840f4e534d757461626c65537472696e67018484084e53537472696e67019584012b")
    private static let runPrefix = bytes("868402694901")
    private static let runSuffix = bytes("928484840c4e5344696374696f6e6172790095840169008686")

    static func inspect(_ data: Data) -> Result {
        guard data.count <= limit else { return .limitExceeded }
        let input = [UInt8](data)
        // Never invoke NSKeyedUnarchiver on untrusted data.
        guard input.starts(with: prefix) else { return .unsupported }
        var position = prefix.count
        guard position < input.count else { return .invalid }
        var length = Int(input[position]); position += 1
        if (0x81...0x83).contains(length) {
            let count = length - 0x7f
            guard count <= input.count-position else { return .invalid }
            length = 0
            for i in 0..<count { length |= Int(input[position+i]) << (8*i) }
            position += count
        } else if length >= 0x80 { return .invalid }
        guard length <= limit else { return .limitExceeded }
        guard length <= input.count-position else { return .invalid }
        guard let text = String(bytes: input[position..<(position+length)], encoding: .utf8) else { return .invalid }
        position += length
        guard text.utf8.count <= limit, text.utf16.count <= 16_383 else { return .limitExceeded }
        let suffix: [UInt8]
        if text.isEmpty { suffix = [0x86,0x86] }
        else {
            let units = text.utf16.count
            let encoded = units < 128 ? [UInt8(units)] : [0x81, UInt8(units & 255), UInt8((units >> 8) & 255)]
            suffix = runPrefix + encoded + runSuffix
        }
        // The entire suffix must match: trailing bytes and unsupported runs fail.
        guard Array(input[position...]) == suffix else { return .unsupported }
        return .decoded(text)
    }

    static func decode(_ data: Data) -> String? {
        if case .decoded(let text) = inspect(data) { return text }
        return nil
    }
}
