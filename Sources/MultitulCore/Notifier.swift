import Foundation
import UserNotifications

public struct NotificationActionSpec: Equatable, Sendable {
    public var id: String
    public var title: String
    public var destructive: Bool
    public init(id: String, title: String, destructive: Bool = false) {
        self.id = id
        self.title = title
        self.destructive = destructive
    }
}

public struct NotificationCategorySpec: Equatable, Sendable {
    public var id: String
    public var actions: [NotificationActionSpec]
    public init(id: String, actions: [NotificationActionSpec]) {
        self.id = id
        self.actions = actions
    }
}

public struct NotificationEvent: Equatable, Sendable {
    public static let defaultAction = "default"
    public var requestId: String
    public var actionId: String
    public var userInfo: [String: String]
    public init(requestId: String, actionId: String, userInfo: [String: String]) {
        self.requestId = requestId
        self.actionId = actionId
        self.userInfo = userInfo
    }
}

public final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = Notifier()
    private var armed = false
    private let lock = NSLock()
    private var categories: [String: NotificationCategorySpec] = [:]
    private var handlers: [String: @Sendable (NotificationEvent) -> Void] = [:]

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    public func arm() {
        guard !armed else { return }
        armed = true
        center.delegate = self
    }

    public func requestAuthorization() {
        arm()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.write("notifications authorization granted=\(granted) error=\(String(describing: error))")
        }
    }

    // Categories from all modules are merged: the system call replaces the whole set.
    public func register(categories specs: [NotificationCategorySpec]) {
        arm()
        lock.lock()
        for s in specs { categories[s.id] = s }
        let all = categories.values.map { spec -> UNNotificationCategory in
            let actions = spec.actions.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: $0.destructive ? [.destructive] : []) }
            return UNNotificationCategory(identifier: spec.id, actions: actions, intentIdentifiers: [], options: [])
        }
        lock.unlock()
        center.setNotificationCategories(Set(all))
    }

    // owner = request id prefix ("storozh-")
    public func setHandler(prefix: String, _ handler: (@Sendable (NotificationEvent) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        handlers[prefix] = handler
    }

    private func handler(for requestId: String) -> (@Sendable (NotificationEvent) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return handlers.first { requestId.hasPrefix($0.key) }?.value
    }

    public func post(title: String, body: String, id: String = UUID().uuidString, category: String? = nil, userInfo: [String: String] = [:]) {
        arm()
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if let category { c.categoryIdentifier = category }
        if !userInfo.isEmpty { c.userInfo = userInfo }
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { error in
            Log.write("notification posted id=\(id) error=\(String(describing: error))")
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let req = response.notification.request
        var info: [String: String] = [:]
        for (k, v) in req.content.userInfo { if let key = k as? String { info[key] = "\(v)" } }
        let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? NotificationEvent.defaultAction : response.actionIdentifier
        let event = NotificationEvent(requestId: req.identifier, actionId: action, userInfo: info)
        handler(for: event.requestId)?(event)
    }
}
