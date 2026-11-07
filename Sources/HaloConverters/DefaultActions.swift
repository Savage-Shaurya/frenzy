import HaloCore

/// Every built-in action. Each family lives in its own file and owns its `ActionID`s
/// (prefix them with the family: "image.", "pdf.", "video.", "audio.", "document.", "text.", "archive.").
public enum DefaultActions {
    /// Choices that need the media engine are only listed when it's in this copy of the app (`MediaEngine.isAvailable`).
    /// The app and the worker answer the same way: the app looks inside the worker's bundle, the worker in its own.
    public static func all() -> [ConversionAction] { all(engine: MediaEngine.isAvailable) }

    static func all(engine: Bool) -> [ConversionAction] {
        ImageActions.actions(engine: engine) + PDFActions.all + VideoActions.all + (engine ? EngineActions.all : [])
            + AudioActions.actions(engine: engine) + DocumentActions.all + EpubActions.all + TextActions.all + ArchiveActions.all
    }

    public static func registry(usage: any UsageStore = DefaultsUsageStore()) -> ActionRegistry {
        ActionRegistry(actions: all(), usage: usage)
    }

    static func registry(engine: Bool, usage: any UsageStore) -> ActionRegistry {
        ActionRegistry(actions: all(engine: engine), usage: usage)
    }
}
