# AdSparkle iOS SDK

`AdSparkle` is the official iOS client SDK for the **AdSparkle** affiliate
attribution tracking platform. It lets your mobile app capture affiliate
attribution from deep links and report conversion events (install, sign up,
purchase, etc.) to the tracking backend.

- iOS 13+
- Swift 5.7+
- Swift Package Manager **and** CocoaPods
- Objective-C interoperable

> **Security note:** AdSparkle only uses your **publishable company key** (the
> `co_…` key). This key is **not a secret** and is safe to ship in your app
> binary. The SDK **never** uses or transmits any HMAC / secret key.

---

## Installation

### Swift Package Manager

In Xcode: **File → Add Packages…** and enter the repository URL:

```
https://github.com/Adsparkle/adsparkle-ios.git
```

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Adsparkle/adsparkle-ios.git", from: "0.1.3")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "AdSparkle", package: "adsparkle-ios")
        ]
    )
]
```

### CocoaPods

Add to your `Podfile`:

```ruby
pod 'AdSparkle', '~> 0.1.3'
```

Then run:

```sh
pod install
```

---

## Quick start

```swift
import AdSparkle

// 1. Configure once at launch.
AdSparkle.shared.configure(
    companyKey: "co_your_publishable_key",
    baseUrl: "https://api.adsparkle.co",   // optional, this is the default
    debug: true                          // optional, prints diagnostics
)

// 2. Identify the user.
AdSparkle.shared.setUserId("user-123")

// 3. Capture attribution from a deep link (see below).

// 4. Track events.
AdSparkle.shared.trackInstall()
AdSparkle.shared.trackPurchase(
    AdSparkleEvent(transactionId: "txn_987", amount: 9.99, currency: "USD")
)
```

---

## Capturing the `click_id` from deep links

Attribution is carried in a `click_id` query parameter:

```
yourapp://open?click_id=<uuid>
https://yourbrand.link/path?click_id=<uuid>
```

Pass every incoming URL to `handleDeepLink(_:)`. URLs without a `click_id` are
ignored safely.

### SwiftUI

```swift
import SwiftUI
import AdSparkle

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    AdSparkle.shared.handleDeepLink(url)
                }
        }
    }
}
```

### UIKit — SceneDelegate (custom URL scheme)

```swift
func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    if let url = URLContexts.first?.url {
        AdSparkle.shared.handleDeepLink(url)
    }
}

// Cold-start launch via URL:
func scene(_ scene: UIScene,
           willConnectTo session: UISceneSession,
           options connectionOptions: UIScene.ConnectionOptions) {
    if let url = connectionOptions.urlContexts.first?.url {
        AdSparkle.shared.handleDeepLink(url)
    }
}
```

### UIKit — SceneDelegate (Universal Links)

```swift
func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       let url = userActivity.webpageURL {
        AdSparkle.shared.handleDeepLink(url)
    }
}
```

### UIKit — AppDelegate (no scenes)

```swift
func application(_ app: UIApplication,
                 open url: URL,
                 options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    AdSparkle.shared.handleDeepLink(url)
    return true
}

func application(_ application: UIApplication,
                 continue userActivity: NSUserActivity,
                 restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    if let url = userActivity.webpageURL {
        AdSparkle.shared.handleDeepLink(url)
    }
    return true
}
```

You can also set the click id manually if you obtain it some other way:

```swift
AdSparkle.shared.setClickId("a1b2c3-...")
let current = AdSparkle.shared.clickId   // Optional<String>
```

The SDK keeps an attribution **chain** of up to the 10 most recent, unique click
ids and sends them as `click_ids` alongside the latest `click_id`.

---

## Tracking events

The generic entry point:

```swift
AdSparkle.shared.track("purchase", event: AdSparkleEvent(amount: 19.99, currency: "USD"))
```

Plus convenience methods for every supported type:

```swift
AdSparkle.shared.trackInstall()
AdSparkle.shared.trackSignUp()
AdSparkle.shared.trackLogin()
AdSparkle.shared.trackDownload()
AdSparkle.shared.trackPurchase(AdSparkleEvent(transactionId: "txn_1", amount: 4.99, currency: "USD"))
AdSparkle.shared.trackSubscription(AdSparkleEvent(amount: 9.99, currency: "USD"))
AdSparkle.shared.trackRefund(AdSparkleEvent(transactionId: "txn_1"))
```

`AdSparkleEvent` fields are all optional:

```swift
AdSparkleEvent(
    transactionId: "txn_1",
    amount: 9.99,
    currency: "USD",
    productIds: ["sku_a", "sku_b"],
    customParams: ["campaign": "summer"]
)
```

> If no `click_id` or no `user_id` is available when you call a `track` method,
> the event is **silently skipped** (a debug message is printed when `debug` is
> enabled). No error is thrown.

### Supported event types

| Event type     | Constant                          | Typical fields                          |
| -------------- | --------------------------------- | --------------------------------------- |
| `install`      | `AdSparkleEventType.install`      | —                                       |
| `sign_up`      | `AdSparkleEventType.signUp`       | —                                       |
| `login`        | `AdSparkleEventType.login`        | —                                       |
| `download`     | `AdSparkleEventType.download`     | —                                       |
| `purchase`     | `AdSparkleEventType.purchase`     | `transactionId`, `amount`, `currency`   |
| `subscription` | `AdSparkleEventType.subscription` | `transactionId`, `amount`, `currency`   |
| `refund`       | `AdSparkleEventType.refund`       | `transactionId`                         |

These 7 constants are a **convenience** — they are not the only accepted
values. You can also pass a company **custom-event `shortId`** (e.g. `"YE2YFSQ"`)
directly as the `event_type`:

```swift
AdSparkle.shared.track("YE2YFSQ", event: AdSparkleEvent(
    amount: 9.99,
    currency: "USD",
    productIds: ["sku_a"],
    customParams: ["campaign": "summer"]
))
```

Any `event_type` matching the format `^[A-Za-z0-9_]{1,64}$` is accepted; anything
else is ignored. `product_ids` and `custom_params` are supported for every event
type, built-in or custom.

---

## Delivery & reliability

- Events are sent asynchronously on a background queue — the main thread is
  never blocked.
- On `5xx` / network errors the SDK retries up to **3 times** with exponential
  backoff (1s, 2s, 4s).
- If all attempts fail, the event is persisted to a **pending queue** and
  retried on the next `track(...)` or `configure(...)` call.
- A `200` response means the event was accepted (processing is async on the
  backend).

State (company key, base URL, user id, click ids, pending queue) is persisted in
`UserDefaults` under the `co.adsparkle.sdk` suite, so attribution survives app
restarts.

---

## Objective-C interop

The public API is exposed to Objective-C:

```objc
@import AdSparkle;

[AdSparkle.shared configureWithCompanyKey:@"co_xxx"
                                  baseUrl:@"https://api.adsparkle.co"
                                    debug:YES];
[AdSparkle.shared setUserId:@"user-123"];
[AdSparkle.shared handleDeepLink:url];

AdSparkleEvent *event = [[AdSparkleEvent alloc] init];
event.amount = @9.99;
event.currency = @"USD";
[AdSparkle.shared trackPurchase:event];
```

---

## License

MIT.
