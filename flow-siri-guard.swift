import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

private let flowID = "com.electron.wispr-flow"
private let siriID = "com.apple.campo"
private let alfredID = "com.runningwithcrayons.Alfred"
private let languageToolID = "org.languagetool.desktop"
private let mode = CommandLine.arguments.dropFirst().first ?? "--observe"
private let lockPath = NSTemporaryDirectory() + "flow-siri-guard-\(getuid()).lock"
private let healthPath = NSTemporaryDirectory() + "flow-siri-guard-\(getuid()).health.json"

private func log(_ message: String) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    print("\(formatter.string(from: Date())) \(message)")
    fflush(stdout)
}

private struct WindowState {
    var hub = false
    var status = false
}

private func windows(_ pid: pid_t) -> WindowState {
    var result = WindowState()
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    for row in info where (row[kCGWindowOwnerPID as String] as? Int) == Int(pid) {
        let title = row[kCGWindowName as String] as? String ?? ""
        if title == "Wispr Flow", (row[kCGWindowLayer as String] as? Int) == 0 { result.hub = true }
        if title == "Status" { result.status = true }
    }
    return result
}

private func siriHasWindow(_ pid: pid_t) -> Bool {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.contains { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) }
}

private final class PreinputGuard {
    var tap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var flow: NSRunningApplication?
    var extra: [NSRunningApplication] = []
    var leasePID: pid_t?
    var deadline: TimeInterval = 0
    var latestTrigger: TimeInterval = 0
    var restoreTimer: Timer?
    var signals: [DispatchSourceSignal] = []
    var lockFD: Int32 = -1
    var stopping = false
    var pendingRestore: String?
    var restoreAttempts = 0
    var nextRestore: TimeInterval = 0
    var callbackCount: UInt64 = 0
    var callbackTotalNS: UInt64 = 0
    var callbackMaximumNS: UInt64 = 0
    var healthTimer: Timer?
    let healthQueue = DispatchQueue(label: "flow-siri-guard.health")
    let system = AXUIElementCreateSystemWide()

