import Foundation

/// Immutable view of one evaluation, published to the debug window.
///
/// Everything is pre-rendered for the same reason `DebugEvent` is: the value
/// crosses a queue boundary and the view should do no formatting work. It is
/// deliberately a separate publication from `BufferSnapshot` — evaluations
/// happen about once a second, keystrokes far more often.
public struct DecisionSnapshot: Equatable, Hashable, Sendable {
    /// `autoApply`, `suggest`, `ignore`, or `skipped` when the policy stopped
    /// the evaluation before the detector ran.
    public var verdict: String
    public var reason: String
    public var regionText: String
    public var currentScore: Double
    public var alternateScore: Double
    public var guards: String
    public var policy: String
    public var bundleID: String?
    /// Populated only for a fix (suggested or applied).
    public var deleteCount: Int?
    public var insertText: String?
    /// Outcome of the apply, filled in after the fix engine returns.
    public var result: String?
    /// Wall time the evaluation itself took, in milliseconds.
    public var durationMillis: Double
    public var evaluatedAt: TimeInterval

    public init(
        verdict: String,
        reason: String = "",
        regionText: String = "",
        currentScore: Double = 0,
        alternateScore: Double = 0,
        guards: String = "none",
        policy: String,
        bundleID: String? = nil,
        deleteCount: Int? = nil,
        insertText: String? = nil,
        result: String? = nil,
        durationMillis: Double = 0,
        evaluatedAt: TimeInterval = 0
    ) {
        self.verdict = verdict
        self.reason = reason
        self.regionText = regionText
        self.currentScore = currentScore
        self.alternateScore = alternateScore
        self.guards = guards
        self.policy = policy
        self.bundleID = bundleID
        self.deleteCount = deleteCount
        self.insertText = insertText
        self.result = result
        self.durationMillis = durationMillis
        self.evaluatedAt = evaluatedAt
    }

    public init(
        detection: Detector.Detection,
        policy: AppPolicy,
        bundleID: String?,
        duration: TimeInterval,
        evaluatedAt: TimeInterval
    ) {
        let fix = detection.decision.fix
        self.init(
            verdict: Self.name(of: detection.decision),
            reason: Self.reason(of: detection.decision),
            regionText: detection.region?.typedText ?? "",
            currentScore: detection.analysis?.current.combined ?? 0,
            alternateScore: detection.analysis?.alternate.combined ?? 0,
            guards: detection.analysis?.guards.summary ?? "none",
            policy: policy.rawValue,
            bundleID: bundleID,
            deleteCount: fix?.deleteCount,
            insertText: fix?.insertText,
            result: nil,
            durationMillis: duration * 1000,
            evaluatedAt: evaluatedAt)
    }

    /// The evaluation that never ran because the frontmost app is not allowed.
    public static func skipped(
        reason: String, policy: AppPolicy, bundleID: String?, evaluatedAt: TimeInterval
    ) -> DecisionSnapshot {
        DecisionSnapshot(
            verdict: "skipped", reason: reason, policy: policy.rawValue, bundleID: bundleID,
            evaluatedAt: evaluatedAt)
    }

    public static func name(of decision: Decision) -> String {
        switch decision {
        case .ignore: return "ignore"
        case .suggest: return "suggest"
        case .autoApply: return "autoApply"
        }
    }

    public static func reason(of decision: Decision) -> String {
        if case .ignore(let reason) = decision { return reason }
        return ""
    }
}
