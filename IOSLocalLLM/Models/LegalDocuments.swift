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
    static let currentVersion = 6

    // MARK: - Public URLs
    static let privacyPolicyURL = "https://ondevice.fun/local-ai-studio/privacy/"
    static let eulaURL          = "https://github.com/Mesutcydev/ios-local-llm/blob/main/LICENSE"
    static let supportURL       = "https://ondevice.fun/local-ai-studio/support/"

    // MARK: - Privacy Policy

    static let privacyPolicy = """
    # OnDevice LLM Privacy Policy

    _Last updated: 2026-11-13_

    OnDevice LLM (the iOS Local LLM project) runs downloaded AI models locally by
    default. We do not operate an account system, advertising service, analytics
    service, or telemetry backend. Optional network features send data to the
    recipients described below. Do not include private information in web queries.

    ## Local storage

    Conversations are saved in the app sandbox with iOS file protection. A saved
    conversation can include message text, image thumbnails from camera captures
    or imported photos, and model context derived from documents, web pages or the
    Knowledge Base. These attachments are retained with the conversation; they
    are not always discarded after analysis. Camera preview frames that are not
    attached to a conversation are processed in memory.

    Memories, snippets, custom personas, macros and settings are saved locally.
    The Knowledge Base stores imported document content and derived indexes.
    Downloaded models, temporary download data, and cached resources stay in the
    app sandbox. Local diagnostics and benchmarks contain operational information
    and are not sent to us. Web activity history can contain search queries and
    URLs and is rotated at 500 entries or approximately 1 MB.

    ## Optional network features

    - **Model discovery and downloads:** After you request them, Hugging Face or
      the selected source receives model requests and connection metadata such as
      your IP address. A saved Hugging Face token is sent only to authorized
      Hugging Face endpoints when needed. Model terms are separate from the app's
      source license. FastVLM research weights are not offered in the consumer app.
    - **Web search and web pages:** The query or URL shown in the permission sheet
      is sent to the selected provider or website. Your complete chat history and
      attachments are not sent by the web tool. Providers receive connection
      metadata and an API credential when configured. They may retain queries,
      associate them with the API account, and use them to improve their services.
      Brave's API notice specifies query retention for up to 90 days; Tavily and
      Exa describe query reuse under their applicable terms. Review the provider's
      policy before allowing a request. Changing an app setting does not delete
      records already held by a provider. The App Store privacy label lists this
      search and request data, with an Analytics purpose, because providers may
      reuse it; the app itself includes no analytics SDK and sends no usage data to
      the developer.
    - **Mac Bridge and Local API:** When enabled, these features send prompts,
      outputs and requested tool data between this app and authorized clients on
      your network. TLS encrypts the connection. Pairing can disclose a device
      identifier to the paired client. Clients control their own storage.
    - **iCloud sync:** Off by default. When enabled, Apple stores entire saved
      conversations, including attached thumbnails and model context, in your
      private CloudKit database. Disabling sync stops future synchronization but
      does not delete existing cloud copies. Use the separate cloud deletion
      control to remove them.
    - **Private Cloud Compute:** Available only in builds configured with Apple's
      approved capability. Choosing this model requires a separate disclosure and
      explicit consent before prompts are sent to Apple's cloud service. Standard
      builds do not enable this capability.
    - **External links and exports:** Links open after your action. When you export
      or share content, the chosen app or destination controls its handling.

    Provider policies: [Hugging Face](https://huggingface.co/privacy),
    [Brave API](https://api-dashboard.search.brave.com/app/documentation/general/privacy-policy),
    [Tavily](https://www.tavily.com/privacy), [Exa](https://exa.ai/privacy-policy),
    [Apple](https://www.apple.com/legal/privacy/).

    The network indicator covers the app's monitored networking layer, not every
    system or framework connection. There is no silent fallback from local
    inference to a remote model.

    ## Camera, microphone and speech

    Camera and microphone access require system permission. Selected images may
    be saved as conversation thumbnails as described above. Microphone audio is
    transcribed with a local Whisper model or Apple's on-device Speech framework.
    If on-device recognition is unavailable, the app refuses the operation instead
    of allowing server recognition. Apple frameworks operate under Apple's
    privacy practices. Turning off permission in system Settings stops access.

    ## Calendar and Reminders

    The assistant can read your upcoming calendar events, add a calendar event, or
    add a reminder only after you approve each request in the chat, and only after
    iOS shows its own permission prompt. Event and reminder text stays on the device
    and is used only as context for the local model. If calendar details are in a
    chat, any later web search asks for your approval again and shows the exact
    query before it is sent. Voice conversations cannot use these tools. Turning
    off Calendar or Reminders access in system Settings stops access.

    ## Deletion and retention

    Local content remains until you delete it, wipe it, or a documented cache or
    history limit rotates it. "Wipe all on-device data" clears local conversations,
    snippets, memories, custom prompts, web activity, downloaded models, cached
    resources, app preferences and saved API credentials. It also disables iCloud
    sync and stops local servers. Existing cloud copies and third-party records
    are not deleted. A parental PIN is retained so resetting content cannot bypass
    a parent's restriction; unlock and remove it in Parental Controls when desired.
    Restart after a wipe before using model features again.

    Uninstalling removes the app sandbox. Keychain credentials can survive
    uninstallation; clear saved credentials before uninstalling if desired. System
    backups and exports you made are controlled separately by you and Apple.

    ## Local content checks

    Generated image prompts and outputs are checked on the device. The image
    classifier runs locally before an output is shown or shared; it does not send
    images or prompts to us. These checks can make mistakes and are separate from
    the parental feature lock. Language-model safety instructions do not guarantee
    that arbitrary downloaded models will always produce appropriate content.

    ## Parental controls

    A parent or guardian can set a separate PIN to restrict image generation. The
    PIN verifier and retry limits are kept in the device-only Keychain; the PIN is
    not sent to us. Access relocks when the app backgrounds. This feature lock does
    not verify age or replace content safeguards. Screen Time can restrict access
    to the entire app. The app is not designed as a children's educational app.

    ## Contact and changes

    For privacy questions, email mesutcydev@gmail.com or use the repository's
    support page: https://github.com/Mesutcydev/ios-local-llm/issues. Do not include
    private content or credentials in an email or issue. We update this policy when handling changes;
    optional network features keep their own consent controls.
    """

    // MARK: - Open-source license and safety notice

    static let eula = """
    # Open-Source License and Safety Notice

    **Last updated:** \(currentVersionDate)

    This source distribution contains original open-source software and separately licensed third-party material. This notice summarizes licenses and important safety information; it does not add copyright restrictions to the MIT-licensed portions of the app.

    ## 1. iOS Local LLM license
    Original iOS Local LLM source code and documentation are licensed under the **MIT License**. Subject to that license, you may use, copy, modify, merge, publish, distribute, sublicense, and sell copies.

    The MIT copyright and permission notice must be included in copies or substantial portions of the software. “iOS Local LLM” is used as a descriptive project title. iOS and related names are Apple Inc. trademarks; this independent project is not affiliated with or endorsed by Apple or any compatibility provider. Modified public distributions should use their own identity and must not imply endorsement.

    ## 2. Third-party components and models
    iOS Local LLM includes or downloads components that are separate works under their own terms. Those terms are not replaced by the iOS Local LLM MIT License.

    A model may be open source, source-available, community-licensed, non-commercial, or research-only. **Review the license shown by the model source before downloading, using, modifying, or redistributing it.** Apple FastVLM model weights, for example, are licensed for research purposes only and are not part of the MIT-licensed source distribution.

    ## 3. AI-generated content
    The app runs downloaded models on your device. Optional cloud models require separate consent. Outputs are generated by statistical models and may be:
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
    Some features capture camera frames, microphone audio, or photo-library images. **You are solely responsible for ensuring you have the legal right to capture and analyse any image, video, or audio you process with the app**, including obtaining any necessary consent from persons captured. Local models process captured data on-device. Saving, iCloud sync, network integrations and exports can retain or transmit content as described in the Privacy Policy.

    ## 6. Network usage and privacy
    The app makes outbound network requests only for user-initiated or explicitly enabled features: searching or downloading from Hugging Face, web search, Mac Bridge and Local API communication on your local network, optional iCloud sync, and external documentation or links you choose to open. Each provider, including Hugging Face, Apple iCloud, and any configured search provider, applies its own terms and privacy policy. Use of any downloaded model is subject to that model's own license, which you must read and comply with.

    ## 7. No warranty
    IOS_LOCAL_LLM, THIRD-PARTY COMPONENTS, MODELS, AND AI OUTPUTS ARE PROVIDED **"AS IS"**, WITHOUT WARRANTY OF ANY KIND, TO THE MAXIMUM EXTENT PERMITTED BY THEIR APPLICABLE LICENSES AND BY LAW. The complete MIT warranty disclaimer is included with the source distribution.

    **By continuing, you confirm that you have read this notice and understand that model licenses and safety information require separate attention.**
    """

    // MARK: - User disclaimer (shown to users on first use of AI features)

    static let aiDisclaimer = """
    # AI Output Disclaimer

    OnDevice LLM runs **downloaded artificial intelligence models on your device by default** to analyse images, generate text, extract code, review code, transcribe speech, and synthesize speech. A model's availability in the catalog does not mean it is open source. Read its license and understand the following before relying on any output.

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
    When you use the camera or import a photo, the app analyses pixels with on-device AI. **You are responsible for ensuring you have the right to capture and analyse the subject matter** (consent of people in frame, licence to scan documents, etc.). Images are processed locally by downloaded models. Attached thumbnails may be saved with conversations and synced when you enable iCloud.

    ## 5. You are responsible for what you do with the output
    You — not the app, not the model authors, not us — are responsible for any decision you make or action you take based on AI output, including but not limited to:
    - Code you commit, ship, or run.
    - Decisions you make based on a described image.
    - Actions taken in response to TTS / spoken output.
    - Anything you share with another person.

    ## 6. On-device privacy (not anonymity)
    Downloaded models run locally. Optional web requests, local-network integrations, iCloud sync, cloud models in approved builds, and exports can transmit content after your action or consent. The Privacy Policy describes recipients, storage and deletion limits.

    The activity indicator covers monitored app requests. It is not a system-wide packet monitor. Local processing does not make your use anonymous to your network provider, device-management policies or people with access to your unlocked device.

    ## 7. Device thermals and battery
    Running large models is computationally intensive. Your device will warm up, occasionally significantly, and battery will drain faster than during normal use. iOS may throttle performance to protect the device, and we apply additional protections (token-cap reduction, generation refusal, mid-stream halts) when iOS reports a "serious" or "critical" thermal state. **Do not place the device on flammable surfaces, do not charge in an enclosed space while running heavy generation, and stop using the app if the device becomes uncomfortably hot.**

    ## 8. Bias and content
    The underlying models were trained on large, primarily English, internet-sourced datasets and reflect biases, errors, and offensive content present in that data. Outputs can be offensive or unsafe. Do not request sexual exploitation, pornography, graphic abuse or other prohibited content. Image prompts and outputs are checked locally before preview or sharing. Checks can make mistakes. Parental controls restrict feature access separately; they do not verify age. Language-model safety instructions do not guarantee that arbitrary downloaded models will always follow them. Report unsafe behavior through Support so we can investigate and improve safeguards.

    ## 9. Voice / text-to-speech outputs
    Spoken output is synthesized from text by a TTS model. Tone and emphasis may differ from what a human reader would convey. Do not rely on voice mode for time-critical or safety-critical instructions, and do not assume the spoken version captures every detail of the written reply.

    ## 10. Third-party model licenses
    Each model you download from Hugging Face is governed by its own license. Some licenses restrict commercial use or impose usage conditions. **It is your responsibility to read and comply with each license.** Attribution, source URLs, and license summaries are available in **Settings → Legal → Attributions**.

    **By continuing, you confirm that you have read this disclaimer and accept full responsibility for how you use the app and AI output.**
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
    - **Network usage** — model discovery and downloads, optional web search and iCloud sync, and enabled local-network integrations use a connection. Downloads can be several gigabytes; use Wi-Fi.

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
        Attribution(
            name: "Local image safety classifier",
            author: "The nsfw_model Developers / TensorFlow",
            license: "MIT / Apache-2.0",
            licenseURL: "https://github.com/GantMan/nsfw_model/blob/1.1.0/LICENSE.md",
            sourceURL: "https://github.com/GantMan/nsfw_model/releases/tag/1.1.0",
            paperURL: nil,
            note: "MobileNet v1.1.0 converted to Core ML. Runs locally before generated images are shown or shared. Full notices are in the bundled license document.",
            category: "Image Generation"
        ),

        Attribution(
            name: "SDXL Turbo / SD-Turbo — Powered by Stability AI",
            author: "Stability AI Ltd.",
            license: "Stability AI Community License (5 July 2024)",
            licenseURL: "https://huggingface.co/stabilityai/sdxl-turbo/blob/71153311d3dbb46851df1931d3ca6e939de83304/LICENSE.md",
            sourceURL: "https://stability.ai/license",
            paperURL: nil,
            note: "Optional downloaded image models. Commercial use requires registration and revenue eligibility, or a separate enterprise license. The full agreement and attribution are included in the bundled license document.",
            category: "Image Generation"
        ),

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
            note: "Backbone referenced by the legacy FastVLM source integration; research weights are unavailable in the consumer app.",
            category: "Language Model"
        ),
        Attribution(
            name: "LFM3 1.7B, VL 2B, Audio 2B, and Omni 2B (GGUF)",
            author: "Liquid AI, Inc.",
            license: "LFM Open License v1.0",
            licenseURL: "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/blob/b3f2ae5d73cd3c91bf40e8ba752c648aa05dffdf/LICENSE",
            sourceURL: "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF",
            paperURL: nil,
            note: "Optional user-initiated GGUF downloads for text, vision, native audio, and native speech. Weights remain outside this source distribution. Commercial use at or above the license revenue threshold requires a separate agreement. Full text is in the bundled license document.",
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
            note: "Research-only weights are unavailable in the consumer app and are excluded from this source distribution. The sample-code license is separate.",
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
        "2026-10-08"
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
