import AppKit

enum DestructionTool: Int, CaseIterable {
    case hammer
    case machineGun
    case flamethrower
    case bomb
    case chainsaw
    case lightning

    var title: String {
        switch self {
        case .hammer: "망치"
        case .machineGun: "기관총"
        case .flamethrower: "화염방사기"
        case .bomb: "시한폭탄"
        case .chainsaw: "전기톱"
        case .lightning: "번개포"
        }
    }

    var symbol: String {
        switch self {
        case .hammer: "🔨"
        case .machineGun: "💥"
        case .flamethrower: "🔥"
        case .bomb: "💣"
        case .chainsaw: "🪚"
        case .lightning: "⚡️"
        }
    }

    var shortcut: String {
        String(rawValue + 1)
    }

    var cursor: NSCursor {
        switch self {
        case .hammer: .crosshair
        case .machineGun: .crosshair
        case .flamethrower: .pointingHand
        case .bomb: .crosshair
        case .chainsaw: .crosshair
        case .lightning: .crosshair
        }
    }
}
