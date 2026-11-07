import Foundation

/// Turns Home Assistant friendly names into short, room-relative names the way
/// Apple Home shows accessories ("Mummy Room Mummy Room Fan" in Mummy Room → "Fan").
///
/// HA friendly names are usually "<device name> <entity name>", and many
/// integrations repeat the room in both, or use raw slugs
/// ("meghna_room_bed_lamp meghna room bed lamp"). The cleaner:
/// 1. normalises slugs (`_`, and `-` inside all-lowercase slug words) to spaces;
/// 2. repeatedly strips leading copies of the device name (also with its words
///    re-ordered, e.g. "ground Floor Lobby" for device "Lobby Ground Floor") and of
///    any room name (space-insensitive, so "paparoom" matches "Papa Room");
/// 3. if what's left is empty, uses the device name (minus the room); if it's only
///    a generic word ("Relay 1", "LED", "lights"), prefixes it with the device name
///    (minus the room) so it stays meaningful;
/// 4. capitalises all-lowercase words, keeping words that already have capitals
///    ("LED", "TubeLight", "TV").
public enum NameCleaner {

    /// Words that mean nothing on their own once the device name is gone.
    static let genericWords: Set<String> = [
        "relay", "switch", "light", "lights", "led", "onoff", "power", "socket", "plug", "output", "channel",
    ]

    /// - Parameters:
    ///   - friendlyName: HA `friendly_name` (or the entity ID if none).
    ///   - deviceName: the HA device's name (`name_by_user` or `name`), if any.
    ///   - roomNames: names of the room the device is going into and its HA area.
    public static func clean(friendlyName: String, deviceName: String? = nil, roomNames: [String] = []) -> String {
        let original = words(friendlyName)
        guard !original.isEmpty else { return friendlyName }
        let device = deviceName.map(words) ?? []
        let rooms = roomNames.map(words).filter { !$0.isEmpty }

        var rest = original
        var changed = true
        while changed && !rest.isEmpty {
            changed = false
            if let r = stripPrefix(device, from: rest, allowReorder: true) { rest = r; changed = true; continue }
            for room in rooms {
                if let r = stripPrefix(room, from: rest, allowReorder: false) { rest = r; changed = true; break }
            }
        }

        // The device name minus any room prefix ("Papa Room" in Papa Room → []).
        var deviceShort = device
        for room in rooms {
            if let r = stripPrefix(room, from: deviceShort, allowReorder: false) { deviceShort = r }
        }

        let result: [String]
        if rest.isEmpty {
            result = deviceShort.isEmpty ? (device.isEmpty ? original : device) : deviceShort
        } else if isGeneric(rest) {
            result = deviceShort + rest
        } else {
            result = rest
        }
        return result.map(prettify).joined(separator: " ")
    }

    /// Cleans an HA area / room name ("golu_balcony" → "Golu Balcony").
    public static func cleanRoomName(_ name: String) -> String {
        let w = words(name)
        return w.isEmpty ? name : w.map(prettify).joined(separator: " ")
    }

    // MARK: - Internals

    static func words(_ s: String) -> [String] {
        s.replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .flatMap { token -> [String] in
                let t = String(token)
                // "meghna-ir-blaster" is a slug; "Pre-release" / "On-Off" are words.
                if t.contains("-"), t == t.lowercased(), t.rangeOfCharacter(from: .letters) != nil {
                    return t.split(separator: "-").map(String.init)
                }
                return [t]
            }
            .filter { !$0.isEmpty }
    }

    private static func key(_ w: String) -> String { w.lowercased() }

    /// If `rest` starts with `prefix` (case-insensitive; spaces ignored, so
    /// ["paparoom"] matches ["Papa", "Room"] and vice versa), returns the rest.
    /// With `allowReorder`, the first `prefix.count` words may also be a
    /// permutation of `prefix`. Never strips everything only by reordering.
    static func stripPrefix(_ prefix: [String], from rest: [String], allowReorder: Bool) -> [String]? {
        guard !prefix.isEmpty, !rest.isEmpty else { return nil }
        let target = prefix.map(key).joined()
        // Space-insensitive in-order match: consume words until the joined text equals the target.
        var joined = ""
        for (i, w) in rest.enumerated() {
            joined += key(w)
            if joined == target { return Array(rest[(i + 1)...]) }
            if !target.hasPrefix(joined) { break }
        }
        if allowReorder, prefix.count > 1, rest.count > prefix.count {
            let head = rest.prefix(prefix.count).map(key).sorted()
            if head == prefix.map(key).sorted() { return Array(rest.dropFirst(prefix.count)) }
        }
        return nil
    }

    static func isGeneric(_ w: [String]) -> Bool {
        guard let first = w.first, genericWords.contains(key(first)) else { return false }
        return w.dropFirst().allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    static func prettify(_ w: String) -> String {
        guard w == w.lowercased(), let f = w.first, f.isLetter else { return w }
        return f.uppercased() + w.dropFirst()
    }
}
