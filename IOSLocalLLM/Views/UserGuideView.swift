import SwiftUI

struct UserGuideView: View {
    @Environment(\.koduTheme) private var T
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: Space.cardGap) {
                // Intro Section
                VStack(alignment: .leading, spacing: Space.xs) {
                    KCaption(text: "manual")
                    KPageTitle(title: "User Guide", size: 28)
                    KMono(text: "On-device AI studio manual & workflows", size: 12, color: T.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.m)
                .padding(.top, Space.s)

                // Privacy Note
                HStack(spacing: Space.s) {
                    Image(systemName: "lock.fill")
                        .font(.system(.callout))
                        .foregroundColor(T.accent)
                        .frame(width: Size.tile, height: Size.tile)
                        .background(RoundedRectangle(cornerRadius: Radius.inner).fill(T.accentSoft))
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text("100% On-Device & Private")
                            .font(T.sans(14, .semibold))
                            .foregroundColor(T.ink)
                        Text("All models run locally. No data leaves this device.")
                            .font(T.sans(11.5))
                            .foregroundColor(T.ink3)
                    }
                    Spacer()
                }
                .padding(Space.m)
                .kGlass(cornerRadius: Radius.card, fallbackFill: T.surface)
                .padding(.horizontal, Space.m)

                // 1. Assistant View Section
                KSection(title: "assistant") {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Interactive Local Chat")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("Engage in direct chats with your chosen reasoning model (e.g. Qwen, Llama). Code blocks are automatically formatted with syntax highlighting.")
                            .font(T.sans(12.5))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)
                        
                        visualImage("img_assistant")
                        
                        bulletPoint("Composer Inputs", "Attach images, documents, or repositories. Access saved snip presets from the toolbar.")
                        bulletPoint("Conversation Search", "Filter local chat histories by keywords in real-time.")
                        bulletPoint("Tool Integrations", "Supports local tool-calling like Web Search, with user approvals.")
                    }
                    .padding(Space.m)
                }

                // 2. Image Generation Section
                KSection(title: "image_generation") {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Local Diffusion Models")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("Create artwork locally using Stable Diffusion or SDXL-Turbo, designed to operate safely within iOS RAM limits.")
                            .font(T.sans(12.5))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)

                        HStack(spacing: Space.s) {
                            visualImage("img_prompting")
                            visualImage("img_generation")
                        }

                        bulletPoint("Model Profiles", "Select specialized profiles like DreamShaper 8 and configure negative prompts.")
                        bulletPoint("Refining Details", "Configure generation steps. Fast models require only 1–4 steps.")
                    }
                    .padding(Space.m)
                }

                // 3. Lens (Camera) Section
                KSection(title: "camera_&_lens") {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Real-Time Code & Vision")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("Use the viewfinder to scan source code from screens or whiteboards, or stream continuous descriptive VLM captions.")
                            .font(T.sans(12.5))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)

                        visualImage("img_lens")

                        bulletPoint("Code Mode (Default)", "Frames and captures code using a high-fidelity OCR pass, sending it directly to the LLM analyzer.")
                        bulletPoint("Visual Mode (VLM)", "Point at anything to generate live text descriptions of objects, screens, or layouts.")
                        bulletPoint("Describe Interval", "Adjust follow-up refresh intervals from 6s to 30s. Manual describes can be triggered at any time.")
                    }
                    .padding(Space.m)
                }

                // 4. Voice Section
                KSection(title: "voice_assistant") {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Hands-Free Conversational Loop")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("Talk directly with models using robust voice activity detection (VAD) that filters out ambient background noise.")
                            .font(T.sans(12.5))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)

                        visualImage("img_voice")

                        bulletPoint("Synchronized Audio", "Uses a single synchronized audio session for seamless transitions between listening and speaking.")
                        bulletPoint("Neural TTS Engines", "Select between system voice synthesis and advanced local voices (KittenTTS, Kokoro).")
                    }
                    .padding(Space.m)
                }

                // 5. Models Hub
                KSection(title: "model_management") {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Unified Model Library")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("The central hub for downloading models, searching HuggingFace, and tracking local disk space usage.")
                            .font(T.sans(12.5))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)

                        bulletPoint("Residency Gates", "Models automatically load and unload dynamically to protect your device from memory-related jetsam kills.")
                        bulletPoint("Disk Management", "Segments total storage sizes per type (Language, Vision, Voice) and allows one-tap cleanups of orphaned files.")
                        bulletPoint("Hugging Face Search", "Find and download any compatible open-source model directly by entering its repository path.")
                    }
                    .padding(Space.m)
                }

                // 6. Mac Bridge Section
                KSection(title: "mac_bridge") {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Desktop Coupling")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("Pair with LocalCoderBridge on your Mac. Scan the desktop QR code to establish secure local connection links.")
                            .font(T.sans(12.5))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)

                        visualImage("img_mac_bridge")

                        bulletPoint("Dual Inference Routing", "Offload complex reasoning tasks from your Mac to your iOS device's Neural Engine.")
                        bulletPoint("Visual Inspection", "Streams Mac screenshots, simulator boundaries, and Xcode logs directly to the iOS visual model.")
                    }
                    .padding(Space.m)
                }
            }
            .padding(.bottom, Space.xl)
        }
        .background(LiquidPinkBackdrop())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private func visualImage(_ name: String) -> some View {
        Image(name)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(T.glassBorder, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 14, y: 3)
    }

    @ViewBuilder
    private func bulletPoint(_ title: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            HStack(spacing: Space.xs) {
                Circle().fill(T.accent).frame(width: 4, height: 4)
                KMono(text: title.uppercased(), size: 10, weight: .semibold, color: T.accent)
            }
            Text(desc)
                .font(T.sans(12))
                .foregroundColor(T.ink3)
                .lineSpacing(2)
                .padding(.leading, Space.s)
        }
    }
}
