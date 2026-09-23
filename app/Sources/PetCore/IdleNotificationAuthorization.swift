public struct IdleNotificationAuthorization: Sendable {
    public enum State: Equatable, Sendable {
        case notAsked
        case checking
        case requesting
        case authorized
        case denied
    }

    public enum Action: Equatable, Sendable {
        case checkSettings
        case requestAuthorization
        case deliver(IdleAlert)
        case drop(IdleAlert)
    }

    public enum Settings: Equatable, Sendable {
        case notDetermined
        case authorized
        case denied
    }

    public private(set) var state: State = .notAsked
    public private(set) var pendingAlert: IdleAlert?

    public init() {}

    public mutating func prepare() -> [Action] {
        guard state == .notAsked || state == .denied else { return [] }
        state = .checking
        return [.checkSettings]
    }

    public mutating func post(_ alert: IdleAlert) -> [Action] {
        switch state {
        case .notAsked, .denied:
            pendingAlert = alert
            state = .checking
            return [.checkSettings]
        case .checking, .requesting:
            guard pendingAlert == nil else { return [.drop(alert)] }
            pendingAlert = alert
            return []
        case .authorized:
            return [.deliver(alert)]
        }
    }

    public mutating func resolveSettings(_ settings: Settings) -> [Action] {
        guard state == .checking else { return [] }
        switch settings {
        case .notDetermined:
            state = .requesting
            return [.requestAuthorization]
        case .authorized:
            state = .authorized
        case .denied:
            state = .denied
        }
        guard let alert = pendingAlert else { return [] }
        pendingAlert = nil
        return [settings == .authorized ? .deliver(alert) : .drop(alert)]
    }

    public mutating func resolve(authorized: Bool) -> [Action] {
        guard state == .requesting else { return [] }
        state = authorized ? .authorized : .denied
        guard let alert = pendingAlert else { return [] }
        pendingAlert = nil
        return [authorized ? .deliver(alert) : .drop(alert)]
    }
}
