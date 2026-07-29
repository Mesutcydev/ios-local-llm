import Foundation

// MARK: - FastVLMTask
// The high-level task that determines the system + user prompt sent to the model.

enum FastVLMTask: Equatable {
    case extractCode
    case reviewCode
    case describeImage
    case answerQuestion(String)
}

// MARK: - FastVLMPromptBuilder
// Builds the full chat-formatted prompt string for each task type.
//
// Qwen2 chat template:
//   <|im_start|>system\n{system}<|im_end|>\n
//   <|im_start|>user\n{user}<|im_end|>\n
//   <|im_start|>assistant\n
//
// The <image> token is inserted in the user turn where the image should be processed.
// For LlavaQwen2, image token positions get replaced with projected vision features
// before running the decoder.

struct FastVLMPromptBuilder {

    // MARK: - Build prompt

    /// Returns the full formatted prompt string for the given task.
    /// Includes the Qwen2 chat template with <image> token placeholder.
    static func buildPrompt(for task: FastVLMTask) -> String {
        let (system, user) = promptParts(for: task)
        return formatChatTemplate(system: system, user: user)
    }

    // MARK: - Chat template formatter

    static func formatChatTemplate(system: String, user: String) -> String {
        let s = FastVLMConfig.imStartToken
        let e = FastVLMConfig.imEndToken
        return "\(s)system\n\(system)\(e)\n\(s)user\n\(user)\(e)\n\(s)assistant\n"
    }

    // MARK: - Task-specific prompts

    /// Returns (system, user) prompt parts for the given task.
    /// The user string includes a `<image>` token prefix that should be stripped
    /// when passing directly as `UserInput.chat` messages (FastVLMProcessor adds tokens itself).
    static func promptParts(for task: FastVLMTask) -> (system: String, user: String) {
        switch task {

        case .extractCode:
            return (
                system: "You are an expert code extraction assistant. " +
                        "Given an image of code on a screen or whiteboard, " +
                        "extract the code exactly as shown. " +
                        "Output ONLY the code without any explanation or markdown formatting.",
                user:   "\(FastVLMConfig.imageToken)\nExtract all code visible in this image. " +
                        "Output only the raw code, preserving indentation and structure."
            )

        case .reviewCode:
            return (
                system: "You are an expert software engineer performing code review. " +
                        "Analyze the code in the image and provide a concise review " +
                        "covering: bugs, style issues, performance, and suggestions for improvement. " +
                        "Use markdown formatting with bullet points.",
                user:   "\(FastVLMConfig.imageToken)\nReview this code. " +
                        "Identify any bugs, issues, or improvements. " +
                        "Format your response with markdown."
            )

        case .describeImage:
            return (
                system: "You are a helpful assistant that describes images accurately and concisely.",
                user:   "\(FastVLMConfig.imageToken)\nDescribe what you see in this image in detail."
            )

        case .answerQuestion(let question):
            return (
                system: "You are a helpful assistant that answers questions about images. " +
                        "Be concise and accurate.",
                user:   "\(FastVLMConfig.imageToken)\n\(question)"
            )
        }
    }

    // MARK: - Token counting estimate

    /// Rough estimate of prompt length in tokens (prompt text + image patches).
    /// Image contributes ~256 tokens (one per patch from FastViT-HD).
    static func estimatedPromptTokens(for task: FastVLMTask) -> Int {
        let (system, user) = promptParts(for: task)
        let promptChars = system.count + user.count
        let textTokens = promptChars / 4   // ~4 chars per token heuristic
        let imageTokens = FastVLMConfig.encoderNumPatches   // 256
        return textTokens + imageTokens
    }
}
