# Xcode Project Setup

This directory shows where the `.xcodeproj` bundle belongs.
Since `.xcodeproj` is a binary XML bundle, create it manually in Xcode:

## Steps

1. **Open Xcode** → File → New → Project
2. Choose **iOS → App**
3. Fill in:
   - Product Name: `IOSLocalLLM`
   - Bundle ID: `com.yourname.IOSLocalLLM`
   - Interface: **SwiftUI**
   - Language: **Swift**
4. **Save to this folder** (`/IOSLocalLLM/`)
5. Xcode creates `IOSLocalLLM.xcodeproj` here automatically.

## Add Source Files

After project creation, add all `.swift` files from `IOSLocalLLM/` to the target:
- File → Add Files to "IOSLocalLLM"…
- Select all `.swift` files and subfolders
- Check "Copy items if needed" → Add to target `IOSLocalLLM`

## Add ML Models

Drag into Xcode project navigator (under `IOSLocalLLM/Models/`):
- `yolo11n.mlpackage`
- `FastVLMEncoder.mlpackage`
- `FastVLMDecoder.mlpackage`
- `tokenizer.json`
- `tokenizer_config.json`

Check **"Add to target: IOSLocalLLM"** for each.

## Deployment Target

Target → General → Minimum Deployments: **iOS 18.0**

See `SETUP_INSTRUCTIONS.md` (root) for full model download instructions.
