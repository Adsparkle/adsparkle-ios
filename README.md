# AdSparkle iOS SDK

Client-side conversion-tracking SDK for the [AdSparkle](https://adsparkle.co) affiliate platform. Zero third-party dependencies — pure Foundation + Network framework.

- Captures `click_id` from deep links / Universal Links
- Sends conversion events to the AdSparkle postback endpoint
- Persists a click chain (max 50, 7-day TTL attribution window) across launches
- Offline retry queue with automatic flush on network regain (NWPathMonitor)
- Anonymous user ID generation and persistence
- iOS 13+ / macOS 11+ / tvOS 13+, Swift 5.9, Swift Package Manager + CocoaPods

---

## Installation

### Swift Package Manager (recommended)

**Xcode UI:** File > Add Package Dependencies, enter:

```
https://github.com/Adsparkle/adsparkle-ios.git
```

Choose version `0.1.0` (or **Up to Next Major** from `0.1.0`).

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/Adsparkle/adsparkle-ios.git", from: "0.1.0")
],
targets: [
    .target(name: "YourApp", dependencies: ["AdSparkle"])
]
```

### CocoaPods

```ruby
pod 'AdSparkle', '~> 0.1.0'
```

Then run `pod install`.

---

## Quick Start

### 1. Initialise (UIKit AppDelegate)

```swift
// AppDelegate.swift
import AdSparkle

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Optional: enable verbose debug output during development
        AdSparkle.debugLogging = true

        AdSparkle.initialize(companyKey: "YOUR_COMPANY_KEY")
        // or with a custom endpoint:
        // AdSparkle.initialize(companyKey: "YOUR_COMPANY_KEY", endpointBase: "https://api.yourhost.com")

        return true
    }
}
```

### 1b. Initialise (SwiftUI App)

```swift
import SwiftUI
import AdSparkle

@main
struct MyApp: App {
    init() {
        AdSparkle.initialize(companyKey: "YOUR_COMPANY_KEY")
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

---

### 2. Capture Clicks

#### UIKit — AppDelegate deep-link handler

```swift
func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
) -> Bool {
    AdSparkle.trackClick(url: url)
    return true
}
```

#### SceneDelegate — Universal Links / deep links

```swift
func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    URLContexts.forEach { AdSparkle.trackClick(url: $0.url) }
}

func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if let url = userActivity.webpageURL {
        AdSparkle.trackClick(url: url)
    }
}
```

#### SwiftUI — `.onOpenURL` modifier

```swift
ContentView()
    .onOpenURL { url in
        AdSparkle.trackClick(url: url)
    }
```

The SDK reads the `click_id` query parameter, validates it as a UUID v4, and adds it to the local attribution chain.

---

### 3. Track Conversions

All calls are asynchronous and off the main thread. The optional `completion` block is also delivered on a background thread — dispatch to main if you need to update the UI.

#### Purchase

```swift
AdSparkle.trackConversion(
    type: .purchase,              // AdSparkleConversionType
    transactionId: "txn_98765",
    amount: 49.99,
    currency: "USD",
    productIds: ["sku_001", "sku_002"],
    completion: { result in
        switch result {
        case .success(let queued):
            print(queued ? "Queued for retry" : "Sent successfully")
        case .noClickId:
            print("Organic visit — no click_id")
        case .networkError(let err):
            print("Network error: \(err)")
        case .serverError(let code):
            print("Server error: \(code)")
        case .unknownEventType(let raw):
            print("Unknown type: \(raw)")
        case .notInitialised:
            print("SDK not initialised")
        }
    }
)
```

#### Sign-up

```swift
AdSparkle.setUserId("user_42")          // call after successful sign-in/registration
AdSparkle.trackConversion(type: .signUp)
```

#### Login

```swift
AdSparkle.setUserId("user_42")
AdSparkle.trackConversion(type: .login)
```

#### Subscription

```swift
AdSparkle.trackConversion(
    type: .subscription,
    transactionId: "sub_annual_001",
    amount: 99.00,
    currency: "EUR"
)
```

#### Refund / Chargeback

```swift
AdSparkle.trackConversion(
    type: .refund,
    transactionId: "txn_98765",
    amount: 49.99,
    currency: "USD"
)
```

#### Using raw strings (and aliases)

```swift
// These aliases are resolved to the canonical type automatically:
AdSparkle.trackConversion(type: "order")      // → purchase
AdSparkle.trackConversion(type: "signup")     // → sign_up
AdSparkle.trackConversion(type: "subscribe")  // → subscription
AdSparkle.trackConversion(type: "chargeback") // → refund
```

#### Custom metadata

```swift
AdSparkle.trackConversion(
    type: .purchase,
    transactionId: "txn_99",
    amount: 19.99,
    currency: "GBP",
    customParams: ["plan": "pro", "source": "onboarding"]
)
```

---

### 4. Offline Retry

The SDK automatically retries failed events when connectivity is restored. You can also trigger a manual flush:

```swift
AdSparkle.flushQueue()
```

---

## Supported Event Types

| Enum case | Raw value | Accepted aliases |
|---|---|---|
| `.install` | `install` | — |
| `.signUp` | `sign_up` | `signup`, `register`, `registration` |
| `.login` | `login` | — |
| `.download` | `download` | — |
| `.purchase` | `purchase` | `order`, `sale` |
| `.subscription` | `subscription` | `subscribe` |
| `.refund` | `refund` | `chargeback` |

---

## Debug Logging

```swift
AdSparkle.debugLogging = true   // set BEFORE initialize()
```

Logs are emitted via `os.log` (visible in Console.app and Xcode console). Errors are always logged regardless of this flag.

---

## Release Checklist

### Swift Package Manager

Tag the commit that should be released:

```bash
git tag 0.1.0
git push origin 0.1.0
```

Consumers pinned to `from: "0.1.0"` or `"~> 0.1.0"` will pick up the release.

### CocoaPods

Ensure your `AdSparkle.podspec` version matches the git tag, then push to the trunk:

```bash
pod trunk push AdSparkle.podspec --allow-warnings
```

If you haven't registered yet:

```bash
pod trunk register adem@viralif.co 'ViralifAdem'
```

---

## Requirements

| | Minimum |
|---|---|
| iOS | 13.0 |
| macOS | 11.0 |
| tvOS | 13.0 |
| Swift | 5.9 |
| Xcode | 15.0 |

---

## License

MIT — see [LICENSE](LICENSE).
