import Foundation
@testable import PetCore

func thread(_ name: String, _ state: ThreadState, reviewReady: Bool = false, pr: PullRequest? = nil,
            sessions: [ThreadSession]? = nil, actions: [ThreadAction] = []) -> BuildThread {
    BuildThread(id: name, name: name, state: state, reviewReady: reviewReady, pr: pr, sessions: sessions, actions: actions)
}

func session(_ harness: String, _ status: String, seen: Date) -> ThreadSession {
    var s = ThreadSession()
    s.harness = harness; s.status = status
    s.lastSeen = ISO8601DateFormatter().string(from: seen)
    return s
}

func fixtureData(_ file: String) throws -> Data {
    let url = Bundle.module.url(forResource: file.replacingOccurrences(of: ".json", with: ""),
                                withExtension: "json", subdirectory: "Fixtures")
    guard let url else { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing \(file)"]) }
    return try Data(contentsOf: url)
}

func row(_ name: String, _ state: NaviState, ago: Double, base: Double = 1_000_000) -> MenuRow {
    MenuRow(id: name, name: name, state: state, changedAt: base - ago * 60, status: "")
}
