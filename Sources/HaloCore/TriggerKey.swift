/// The key the user holds during a drag to summon the ring. AppKit flag mapping lives in HaloDrag.
public enum TriggerKey: String, CaseIterable, Sendable, Codable {
    case option, shift, control, function

    public var displayName: String {
        switch self {
        case .option: "⌥ Option"
        case .shift: "⇧ Shift"
        case .control: "⌃ Control"
        case .function: "fn Function"
        }
    }
}
