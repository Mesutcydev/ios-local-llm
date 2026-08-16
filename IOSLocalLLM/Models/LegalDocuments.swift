import Foundation

// MARK: - LegalDocuments
// Centralised source of truth for every legal text shown in the app.
// Edit these strings to update the Privacy Policy, license notice, Disclaimer,
// and Attributions.
//
// IMPORTANT before distributing a modified build:
//   • Update the public URLs below to point to your fork.
//   • Have a real lawyer review these texts for your jurisdiction.
//   • The texts below are template-quality, not legal advice.

enum LegalDocuments {

    // MARK: - Versioning
    // Bump this whenever any legal text materially changes. Existing users
    // will be re-prompted to accept on app launch.
    static let currentVersion = 4

    // MARK: - Public URLs
    static let privacyPolicyURL = "https://github.com/Mesutcydev/ios-local-llm/blob/main/PRIVACY_POLICY.md"
    static let eulaURL          = "https://github.com/Mesutcydev/ios-local-llm/blob/main/LICENSE"
    static let supportURL       = "https://github.com/Mesutcydev/ios-local-llm/issues"

    // MARK: - Privacy Policy

    static let privacyPolicy = """
    # Privacy Policy

    **Last updated:** \(currentVersionDate)

    OnDevice LLM ("we", "the app") is designed with privacy as the core principle. All AI processing happens entirely on your device. We do not operate any servers and we do not collect, store, transmit, or sell your personal data.

    ## 1. What we do NOT collect
    - We do **not** collect images, video, or photos captured by the camera.
    - We do **not** collect any text you enter, including chat conversations with the on-device assistant.
    - We do **not** collect analytics, telemetry, crash reports, device identifiers, advertising identifiers, or any other usage data.
    - We do **not** use cookies or web beacons.
    - We do **not** sell, rent, or share data with third parties because we do not collect any data.

    ## 2. What stays on your device
    - **Camera frames** captured for analysis are processed in-memory and discarded immediately. They are never written to disk by the app unless you explicitly save them via the iOS share sheet.
    - **Photos** you import from your Photo Library are read into memory, analysed, and discarded.
    - **Chat conversations** with the Coding Assistant are stored locally in the app's sandbox (Documents folder). You can delete them at any time. They are never uploaded.
    - **Downloaded AI models** (e.g. Qwen3, FastVLM, KittenTTS) are stored in the app's sandbox. They are downloaded directly from Hugging Face on first use and used entirely locally afterwards.

    ## 3. Network usage
    The app connects to the network only for explicit features:
    - **Model search and download:** Hugging Face receives the request. A saved Hugging Face token is included only when required for a gated repository.
    - **Web search:** When you enable web search and submit a query, the configured provider receives that query under its own terms.
    - **Mac Bridge and Local API Server:** When enabled, paired clients communicate with the app over your local network.
    - **iCloud sync:** When enabled, Apple stores conversations in your private CloudKit database.
    - **External documentation and links:** These open only after your action.

    There is no OnDevice LLM telemetry channel, remote configuration service, analytics SDK, or advertising SDK.

    ## 4. Permissions we request
    - **Camera:** Required to capture frames for live analysis. Disable in iOS Settings any time; the app will continue to work with imported photos only.
    - **Photo Library:** Optional. Only requested when you tap the photo picker. The app accesses only photos you explicitly select.

    ## 5. Children
    The app is not directed at children under 13. We do not knowingly process data from children. If you are a parent or guardian and believe a child is using the app contrary to this policy, please contact us via the Support link in Settings.

    ## 6. Third-party AI models
    The app uses third-party AI models that run on your device. We are not the authors of these models. Each model's license, source repository, and citation is shown in **Settings → Legal → Attributions**. A model may be open source, source-available, community-licensed, or restricted to research use; review its terms before downloading or using it.

    ## 7. Hugging Face downloads
    When you tap "download" on a Hugging Face model, your device makes HTTPS requests to `huggingface.co`. We do not control Hugging Face. Their privacy policy and terms of service apply. If you save a Hugging Face token for a gated repository, the app stores it in the Keychain and sends it to Hugging Face for authorized requests; OnDevice LLM does not receive it.

    ## 8. Apple frameworks
    The app uses Apple-provided iOS frameworks (Vision, Speech, Core ML, MetricKit, ActivityKit, CloudKit when iCloud sync is enabled). These frameworks operate under Apple's privacy practices. **Speech recognition is forced on-device** wherever the device supports it (recent iPhones). CloudKit sync, if you enable it, stores conversations in **your** private iCloud database — Apple, not us, controls that storage.

    ## 9. MetricKit diagnostics
    iOS periodically sends MetricKit reports (crash, hang, CPU usage) to the app for the user's own diagnostic use. These reports stay on the device — we do not collect or transmit them. You can view and delete them in **Settings → Diagnostics**.

    ## 10. Network-activity indicator
    A live indicator in the assistant tab reports requests made through the app's monitored networking layer. It is a useful diagnostic, not a system-wide packet monitor.

    ## 11. Data retention
    All app data is stored in the app's iOS sandbox. Conversations are stored encrypted-at-rest (`completeFileProtectionUnlessOpen`). You can wipe all on-device data at any time via **Settings → Privacy & Reset → Wipe all on-device data**. Uninstalling the app also removes everything we've stored on the device.

    ## 12. Your rights
    Because we do not collect personal data, there is nothing for us to access, correct, port, or delete on your behalf. All of your data is on your device, under your control. If you believe we have nevertheless processed your personal data, contact us via the Support link.

    ## 13. Changes
    If we change this policy we will update the "Last updated" date and re-prompt for acceptance inside the app.

    ## 14. Contact
    Questions: see Settings → Legal → Support.
    """

