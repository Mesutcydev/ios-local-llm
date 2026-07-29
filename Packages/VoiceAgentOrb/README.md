# VoiceAgentOrb

A reusable SwiftUI and Metal voice-state visualization extracted from the
iOS Local LLM project.

## Requirements

- Swift 6
- iOS 18, macOS 15, Mac Catalyst 18, tvOS 18, or visionOS 2

## Test

```bash
swift test
```

The public entry point is `VoiceAgentOrb`. Rendering, accessibility,
performance policy, state, and audio-energy mapping are separate source files
so adopters can replace individual layers.

## License

VoiceAgentOrb is MIT-licensed. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
