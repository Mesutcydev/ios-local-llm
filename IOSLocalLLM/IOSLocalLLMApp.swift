import CoreSpotlight
import MLXVLM
import SwiftUI

@main
struct IOSLocalLLMApp: App {
    @ObservedObject private var settings = AppSettings.shared
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingSplash = true

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if VoiceUITestLaunch.isActive {
                VoiceUITestFixtureView()
                    .koduTheme(KoduTheme.make(
                        appearance: settings.appearance,
                        accent: KoduTheme.appAccent))
            } else {
                appRoot
            }
            #else
            appRoot
            #endif
        }
        .onChange(of: scenePhase) { _, newPhase in
            LifecycleController.shared.handle(phase: newPhase)
        }
    }

    @ViewBuilder
    private var appRoot: some View {
        ZStack {
            // Shared content layer for screens and sheets that intentionally
            // leave their background transparent. Clear Liquid Glass needs
            // real pixels beneath it; this restrained canvas supplies them
            // without turning the UI into a decorative gradient demo.
            LiquidPinkBackdrop()
            ContentView()
            ToastOverlayView()
            // Mounted above toasts so the burst draws over them, but
            // pointer-transparent (allowsHitTesting=false inside the
            // overlay) so it can't intercept taps. Listens for
            // download-complete notifications below — single firing
            // point keeps the celebration consistent across MLX,
            // llama.cpp, and HF Search download paths.
            ConfettiOverlayView()
            if isShowingSplash {
                PlumDuskSplashView {
                    withAnimation(.easeOut(duration: 0.28)) {
                        isShowingSplash = false
                    }
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .onOpenURL { url in
            AppBridge.shared.handleIncomingURL(url)
        }
        // Tap on a Spotlight search result → deep-link into that chat.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let idString = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let id = UUID(uuidString: idString) else { return }
            AppBridge.shared.openConversation(id: id)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .hfModelDownloadCompleted
        )) { _ in
            ConfettiCenter.shared.burst()
        }
        .task {
            if settings.localAPIEnabled {
                await LocalAPIManager.shared.start()
            }
            // Subscribe to MetricKit (crash + perf reports stay on-device).
            MetricKitHandler.shared.subscribe()
            // NOTE: do NOT set MLX.GPU.cacheLimit here. An earlier
            // version of this code capped it at 256 MiB hoping to
            // bound OOM-driven Metal command-buffer SIGABRTs. The
            // opposite happened: a 2.3 GB Qwen3-4B with only 256 MiB
            // of transient cache forces constant buffer eviction and
            // reallocation, and the resulting churn was itself a
            // reliable path to `mlx::core::gpu::check_error` throwing.
            // MLX's default unbounded cache is what the upstream
            // example apps ship with — leave it alone.
            // Set the UIHostingController's backing view to black so no
            // white system background bleeds through during the 1-2 UIKit
            // compositing frames that elapse on camera ↔ assistant tab switch.
            // SwiftUI's Color.black.ignoresSafeArea() covers this in steady
            // state; the explicit backgroundColor ensures there is no gap.
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = scene.windows.first {
                window.backgroundColor = .black
                window.rootViewController?.view.backgroundColor = .black

                #if targetEnvironment(macCatalyst)
                // The iOS app is iPhone-only/portrait; on Mac that would
                // otherwise derive a cramped, oddly-fixed window. Make the
                // window freely resizable with a usable minimum so the
                // portrait-oriented UI stays legible. Hide the title bar so
                // the app's own chrome owns the full window.
                scene.sizeRestrictions?.minimumSize = CGSize(width: 480, height: 720)
                scene.sizeRestrictions?.maximumSize = CGSize(width: 2200, height: 3000)
                scene.titlebar?.titleVisibility = .hidden
                scene.titlebar?.toolbar = nil
                #endif
            }
        }
        .koduTheme(KoduTheme.make(
            appearance: settings.appearance,
            accent: KoduTheme.appAccent))
        .preferredColorScheme(settings.resolvedColorScheme)
        .koduScaledType()
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Install the crash reporter as early as possible so the signal /
        // exception handlers are armed before any heavy work, and so a prior
        // session's crash (incl. jetsam) is detected and surfaced.
        CrashReporter.shared.install()
        Diagnostics.shared.breadcrumb("app launch · \(SystemSnapshot.appVersion()) · iOS \(SystemSnapshot.osVersion())")

        // Force all UINavigationBars to transparent by default. Without this,
        // switching from the assistant tab (which sets a cream toolbarBackground)
        // to the camera tab leaves a 1-2 frame UIKit cream strip at the top —
        // SwiftUI's disablesAnimations cannot suppress UIKit-level bar repaints.
        // Individual screens also keep toolbar backgrounds hidden so iOS 26 can
        // render its clear floating controls without an opaque strip underneath.
        let clear = UINavigationBarAppearance()
        clear.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance   = clear
        UINavigationBar.appearance().compactAppearance    = clear
        UINavigationBar.appearance().scrollEdgeAppearance = clear

        // Override the broken upstream SmolVLMProcessor with our
        // rescue implementation. Has to run before any VLM load
        // pulls from VLMProcessorTypeRegistry.shared — registering
        // here in didFinishLaunching is the earliest hook iOS gives
        // us, and is the same idempotent registration pattern used
        // by FastVLM (see FastVLMService.load()).
        // Registration is async in mlx-swift-lm 3.x (the registry is an
        // actor). Kick it off here at launch; it completes long before any
        // user-initiated VLM load looks up the processor type.
        Task { await SmolVLM2Rescue.register(modelFactory: VLMModelFactory.shared) }
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            BackgroundDownloadCoordinator.shared.systemCompletionHandler = completionHandler
            // Re-create the background URLSession (it's lazy) so its delegate
            // is attached and the queued events actually deliver — without
            // this, downloads that finished while the app was dead were
            // never moved into place after relaunch.
            BackgroundDownloadCoordinator.shared.reattach()
        }
    }
}
