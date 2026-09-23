public struct IdleNotificationAuthorization: Sendable {
    public enum State: Equatable, Sendable {
        case notAsked
        case requesting
        case authorized
        case denied
    }

    public enum Action: Equatable, Sendable {
        case requestAuthorization
        case deliver(IdleAlert)
        case drop(IdleAlert)
    }

    public private(set) var state: State = .notAsked
    public private(set) var pendingAlert: IdleAlert?

    public init() {}

    public mutating func prepare() -> [Action] {
        guard state == .notAsked else { return [] }
        state = .requesting
        return [.requestAuthorization]
    }

    public mutating func post(_ alert: IdleAlert) -> [Action] {
        switch state {
        case .notAsked:
            pendingAlert = alert
            state = .requesting
            return [.requestAuthorization]
        case .requesting:
            guard pendingAlert == nil else { return [.drop(alert)] }
            pendingAlert = alert
            return []
        case .authorized:
            return [.deliver(alert)]
        case .denied:
            return [.drop(alert)]
        }
    }

    public mutating func resolve(authorized: Bool) -> [Action] {
        guard state == .requesting else { return [] }
        state = authorized ? .authorized : .denied
        guard let alert = pendingAlert else { return [] }
        pendingAlert = nil
        return [authorized ? .deliver(alert) : .drop(alert)]
    }
}