    // MARK: - Open-source license and safety notice

    static let eula = """
    # Open-Source License and Safety Notice

    **Last updated:** \(currentVersionDate)

    This source distribution contains original open-source software and separately licensed third-party material. This notice summarizes licenses and important safety information; it does not add copyright restrictions to the MIT-licensed portions of the app.

    ## 1. OnDevice LLM license
    Original OnDevice LLM source code and documentation are licensed under the **MIT License**. Subject to that license, you may use, copy, modify, merge, publish, distribute, sublicense, and sell copies.

    The MIT copyright and permission notice must be included in copies or substantial portions of the software. “OnDevice LLM” is used as a descriptive project title. iOS and related names are Apple Inc. trademarks; this independent project is not affiliated with or endorsed by Apple or any compatibility provider. Modified public distributions should use their own identity and must not imply endorsement.

    ## 2. Third-party components and models
    OnDevice LLM includes or downloads components that are separate works under their own terms. Those terms are not replaced by the OnDevice LLM MIT License.

    A model may be open source, source-available, community-licensed, non-commercial, or research-only. **Review the license shown by the model source before downloading, using, modifying, or redistributing it.** Apple FastVLM model weights, for example, are licensed for research purposes only and are not part of the MIT-licensed source distribution.

    ## 3. AI-generated content
    The app runs third-party AI models entirely on your device. Outputs are generated by statistical models and may be:
    - Factually incorrect, outdated, fabricated, or misleading ("hallucinations").
    - Biased, offensive, or unsafe.
    - Inappropriate or harmful in your context (medical, legal, financial, safety-critical, security, or other regulated domains).
    - Subject to third-party copyright or other intellectual-property rights.

    **You alone are responsible for verifying any AI output before relying on it.** Do not use AI output to make any decision that could affect a person's health, safety, finances, legal rights, or employment, without independent verification by a qualified human professional. **Do not run AI-generated code in production, against real data, or in any environment you cannot afford to lose, without thorough independent review and testing.**

    ## 4. Device safety
    Running large machine-learning models on a mobile device is computationally intensive and may:
    - Cause the device to **become warm or hot to the touch**.
    - **Reduce battery life** during use and accelerate long-term battery wear.
    - Trigger iOS thermal throttling, which the app handles automatically by reducing output length or pausing generation.
    - In extreme cases, cause the operating system to terminate the app to protect the device.

    These are intrinsic properties of on-device AI inference. Do not use the app where device heat could cause harm, and stop using it if the device becomes uncomfortably hot.

    ## 5. Camera, microphone, and image use
    Some features capture camera frames, microphone audio, or photo-library images. **You are solely responsible for ensuring you have the legal right to capture and analyse any image, video, or audio you process with the app**, including obtaining any necessary consent from persons captured. The app processes this data entirely on-device and does not transmit it anywhere, but local processing does not relieve you of consent and privacy obligations under your local law.

    ## 6. Network usage and privacy
    The app makes outbound network requests only for user-initiated or explicitly enabled features: searching or downloading from Hugging Face, web search, Mac Bridge and Local API communication on your local network, optional iCloud sync, and external documentation or links you choose to open. Each provider, including Hugging Face, Apple iCloud, and any configured search provider, applies its own terms and privacy policy. Use of any downloaded model is subject to that model's own license, which you must read and comply with.

    ## 7. No warranty
    IOS_LOCAL_LLM, THIRD-PARTY COMPONENTS, MODELS, AND AI OUTPUTS ARE PROVIDED **"AS IS"**, WITHOUT WARRANTY OF ANY KIND, TO THE MAXIMUM EXTENT PERMITTED BY THEIR APPLICABLE LICENSES AND BY LAW. The complete MIT warranty disclaimer is included with the source distribution.

    **By continuing, you confirm that you have read this notice and understand that model licenses and safety information require separate attention.**
    """

