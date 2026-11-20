import ApplicationServices

/// Providers that don't publish AX destruction are covered by inventory polling.
final class WindowCloseObserver {
    private final class Owner {
        let observer: AXObserver
        var windows: [CGWindowID: AXUIElement] = [:]

        init?(pid: pid_t) {
            var result: AXObserver?
            guard AXObserverCreate(pid, { _, element, _, context in
                guard let context else { return }
                let watcher = Unmanaged<WindowCloseObserver>.fromOpaque(context).takeUnretainedValue()
                watcher.destroyed(element)
            }, &result) == .success, let result else { return nil }
            observer = result
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }

        deinit {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    private var owners: [pid_t: Owner] = [:]
    private let onClose: (CGWindowID) -> Void

    init(onClose: @escaping (CGWindowID) -> Void) { self.onClose = onClose }

    func watch(_ windows: [ManagedWindow]) {
        let byOwner = Dictionary(grouping: windows, by: \.pid)
        owners = owners.filter { byOwner[$0.key] != nil }
        for (pid, group) in byOwner {
            guard let owner = owners[pid] ?? Owner(pid: pid) else { continue }
            owners[pid] = owner
            let current = Set(group.map(\.id))
            for (id, element) in owner.windows where !current.contains(id) {
                AXObserverRemoveNotification(owner.observer, element, kAXUIElementDestroyedNotification as CFString)
                owner.windows[id] = nil
            }
            for window in group where owner.windows[window.id] == nil {
                let error = AXObserverAddNotification(owner.observer, window.element,
                    kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
                if error == .success || error == .notificationUnsupported {
                    owner.windows[window.id] = window.element
                }
            }
        }
    }

    private func destroyed(_ element: AXUIElement) {
        for owner in owners.values {
            if let (id, _) = owner.windows.first(where: { CFEqual($0.value, element) }) {
                onClose(id)
                return
            }
        }
    }
}
