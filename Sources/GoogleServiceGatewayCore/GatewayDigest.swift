import Foundation

public enum GatewayDigest {
  public static func sha256Hex(_ data: Data) -> String {
    hex(sha256(Array(data)))
  }

  public static func hmacSHA256Hex(key: Data, message: Data) -> String {
    var keyBytes = Array(key)
    if keyBytes.count > 64 { keyBytes = sha256(keyBytes) }
    keyBytes += Array(repeating: 0, count: 64 - keyBytes.count)
    let outer = keyBytes.map { $0 ^ 0x5c }
    let inner = keyBytes.map { $0 ^ 0x36 }
    return hex(sha256(outer + sha256(inner + Array(message))))
  }

  public static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
    let lhs = Array(left.utf8)
    let rhs = Array(right.utf8)
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
    return difference == 0
  }

  private static func sha256(_ input: [UInt8]) -> [UInt8] {
    let constants: [UInt32] = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
      0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
      0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
      0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
      0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
      0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]
    var message = input
    let bitCount = UInt64(message.count) * 8
    message.append(0x80)
    while message.count % 64 != 56 { message.append(0) }
    message += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bitCount >> UInt64($0 * 8)) }

    var hash: [UInt32] = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    for offset in stride(from: 0, to: message.count, by: 64) {
      var words = Array(repeating: UInt32(0), count: 64)
      for index in 0..<16 {
        let start = offset + index * 4
        words[index] = UInt32(message[start]) << 24 | UInt32(message[start + 1]) << 16
          | UInt32(message[start + 2]) << 8 | UInt32(message[start + 3])
      }
      for index in 16..<64 {
        let value15 = words[index - 15]
        let value2 = words[index - 2]
        let sigma0 = rotate(value15, by: 7) ^ rotate(value15, by: 18) ^ (value15 >> 3)
        let sigma1 = rotate(value2, by: 17) ^ rotate(value2, by: 19) ^ (value2 >> 10)
        words[index] = words[index - 16] &+ sigma0 &+ words[index - 7] &+ sigma1
      }
      var working = hash
      for index in 0..<64 {
        let sigma1 = rotate(working[4], by: 6) ^ rotate(working[4], by: 11)
          ^ rotate(working[4], by: 25)
        let choice = (working[4] & working[5]) ^ (~working[4] & working[6])
        let first = working[7] &+ sigma1 &+ choice &+ constants[index] &+ words[index]
        let sigma0 = rotate(working[0], by: 2) ^ rotate(working[0], by: 13)
          ^ rotate(working[0], by: 22)
        let majority = (working[0] & working[1]) ^ (working[0] & working[2])
          ^ (working[1] & working[2])
        let second = sigma0 &+ majority
        working = [
          first &+ second, working[0], working[1], working[2],
          working[3] &+ first, working[4], working[5], working[6]
        ]
      }
      for index in hash.indices { hash[index] &+= working[index] }
    }
    return hash.flatMap { word in
      [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: word >> UInt32($0)) }
    }
  }

  private static func rotate(_ value: UInt32, by count: UInt32) -> UInt32 {
    (value >> count) | (value << (32 - count))
  }

  private static func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}