    // MARK: - User disclaimer (shown to users on first use of AI features)

    static let aiDisclaimer = """
    # AI Output Disclaimer

    OnDevice LLM runs **third-party artificial intelligence models entirely on your device** to analyse images, generate text, extract code, review code, transcribe speech, and synthesize speech. A model's availability in the catalog does not mean it is open source. Read its license and understand the following before relying on any output.

    ## 1. AI output is generated by statistics, not understanding
    Outputs are produced by neural networks that predict the next token based on patterns in their training data. They do not "understand" your input, do not have access to real-time information, and do not verify their own answers. They can and routinely will produce:
    - **Hallucinations** — confidently stated facts, citations, function names, library APIs, or library versions that do not exist.
    - **Bugs and security holes** — code that compiles or appears reasonable but contains logic errors, race conditions, injection vulnerabilities, exposed secrets, or licence violations.
    - **Inaccurate OCR / image analysis** — characters misread, code mis-transcribed, contents of an image mis-described.
    - **Biased, offensive, or unsafe content** — reflecting biases in the training data.
    - **Out-of-date information** — the models do not have current internet access and may be months or years behind.

    **Always independently verify any AI output before relying on it.**

    ## 2. Do not run AI-generated code blindly
    Treat generated code as a draft, not a finished product. Before running it:
    - Read it line by line.
    - Run it in a sandboxed environment, not against production data or critical infrastructure.
    - Test it with edge cases and adversarial inputs.
    - Review any shell commands, file operations, network calls, deletes, or destructive actions in particular.
    - Check that any libraries, APIs, and CLI flags it uses actually exist and behave the way the model claims.

    **We are not responsible for any data loss, security breach, system damage, financial loss, or other harm caused by running AI-generated code or commands.**

    ## 3. Not a substitute for a professional
    The app does **not** provide and must not be relied on for:
    - **Medical** advice, diagnosis, or treatment.
    - **Legal** advice or interpretation.
    - **Financial**, tax, or investment advice.
    - **Engineering, safety-critical, or life-critical** decisions (aviation, automotive, industrial control, structural, electrical, etc.).
    - **Mental-health, crisis, or self-harm** support. If you are in crisis, contact your local emergency number or a qualified crisis service.

    Consult a qualified human professional for any decision in these areas.

    ## 4. Camera, microphone, and image processing
    When you use the camera or import a photo, the app analyses pixels with on-device AI. **You are responsible for ensuring you have the right to capture and analyse the subject matter** (consent of people in frame, licence to scan documents, etc.). The app processes everything locally and does not transmit images, but local processing does not relieve you of consent obligations under your local law.

    ## 5. You are responsible for what you do with the output
    You — not the app, not the model authors, not us — are responsible for any decision you make or action you take based on AI output, including but not limited to:
    - Code you commit, ship, or run.
    - Decisions you make based on a described image.
    - Actions taken in response to TTS / spoken output.
    - Anything you share with another person.

    ## 6. On-device privacy (not anonymity)
    All AI inference happens on your device. The app makes no telemetry calls and does not transmit your prompts, images, or audio. The only outbound network requests are:
    - Searches and downloads from `huggingface.co` when you explicitly request them; gated repositories may include a token you saved.
    - Web search when you enable it and submit a query.
    - Mac Bridge or Local API communication on your local network when enabled.
    - iCloud synchronization when enabled.
    - External documentation and links when you choose them.

    A live indicator in the assistant tab lights up whenever ANY network request is in flight. On-device processing protects you from cloud-side data retention but does **not** make your use anonymous to your network provider, your device-management policies, or anyone with physical access to your unlocked device.

    ## 7. Device thermals and battery
    Running large models is computationally intensive. Your device will warm up, occasionally significantly, and battery will drain faster than during normal use. iOS may throttle performance to protect the device, and we apply additional protections (token-cap reduction, generation refusal, mid-stream halts) when iOS reports a "serious" or "critical" thermal state. **Do not place the device on flammable surfaces, do not charge in an enclosed space while running heavy generation, and stop using the app if the device becomes uncomfortably hot.**

    ## 8. Bias and content
    The underlying models were trained on large, primarily English, internet-sourced datasets and reflect biases, errors, and offensive content present in that data. The app does **not** add content filters beyond what each model includes. Adult, harassing, or otherwise inappropriate output is possible and is the model's behaviour, not ours.

    ## 9. Voice / text-to-speech outputs
    Spoken output is synthesized from text by a TTS model. Tone and emphasis may differ from what a human reader would convey. Do not rely on voice mode for time-critical or safety-critical instructions, and do not assume the spoken version captures every detail of the written reply.

    ## 10. Third-party model licences
    Each model you download from Hugging Face is governed by its own licence. Some licences restrict commercial use or impose usage conditions. **It is your responsibility to read and comply with each licence.** Attribution, source URLs, and licence summaries are available in **Settings → Legal → Attributions**.

    **By tapping "I Understand", you confirm that you have read this disclaimer and accept full responsibility for how you use the app and AI output.**
    """

