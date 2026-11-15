import LocalAuthentication
import SwiftUI

/// Face ID (or Touch ID, or the device passcode) for the whole app and for single notebooks.
/// Everything locks again when the app goes to the background.
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    /// The whole app asks for Face ID when it opens.
    var appLockOn: Bool {
        didSet { UserDefaults.standard.set(appLockOn, forKey: "appLock") }
    }
    /// The app is covered until the user unlocks it.
    private(set) var appLocked: Bool
    /// Locked notebooks opened since the app last went to the background.
    private(set) var unlocked: Set<UUID> = []
    /// True while the system asks for Face ID, so the cover does not flash meanwhile.
    private(set) var asking = false

    private init() {
        let on = UserDefaults.standard.bool(forKey: "appLock")
        appLockOn = on
        appLocked = on && !Demo.enabled
    }

    /// Whether the device can check who is there (it has a passcode, at least).
    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// "Face ID", "Touch ID", "Optic ID" or "il codice", for the buttons.
    static var methodName: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch c.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return String(localized: "il codice")
        }
    }

    static var methodIcon: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch c.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.fill"
        }
    }

    /// Asks for Face ID, Touch ID or the passcode. A device without a passcode cannot lock
    /// anything, so there it answers yes.
    func authenticate(_ reason: String) async -> Bool {
        let c = LAContext()
        var err: NSError?
        guard c.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            return (err as? LAError)?.code == .passcodeNotSet
        }
        asking = true
        defer { asking = false }
        return (try? await c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    func unlockApp() async {
        guard appLocked, !asking else { return }
        if await authenticate(String(localized: "Sblocca Quaderno Appunti")) { appLocked = false }
    }

    func isOpen(_ nb: Notebook) -> Bool { !nb.isLocked || unlocked.contains(nb.id) || Demo.enabled }

    func unlock(_ nb: Notebook) async -> Bool {
        if isOpen(nb) { return true }
        guard !asking else { return false }
        guard await authenticate(String(localized: "Apri «\(nb.title)»")) else { return false }
        unlocked.insert(nb.id)
        return true
    }

    /// The app went to the background: locked notebooks close and the app locks again.
    func lockAll() {
        guard !asking else { return }
        unlocked = []
        if appLockOn && !Demo.enabled { appLocked = true }
    }

    /// Turning the app lock on or off asks first, so nobody else can change it.
    func setAppLock(_ on: Bool) async -> String? {
        guard on != appLockOn else { return nil }
        guard Self.available else { return String(localized: "Per bloccare l'app imposta un codice sul dispositivo (Impostazioni → Face ID e codice).") }
        guard await authenticate(on ? String(localized: "Blocca Quaderno Appunti") : String(localized: "Togli il blocco di Quaderno Appunti")) else { return nil }
        appLockOn = on
        return nil
    }
}

/// Covers a window while the app is locked, or while it is in the app switcher with the lock on.
struct AppLockCover: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @State private var lock = AppLock.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if lock.appLocked || (lock.appLockOn && phase != .active && !lock.asking) {
                    LockScreen(title: String(localized: "Quaderno Appunti è bloccato"),
                               button: String(localized: "Sblocca con \(AppLock.methodName)")) {
                        Task { await lock.unlockApp() }
                    }
                    .transition(.opacity)
                }
            }
            .onChange(of: phase) { _, p in
                if p == .background { lock.lockAll() }
                if p == .active, lock.appLocked { Task { await lock.unlockApp() } }
            }
            .task { if lock.appLocked { await lock.unlockApp() } }
    }
}

extension View {
    func appLockCover() -> some View { modifier(AppLockCover()) }
}

/// The screen shown over something locked.
struct LockScreen: View {
    let title: String
    let button: String
    var onClose: (() -> Void)?
    let onUnlock: () -> Void

    init(title: String, button: String, onClose: (() -> Void)? = nil, onUnlock: @escaping () -> Void) {
        self.title = title
        self.button = button
        self.onClose = onClose
        self.onUnlock = onUnlock
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill").font(.system(size: 46, weight: .semibold)).foregroundStyle(Theme.accent)
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            Button(action: onUnlock) {
                Label(button, systemImage: AppLock.methodIcon).frame(minWidth: 220)
            }
            .buttonStyle(PrimaryButtonStyle())
            if let onClose {
                Button("Torna allo scaffale", action: onClose)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.sub)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
    }
}

/// A notebook locked with Face ID: it shows only after unlocking, and closes again when the app
/// goes to the background.
struct LockedNotebookGate<Content: View>: View {
    let notebook: Notebook
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var lock = AppLock.shared

    var body: some View {
        if lock.isOpen(notebook) {
            content()
        } else {
            LockScreen(title: String(localized: "«\(notebook.title)» è bloccato"),
                       button: String(localized: "Apri con \(AppLock.methodName)"),
                       onClose: onClose) {
                Task { _ = await lock.unlock(notebook) }
            }
            .task { _ = await lock.unlock(notebook) }
            .preferredColorScheme(.dark)
        }
    }
}
