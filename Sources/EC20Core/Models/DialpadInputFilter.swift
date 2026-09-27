import Foundation

public struct DialpadInputFilter: Sendable {
    /// Allowed characters on phone dialpad: 0-9, +, *, #
    public static let allowedCharacters: Set<Character> = [
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
        "+", "*", "#"
    ]

    /// Filters any input string, retaining only allowed dialpad characters.
    public static func filter(_ input: String) -> String {
        return String(input.filter { allowedCharacters.contains($0) })
    }

    /// Checks if a single character is an allowed dialpad key.
    public static func isAllowed(_ character: Character) -> Bool {
        return allowedCharacters.contains(character)
    }
}
