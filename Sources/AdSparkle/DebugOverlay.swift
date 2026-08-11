import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Debug ekran tanilari — SDK'nin kritik adimlarini CIHAZ EKRANINDA gosterir.
///
/// Neden: entegrasyonu yapan gelistirici gercek cihazda Xcode'a bagli DEGILSE
/// `print` ciktilarini goremez ("link app'i aciyor ama event gelmiyor" — nerede
/// koptugu belirsiz). Bu katman ayni tani mesajlarini ekranda toast olarak gosterir.
///
/// - YALNIZCA `configure(debug: true)` iken calisir. Kontrol EN DISTA
///   (`AdSparkle.screen(_:)`) yapilir; `debug=false` iken bu dosyadaki hicbir kod
///   calismaz, hicbir pencere/gorunum yaratilmaz (uretimde sifir etki).
/// - UIKit yoksa (macOS/test derlemesi) tum uygulama no-op'a duser.
/// - Tum durum SADECE main thread'de okunur/yazilir; `show(_:)` gerekirse main'e sicrar.
enum DebugOverlay {

#if canImport(UIKit)

    /// Ayni anda ekranda duran en fazla mesaj sayisi (en eski dusurulur).
    private static let maxVisible = 5
    /// Pencere HENUZ yokken (app tam acilmadi) kuyrukta bekletilecek en fazla mesaj.
    private static let maxQueued = 20
    /// Bir mesajin ekranda kalma suresi (saniye).
    private static let displaySeconds: TimeInterval = 6
    /// Pencere bulunamadiginda 0.5 sn araliklarla kac kez tekrar denenecegi (~20 sn).
    private static let maxWindowRetries = 40

    // MARK: - Durum (yalnizca main thread)

    private static var window: UIWindow?
    private static var stack: UIStackView?
    /// Pencere yokken biriken mesajlar; ilk pencere gelince sirayla gosterilir.
    private static var queued: [String] = []
    private static var retryScheduled = false
    private static var retryCount = 0

    // MARK: - Giris noktasi

    /// Mesaji ekranda gosterir. Arka plan kuyruklarindan (stateQueue, URLSession
    /// completion) cagrilabilir — UIKit dokunuslari HER ZAMAN main thread'de yapilir.
    static func show(_ message: String) {
        if Thread.isMainThread {
            present(message)
        } else {
            DispatchQueue.main.async { present(message) }
        }
    }

    // MARK: - Ic isleyis (main thread)

    private static func present(_ message: String) {
        queued.append(message)
        // Kuyruk capi: en eskiler dusurulur.
        if queued.count > maxQueued { queued.removeFirst(queued.count - maxQueued) }
        drain()
    }

    /// Kuyruktaki mesajlari pencereye bosaltir; pencere yoksa tekrar deneme planlar.
    private static func drain() {
        guard let stack = ensureStack() else {
            scheduleRetry()
            return
        }
        let messages = queued
        queued.removeAll()
        for message in messages { addToast(message, to: stack) }
    }

    /// Pencere henuz yaratilamadi (uygulama sahnesi acilmamis) → kisa sure sonra
    /// tekrar dene. Cap'li: app hic on plana gelmezse sonsuz timer donmesin.
    private static func scheduleRetry() {
        guard !retryScheduled, retryCount < maxWindowRetries else { return }
        retryScheduled = true
        retryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            retryScheduled = false
            guard !queued.isEmpty else { return }
            drain()
        }
    }

    /// Overlay penceresini (ve mesaj yiginini) gerekirse yaratir; sahne yoksa `nil`.
    private static func ensureStack() -> UIStackView? {
        // Sahnesi kopmus eski pencere gecersizdir → bastan kur.
        if let existing = stack, let existingWindow = window, existingWindow.windowScene != nil {
            return existing
        }
        window = nil
        stack = nil

        guard let scene = activeWindowScene() else { return nil }

        let overlayWindow = UIWindow(windowScene: scene)
        // Her seyin ustunde dursun; dokunuslari GECIRSIN (uygulama etkilesimi bozulmaz).
        overlayWindow.windowLevel = .alert + 1
        overlayWindow.backgroundColor = .clear
        overlayWindow.isUserInteractionEnabled = false
        // makeKeyAndVisible KULLANILMAZ — key window'u calmak klavye/odagi bozar.
        overlayWindow.isHidden = false

        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.view.isUserInteractionEnabled = false
        overlayWindow.rootViewController = root

        let messageStack = UIStackView()
        messageStack.axis = .vertical
        messageStack.spacing = 6
        messageStack.alignment = .fill
        messageStack.isUserInteractionEnabled = false
        messageStack.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(messageStack)

        // Kenarlardan guvenli alan payi — centik/home cubugu ustune binmez.
        let guide = root.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            messageStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            messageStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            messageStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12)
        ])

        window = overlayWindow
        stack = messageStack
        retryCount = 0
        return messageStack
    }

    /// Mesajlarin gosterilecegi aktif sahne (on planda olan tercih edilir).
    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }

    /// Yeni mesaji EN ALTA ekler, capi asan en eskiyi dusurur, ~6 sn sonra soldurup siler.
    private static func addToast(_ text: String, to stack: UIStackView) {
        window?.isHidden = false

        let toast = makeToast(text)
        stack.addArrangedSubview(toast) // dikey stack alta hizali → yenisi ALTTA

        while stack.arrangedSubviews.count > maxVisible, let oldest = stack.arrangedSubviews.first {
            remove(oldest)
        }

        toast.alpha = 0
        UIView.animate(withDuration: 0.2) { toast.alpha = 1 }

        DispatchQueue.main.asyncAfter(deadline: .now() + displaySeconds) { [weak toast] in
            guard let toast = toast else { return }
            UIView.animate(withDuration: 0.25, animations: { toast.alpha = 0 }) { _ in
                remove(toast)
            }
        }
    }

    private static func remove(_ view: UIView) {
        view.removeFromSuperview() // stack'ten de duser
        // Hicbir mesaj kalmadiysa pencereyi gizle (ekranda iz birakmasin).
        if stack?.arrangedSubviews.isEmpty == true { window?.isHidden = true }
    }

    /// Koyu yari-seffaf zeminli, beyaz mono, cok satirli mesaj kutusu.
    private static func makeToast(_ text: String) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        container.layer.cornerRadius = 8
        container.clipsToBounds = true
        container.isUserInteractionEnabled = false

        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textColor = .white
        label.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10)
        ])
        return container
    }

#else

    /// UIKit yok (macOS / test derlemesi) → tum yuzey no-op.
    static func show(_ message: String) {}

#endif
}