    func start() {
        guard ["--run", "--observe", "--status"].contains(mode) else {
            fputs("Usage: SiriFlowGuard [--observe|--run|--status]\n", stderr); exit(64)
        }
        let ax = AXIsProcessTrusted(), screen = CGPreflightScreenCaptureAccess(), input = CGPreflightListenEventAccess()
        if mode == "--status" {
            log("accessibility=\(ax) screen-recording=\(screen) input-monitoring=\(input)")
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: flowID).first {
                let state = windows(app.processIdentifier)
                log("flow-pid=\(app.processIdentifier) hidden=\(app.isHidden) Hub=\(state.hub) Status=\(state.status)")
            }
            if let text = try? String(contentsOfFile: lockPath, encoding: .utf8),
               let owner = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                var count: UInt32 = 0
                if CGGetEventTapList(0, nil, &count) == .success, count > 0 {
                    var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
                    if CGGetEventTapList(count, &taps, &count) == .success {
                        for item in taps.prefix(Int(count)) where item.tappingProcess == owner {
                            log("guard-pid=\(owner) tap-enabled=\(item.enabled) average-latency-us=\(Int(item.avgUsecLatency)) maximum-latency-us=\(Int(item.maxUsecLatency))")
                        }
                    }
                }
                if let data = try? Data(contentsOf: URL(fileURLWithPath: healthPath)),
                   let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   (state["pid"] as? Int) == Int(owner),
                   let updated = state["updated"] as? Double, Date().timeIntervalSince1970 - updated < 3 {
                    log("measured-callback-count=\(state["count"] ?? 0) average-ms=\(state["averageMs"] ?? 0) maximum-ms=\(state["maximumMs"] ?? 0) restore-pending=\(state["restorePending"] ?? false)")
                }
            }
            return
        }
        guard ax, screen, input else {
            log("ERROR: accessibility=\(ax) screen-recording=\(screen) input-monitoring=\(input); grant access to this helper")
            exit(77)
        }
        lockFD = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            log("ERROR: another guard is already running, or the lock is unavailable"); exit(73)
        }
        _ = ftruncate(lockFD, 0)
        let pidBytes = Array("\(getpid())\n".utf8)
        _ = pidBytes.withUnsafeBytes { write(lockFD, $0.baseAddress, $0.count) }
        AXUIElementSetMessagingTimeout(system, 0.025)
        let mask = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown,
                    .leftMouseUp, .rightMouseUp, .otherMouseUp, .keyDown, .keyUp, .flagsChanged]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let guardObject = Unmanaged<PreinputGuard>.fromOpaque(context).takeUnretainedValue()
                let began = DispatchTime.now().uptimeNanoseconds
                guardObject.handle(type: type, event: event)
                let elapsed = DispatchTime.now().uptimeNanoseconds - began
                guardObject.callbackCount += 1
                guardObject.callbackTotalNS += elapsed
                guardObject.callbackMaximumNS = max(guardObject.callbackMaximumNS, elapsed)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { log("ERROR: macOS refused active event tap; no visibility changed"); exit(77) }
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        restoreTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            guard let self, self.leasePID != nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.pendingRestore != nil {
                if now >= self.nextRestore { self.restore(reason: "retry") }
            } else if now >= self.deadline { self.restore(reason: "timer") }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let state: [String: Any] = ["pid": Int(getpid()), "updated": Date().timeIntervalSince1970,
                "count": self.callbackCount,
                "averageMs": self.callbackCount == 0 ? 0 : Double(self.callbackTotalNS) / Double(self.callbackCount) / 1_000_000,
                "maximumMs": Double(self.callbackMaximumNS) / 1_000_000,
                "restorePending": self.pendingRestore != nil]
            self.healthQueue.async {
                if let data = try? JSONSerialization.data(withJSONObject: state) {
                    try? data.write(to: URL(fileURLWithPath: healthPath), options: [.atomic])
                }
            }
        }
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume(); signals.append(source)
        }
        log("started mode=\(mode) pid=\(getpid()); no key contents or coordinates logged")
        RunLoop.main.run()
    }

    func handle(type: CGEventType, event: CGEvent) {
        let callbackBegan = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsed = ProcessInfo.processInfo.systemUptime - callbackBegan
            if elapsed > 0.1 { log("input callback elapsed-ms=\(Int(elapsed * 1000)) tap-enabled=\(tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false)") }
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            restore(reason: "tap-disabled")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log("event tap re-enabled; previous lease restored")
            return
        }
        guard !stopping else { return }
        if [.leftMouseUp, .rightMouseUp, .otherMouseUp, .keyUp].contains(type) { return }
        let siri = NSRunningApplication.runningApplications(withBundleIdentifier: siriID).first
        var trigger: String?
        var unknownMouse = false
        var inputClass = "other-input"
        if type == .leftMouseDown, let siri {
            let target = mouseTarget(event.location, siriPID: siri.processIdentifier)
            inputClass = "mouse-" + target
            if target.hasPrefix("siri-") { trigger = "siri-click" }
            else { unknownMouse = target == "unknown" }
            if leasePID != nil || target.hasPrefix("siri-") { log("mouse target=\(target)") }
        } else if type == .keyDown {
            inputClass = "key"
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == 36 || code == 76 {
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if front == siriID { trigger = "siri-return" }
                else if let alfred = NSRunningApplication.runningApplications(withBundleIdentifier: alfredID).first, siriHasWindow(alfred.processIdentifier) { trigger = "alfred-return" }
                else if let siri, siriHasWindow(siri.processIdentifier) { trigger = "siri-bubble-return" }
                else { log("return ignored: front=\(front == flowID ? "flow" : "other")") }
            }
        } else if type == .flagsChanged { inputClass = "modifier" }
        if let trigger { prepare(trigger: trigger) }
        else if leasePID != nil && !unknownMouse {
            restore(reason: "before-" + inputClass)
        }
    }

    func mouseTarget(_ point: CGPoint, siriPID: pid_t) -> String {
        var element: AXUIElement?
        var axPID: pid_t = 0
        let axResult = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
        if axResult == .success, let element { _ = AXUIElementGetPid(element, &axPID) }
        if axPID == siriPID { return "siri-accessibility" }
        let flowPID = NSRunningApplication.runningApplications(withBundleIdentifier: flowID).first?.processIdentifier
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        if let dockPID, axPID == dockPID { return "dock" }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for row in info {
            guard let pid = row[kCGWindowOwnerPID as String] as? Int,
                  let bounds = row[kCGWindowBounds as String] as? [String: Double],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"],
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  CGRect(x: x, y: y, width: w, height: h).contains(point) else { continue }
            if pid == Int(flowPID ?? -1),
               (row[kCGWindowName as String] as? String) == "Status" { continue }
            if pid == Int(siriPID) { return "siri-window-geometry" }
            if pid == Int(dockPID ?? -1) { return "dock" }
            if pid == Int(flowPID ?? -1) { return "flow-window" }
            if pid > 0 { return "other-window" }
        }
        return "unknown"
    }

    func prepare(trigger: String) {
        if pendingRestore != nil {
            restore(reason: "retry-before-input")
            if pendingRestore != nil { return }
        }
        if leasePID != nil {
            latestTrigger = ProcessInfo.processInfo.systemUptime
            deadline = ProcessInfo.processInfo.systemUptime + (trigger == "alfred-return" ? 1.5 : 0.5)
            log("lease renewed by \(trigger)")
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: flowID).first,
              !app.isHidden else { return }
        let before = windows(app.processIdentifier)
        guard !before.hub, before.status else {
            log("\(trigger) skipped: Hub=\(before.hub) Status=\(before.status)")
            return
        }
        if mode == "--observe" { log("WOULD-HIDE for \(trigger); Hub closed and Status visible"); return }
        flow = app; leasePID = app.processIdentifier
        restoreAttempts = 0
        latestTrigger = ProcessInfo.processInfo.systemUptime
        deadline = ProcessInfo.processInfo.systemUptime + (trigger == "alfred-return" ? 1.5 : 0.5)
        let began = ProcessInfo.processInfo.systemUptime
        _ = app.hide()
        extra = NSRunningApplication.runningApplications(withBundleIdentifier: languageToolID).filter { !$0.isHidden }
        for other in extra { _ = other.hide() }
        while ProcessInfo.processInfo.systemUptime - began < 0.06 {
            if !windows(app.processIdentifier).status {
                latestTrigger = ProcessInfo.processInfo.systemUptime
                log("\(trigger) pre-hidden elapsed-ms=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000))")
                return
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        log("\(trigger) hide not confirmed within 60ms; restoring and passing input")
        restore(reason: "hide-timeout")
    }

    func restore(reason: String) {
        guard let pid = leasePID else { return }
        if reason.hasPrefix("before-") {
            let remaining = 0.15 - (ProcessInfo.processInfo.systemUptime - latestTrigger)
            if remaining > 0 {
                log("minimum-hide remaining-ms=\(Int(remaining * 1000))")
                Thread.sleep(forTimeInterval: min(remaining, 0.15))
            }
        }
        for other in extra where !other.isTerminated { _ = other.unhide() }
        guard let app = flow, !app.isTerminated, app.processIdentifier == pid else {
            flow = nil; leasePID = nil; pendingRestore = nil; return
        }
        if pendingRestore == nil { pendingRestore = reason }
        restoreAttempts += 1
        _ = app.unhide()
        let began = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - began < 0.06 {
            if windows(pid).status { break }
            Thread.sleep(forTimeInterval: 0.002)
        }
        let after = windows(pid)
        if after.status || !app.isHidden {
            log("restored reason=\(pendingRestore ?? reason) attempts=\(restoreAttempts) Hub=\(after.hub) Status=\(after.status)")
            flow = nil; leasePID = nil; pendingRestore = nil
        } else {
            log("restore pending attempt=\(restoreAttempts); no new hides until restored")
            nextRestore = ProcessInfo.processInfo.systemUptime + (restoreAttempts < 5 ? 0.1 : 1.0)
            if restoreAttempts == 5 { log("WARNING: macOS delayed unhide; continuing one bounded retry per second") }
        }
    }

    func stop() {
        stopping = true
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        restore(reason: "stop")
        for _ in 0..<5 where leasePID != nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            restore(reason: "stop-retry")
        }
        restoreTimer?.invalidate()
        healthTimer?.invalidate()
        if lockFD >= 0 { close(lockFD) }
        if leasePID != nil {
            log("ERROR: stopped but unhide could not be confirmed; open Flow from Dock to restore it")
            exit(1)
        }
        log("stopped; any owned temporary hide restored"); exit(0)
    }
}

PreinputGuard().start()