    // MARK: - Device-safety acknowledgement
    // Surfaced on first launch alongside the EULA and AI disclaimer so users
    // see the thermal/battery realities of on-device AI up front.

    static let deviceSafetyNotice = """
    # Device Safety Notice

    On-device AI inference is computationally intensive. By using OnDevice LLM you acknowledge and accept the following.

    ## What to expect
    - **Heat** — your device will become warm, sometimes hot, during model loading and long replies. This is normal for sustained GPU/Neural-Engine work and is the same effect you'd see from a long gaming session or a long video-call.
    - **Battery drain** — battery percentage will drop faster than during normal use. Heavy daily use will also accelerate long-term battery wear, the same as other intensive apps.
    - **Background termination** — iOS may suspend or terminate the app to recover memory or thermal headroom, especially on older devices or when many apps are running.
    - **Network usage** — only when you download a model. Downloads can be several gigabytes; use Wi-Fi.

    ## What we do to protect your device
    - **Thermal-aware token caps** — when iOS reports the device is "warm," we shorten replies. When "hot," we pause generation and tell you.
    - **Memory-warning halts** — if iOS signals memory pressure mid-reply, we stop generation instead of risking a hard crash.
    - **Auto-tier defaults** — on first launch we pick a model that comfortably fits this device's RAM.
    - **Storage cap** — model downloads are limited to the device's free space; the OS itself prevents downloads that would fill the disk.

    ## What you should do
    - **Take breaks** during long sessions, especially on older devices. Let the phone cool.
    - **Do not place the device on flammable materials** while running heavy generation.
    - **Do not run heavy generation while charging in a hot, enclosed space** (e.g. under bedding).
    - **Stop using the app** if the device becomes uncomfortably hot or behaves strangely.
    - **Charge with an Apple-certified cable and adapter** to avoid charging-related thermal issues unrelated to the app.

    These are intrinsic properties of on-device machine learning, not defects of OnDevice LLM. By continuing you accept that we are not liable for normal thermal output, normal battery drain, or accelerated battery wear consistent with intensive use.
    """

