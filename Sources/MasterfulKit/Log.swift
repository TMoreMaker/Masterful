import OSLog

/// Every subsystem logs under one subsystem with a stable category, so a
/// diagnostics export is `log show --predicate 'subsystem == "com.tlotliso.masterful"'`
/// and nothing else.
public enum Log {
    public static let subsystem = "com.tlotliso.masterful"

    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    public static let input = Logger(subsystem: subsystem, category: "input")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let transcription = Logger(subsystem: subsystem, category: "transcription")
    public static let refinement = Logger(subsystem: subsystem, category: "refinement")
    public static let insertion = Logger(subsystem: subsystem, category: "insertion")
    public static let hud = Logger(subsystem: subsystem, category: "hud")
    public static let session = Logger(subsystem: subsystem, category: "session")

    /// Signposts back the latency budget in `docs/latency.md`. Instruments can
    /// read these directly, so the budget is measured rather than asserted.
    public static let signposter = OSSignposter(
        logger: Logger(subsystem: subsystem, category: "latency")
    )
}
