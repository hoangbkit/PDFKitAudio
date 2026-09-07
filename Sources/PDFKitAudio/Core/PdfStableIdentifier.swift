import Foundation

enum PdfStableIdentifier {
    static func make(prefix: String, components: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037

        for component in components {
            // Length-prefix each component so values containing separators cannot
            // accidentally produce the same byte stream.
            for byte in String(component.utf8.count).utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= 58
            hash &*= 1_099_511_628_211

            for byte in component.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= 0xff
            hash &*= 1_099_511_628_211
        }

        return prefix + "-" + String(hash, radix: 16)
    }
}
