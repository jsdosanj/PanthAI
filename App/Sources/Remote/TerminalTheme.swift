import UIKit

struct TerminalTheme: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let foreground: UIColor
    let background: UIColor

    static let all: [TerminalTheme] = [
        .init(name: "Midnight", foreground: UIColor(white: 0.92, alpha: 1), background: UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)),
        .init(name: "Solarized Dark", foreground: UIColor(red: 0.51, green: 0.58, blue: 0.59, alpha: 1), background: UIColor(red: 0.0, green: 0.17, blue: 0.21, alpha: 1)),
        .init(name: "Dracula", foreground: UIColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1), background: UIColor(red: 0.16, green: 0.16, blue: 0.21, alpha: 1)),
        .init(name: "Paper", foreground: UIColor(white: 0.1, alpha: 1), background: UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)),
        .init(name: "Matrix", foreground: UIColor(red: 0.2, green: 1.0, blue: 0.4, alpha: 1), background: .black),
    ]
    static func named(_ name: String) -> TerminalTheme { all.first { $0.name == name } ?? all[0] }
}
