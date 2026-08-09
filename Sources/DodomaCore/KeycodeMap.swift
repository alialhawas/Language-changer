import Carbon.HIToolbox
import Foundation

/// Builds synthetic `CapturedKey` sequences from Latin text using the standard
/// US/ANSI hardware keycodes.
///
/// This exists purely for the `--render` CLI and for tests: real captures carry
/// the keycodes the hardware actually reported. It is not part of the runtime
/// detection path.
public enum KeycodeMap {
    /// US/ANSI virtual keycodes for the unshifted characters the harness
    /// accepts. Uppercase letters reuse the lowercase keycode plus `.shift`.
    private static let keycodesByCharacter: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, " ": 49, "`": 50,
    ]

    /// Returns `nil` if any character has no US keycode.
    public static func keys(forLatin text: String) -> [CapturedKey]? {
        let keyboardType = UInt32(LMGetKbdType())
        var keys: [CapturedKey] = []
        keys.reserveCapacity(text.count)

        for character in text {
            let isShifted = character.isASCII && character.isUppercase
            let unshifted = isShifted ? Character(character.lowercased()) : character
            guard let keycode = keycodesByCharacter[unshifted] else { return nil }
            keys.append(
                CapturedKey(
                    keycode: keycode,
                    flags: isShifted ? [.shift] : [],
                    producedText: String(character),
                    keyboardType: keyboardType))
        }
        return keys
    }
}
