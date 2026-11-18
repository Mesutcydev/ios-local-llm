#!/usr/bin/env python3
"""Collect verbatim license/notice files from the exact resolved dependencies."""
import argparse
import json
import subprocess
from pathlib import Path


def revision(path):
    return subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-checkouts", required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    pins = json.loads((root / "IOSLocalLLM.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())["pins"]
    folders = {p.name.lower(): p for p in args.package_checkouts.iterdir() if p.is_dir()}
    sections = ["THIRD-PARTY LICENSES AND NOTICES\n\n"
                "Generated from Package.resolved and the source distributions used by this build.\n"
                "Original integrations and adaptations may be modified; their upstream notices follow.\n"
                "Downloaded model weights have their own licenses; selected model notices follow.\n"
                "SDXL Turbo and SD-Turbo: Powered by Stability AI.\n"]

    def append(label, source, path):
        sections.append(f"\n{'=' * 72}\n{label}\nSource: {source}\n{'=' * 72}\n\n"
                        + path.read_text(encoding="utf-8").rstrip() + "\n")

    for pin in pins:
        folder = folders[pin["identity"]]
        expected = pin["state"]["revision"]
        if revision(folder) != expected:
            raise SystemExit(f"Checkout does not match Package.resolved: {pin['identity']}")
        files = sorted(p for p in folder.rglob("*") if p.is_file()
                       and not any(part in {".git", ".build"} for part in p.relative_to(folder).parts)
                       and p.name.upper().startswith(("LICENSE", "NOTICE", "COPYING")))
        if not files:
            raise SystemExit(f"Missing license: {pin['identity']}")
        for path in files:
            label = f"{pin['identity']} {pin['state'].get('version', expected)} — {path.relative_to(folder)}"
            append(label, pin["location"] + " @ " + expected, path)

    local_files = [
        ("Original app code", "LICENSE"),
        ("Liquid AI LFM3 optional model weights", "LICENSES/LFM-Open-License-v1.0.txt"),
        ("Apple Core AI text runtime", "LICENSES/CoreAI-Models-BSD-3-Clause.txt"),
        ("DLPack header in the Core AI grammar bridge", "LICENSES/Apache-2.0.txt"),
        ("Apple FastVLM sample code (model weights excluded)", "LICENSES/Apple-Sample-Code-License.txt"),
        ("ONNX Runtime 1.29.0", "LICENSES/ONNX-Runtime-MIT.txt"),
        ("Silero VAD", "LICENSES/Silero-VAD-MIT.txt"),
        ("GantMan nsfw_model MobileNet v1.1.0 safety classifier", "LICENSES/Image-Safety-Model-MIT.txt"),
        ("TensorFlow Hub MobileNet backbone", "LICENSES/Apache-2.0.txt"),
        ("KittenTTS official 0.8 model license", "LICENSES/Apache-2.0.txt"),
        ("KittenTTS official 0.8 pinned model cards", "LICENSES/KittenTTS-MODEL-CARDS.txt"),
        ("Paradee-8M v1.2 optional voice model (Apache-2.0)", "LICENSES/Apache-2.0.txt"),
        ("Supertonic 3 optional voice model — BigScience Open RAIL-M", "LICENSES/Supertonic-3-OpenRAIL-M.txt"),
        ("SDXL Turbo / SD-Turbo — Stability AI Community License (5 July 2024)", "LICENSES/Stability-AI-Community-License.txt"),
        ("SDXL Turbo / SD-Turbo attribution", "LICENSES/Stability-AI-NOTICE.txt"),
        ("Stable Diffusion source integration", "IOSLocalLLM/Vendor/StableDiffusion/LICENSE"),
        ("CMU Pronouncing Dictionary", "IOSLocalLLM/Resources/Voice/LICENSE"),
        ("thinking-orbs adaptations", "ThirdParty/thinking-orbs/LICENSE"),
    ]
    for label, relative in local_files:
        append(label, relative, root / relative)
    for name in ("llama.cpp", "whisper.cpp"):
        folder = root / "ThirdParty" / name
        append(name, f"https://github.com/ggml-org/{name} @ {revision(folder)}", folder / "LICENSE")

    output = root / "IOSLocalLLM/Resources/ThirdPartyLicenses.txt"
    output.write_text("".join(sections), encoding="utf-8")
    print(f"Wrote {output.relative_to(root)} ({len(sections) - 1} license/notice sections)")


if __name__ == "__main__":
    main()