    // MARK: - Attributions

    /// Each Attribution describes a single third-party component we use,
    /// its source, and its license. Shown in Settings → Legal → Attributions.
    static let attributions: [Attribution] = [

        // ── On-device LLMs ───────────────────────────────────────────────────
        Attribution(
            name: "Qwen3-4B (mlx-community 4-bit)",
            author: "Alibaba Cloud / Tongyi Lab",
            license: "Apache-2.0",
            licenseURL: "https://github.com/QwenLM/Qwen3/blob/main/LICENSE",
            sourceURL: "https://huggingface.co/mlx-community/Qwen3-4B-4bit",
            paperURL: "https://arxiv.org/abs/2502.12119",
            note: "Used as the default on-device coding assistant. Qwen3 source and weights are published under Apache-2.0; verify the selected model repository before redistribution.",
            category: "Language Model"
        ),
        Attribution(
            name: "Qwen2-0.5B (FastVLM LLM backbone)",
            author: "Alibaba Cloud / Tongyi Lab",
            license: "Apache-2.0",
            licenseURL: "https://huggingface.co/Qwen/Qwen2-0.5B-Instruct/blob/main/LICENSE",
            sourceURL: "https://huggingface.co/Qwen/Qwen2-0.5B-Instruct",
            paperURL: "https://arxiv.org/abs/2407.10671",
            note: "Used as the language model inside the FastVLM pipeline.",
            category: "Language Model"
        ),

        // ── Vision–Language ──────────────────────────────────────────────────
        Attribution(
            name: "FastVLM sample implementation",
            author: "Apple Inc.",
            license: "Apple Sample Code License",
            licenseURL: "https://github.com/apple/ml-fastvlm/blob/main/LICENSE",
            sourceURL: "https://github.com/apple/ml-fastvlm",
            paperURL: "https://arxiv.org/abs/2412.13303",
            note: "Adapted vision encoder and projector sample code. FastVLM model weights are separate and use Apple's research model license.",
            category: "Vision–Language"
        ),
        Attribution(
            name: "FastVLM model weights (not included)",
            author: "Apple Inc.",
            license: "Apple Machine Learning Research Model License",
            licenseURL: "https://github.com/apple/ml-fastvlm/blob/main/LICENSE_MODEL",
            sourceURL: "https://github.com/apple/ml-fastvlm",
            paperURL: "https://arxiv.org/abs/2412.13303",
            note: "Optional research-licensed model weights are not distributed in this source repository. Review LICENSE_MODEL before downloading or using them.",
            category: "Vision–Language"
        ),

        // ── Text-to-speech ───────────────────────────────────────────────────
        Attribution(
            name: "KittenTTS (CoreML)",
            author: "Alex Weng",
            license: "Apache-2.0",
            licenseURL: "https://huggingface.co/alexwengg/kittentts-coreml",
            sourceURL: "https://huggingface.co/alexwengg/kittentts-coreml",
            paperURL: nil,
            note: "On-device text-to-speech model. Based on the Kokoro architecture.",
            category: "Text-to-Speech"
        ),
        Attribution(
            name: "Kokoro-82M",
            author: "hexgrad",
            license: "Apache-2.0",
            licenseURL: "https://huggingface.co/hexgrad/Kokoro-82M",
            sourceURL: "https://huggingface.co/hexgrad/Kokoro-82M",
            paperURL: nil,
            note: "Experimental on-device TTS engine.",
            category: "Text-to-Speech"
        ),

        // ── Frameworks ───────────────────────────────────────────────────────
        Attribution(
            name: "MLX Swift (PrismML fork)",
            author: "Apple Inc. / PrismML contributors",
            license: "MIT",
            licenseURL: "https://github.com/PrismML-Eng/mlx-swift/blob/main/LICENSE",
            sourceURL: "https://github.com/PrismML-Eng/mlx-swift",
            paperURL: nil,
            note: "Pinned fork of Apple's Swift API for MLX, used for on-device inference and required one-bit kernels.",
            category: "Framework"
        ),
        Attribution(
            name: "MLX Swift LM",
            author: "MLX contributors",
            license: "MIT",
            licenseURL: "https://github.com/ml-explore/mlx-swift-lm/blob/main/LICENSE",
            sourceURL: "https://github.com/ml-explore/mlx-swift-lm",
            paperURL: nil,
            note: "Provides MLXLLM, MLXVLM, and MLXLMCommon model factories.",
            category: "Framework"
        ),
        Attribution(
            name: "Swift Transformers",
            author: "Hugging Face",
            license: "Apache-2.0",
            licenseURL: "https://github.com/huggingface/swift-transformers/blob/main/LICENSE",
            sourceURL: "https://github.com/huggingface/swift-transformers",
            paperURL: nil,
            note: "Tokenizers and Hub utilities used by mlx-swift-examples.",
            category: "Framework"
        ),
        Attribution(
            name: "thinking-orbs",
            author: "Jakub Antalik",
            license: "MIT",
            licenseURL: "https://github.com/Jakubantalik/thinking-orbs/blob/main/LICENSE",
            sourceURL: "https://github.com/Jakubantalik/thinking-orbs",
            paperURL: nil,
            note: "Dotted state animations adapted for the native Voice Mode canvas.",
            category: "Framework"
        ),
        Attribution(
            name: "Apple Core ML & Vision",
            author: "Apple Inc.",
            license: "Apple SDK License",
            licenseURL: "https://developer.apple.com/support/terms/",
            sourceURL: "https://developer.apple.com/documentation/coreml",
            paperURL: nil,
            note: "iOS frameworks for on-device ML inference, OCR (VNRecognizeTextRequest), and image processing.",
            category: "Framework"
        ),

        // ── Datasets / Catalogues ────────────────────────────────────────────
        Attribution(
            name: "Hugging Face Hub",
            author: "Hugging Face, Inc.",
            license: "Hub Terms of Service",
            licenseURL: "https://huggingface.co/terms-of-service",
            sourceURL: "https://huggingface.co",
            paperURL: nil,
            note: "All AI models are downloaded from huggingface.co at the user's explicit request.",
            category: "Service"
        ),
    ]

    // MARK: - Helpers

    private static var currentVersionDate: String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: Date(timeIntervalSinceReferenceDate: 806_976_000)) // 2026-07-29
    }
}

// MARK: - Attribution

struct Attribution: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let author: String
    let license: String
    let licenseURL: String?
    let sourceURL: String?
    let paperURL: String?
    let note: String
    let category: String
}
