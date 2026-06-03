import Foundation

public enum PressureTier: Equatable { case calm, busy, stressed }

public enum WorkPressure {
    public static func pendingCount(_ prs: [PR]) -> Int {
        prs.filter {
            $0.isMine && $0.state == "OPEN" && !$0.isDraft
                && ($0.reviewDecision == "CHANGES_REQUESTED" || $0.unresolvedCount > 0)
        }.count
    }

    public static func tier(_ prs: [PR], config: ConfigYAML) -> PressureTier {
        let n = pendingCount(prs)
        if n >= config.work.pressureStressedThreshold { return .stressed }
        if n >= config.work.pressureBusyThreshold { return .busy }
        return .calm
    }
}
