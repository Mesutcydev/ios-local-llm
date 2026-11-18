#!/usr/bin/env python3
"""Check release identity/privacy consistency, optionally against a built app.

This is a local preflight. Apple signing, account capabilities, and App Review
still require a signed archive and App Store Connect validation.
"""
import argparse
from datetime import datetime, timezone
import json
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP_ID = "com.codelens.CodeLens"
GROUP_ID = "group.com.codelens.shared"
CLOUD_ID = "iCloud.com.codelens"


def require(condition, message):
    if not condition:
        raise SystemExit(f"error: {message}")


def plist(path):
    with path.open("rb") as stream:
        return plistlib.load(stream)


def check_info(app, extension, version, build=None):
    require(app["CFBundleShortVersionString"] == version, "app marketing version differs")
    require(extension["CFBundleShortVersionString"] == version, "extension marketing version differs")
    require(app["CFBundleVersion"] == extension["CFBundleVersion"], "app/extension builds differ")
    if build is not None:
        require(app["CFBundleVersion"] == build, "built app version differs from project.yml")
        require(app["CFBundleIdentifier"] == APP_ID, "built app has the wrong App Store identity")
        require(extension["CFBundleIdentifier"] == APP_ID + ".share", "built extension identity differs")
    schemes = {scheme for item in app["CFBundleURLTypes"] for scheme in item["CFBundleURLSchemes"]}
    require({"codelens", "ios-local-llm"} <= schemes, "legacy or current share scheme is missing")
    require("_localllm._tcp" in app.get("NSBonjourServices", []), "Mac Bridge Bonjour service is undeclared")
    require(app.get("ITSAppUsesNonExemptEncryption") is False, "review encryption declaration")
    require(not app.get("NSAppTransportSecurity", {}).get("NSAllowsArbitraryLoads"), "ATS is globally disabled")
    for key in ("NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription", "NSLocalNetworkUsageDescription"):
        require(bool(app.get(key)), f"{key} is missing")
    require(extension["NSExtension"]["NSExtensionAttributes"]["NSExtensionActivationRule"] != "TRUEPREDICATE", "extension has a development-only activation rule")


def check_manifest(path, expected_categories):
    manifest = plist(path)
    require(manifest.get("NSPrivacyTracking") is False, f"unexpected tracking declaration: {path}")
    categories = {entry["NSPrivacyAccessedAPIType"]: entry["NSPrivacyAccessedAPITypeReasons"]
                  for entry in manifest.get("NSPrivacyAccessedAPITypes", [])}
    for category, reason in expected_categories.items():
        require(reason in categories.get(category, []), f"{path}: missing reason {reason} for {category}")


def check_distribution(bundle, team, is_extension=False):
    """Inspect public signing metadata; never export a private key."""
    verified = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)],
                              capture_output=True)
    require(verified.returncode == 0, f"invalid signature: {bundle.name}")
    displayed = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)],
                               capture_output=True)
    require(displayed.returncode == 0 and bool(displayed.stdout),
            f"missing signed entitlements: {bundle.name}")
    entitlements = plistlib.loads(displayed.stdout)
    identifier = APP_ID + (".share" if is_extension else "")
    require(entitlements.get("application-identifier") == team + "." + identifier,
            f"signed application identifier differs: {bundle.name}")
    require(entitlements.get("com.apple.developer.team-identifier") == team,
            f"signed team differs: {bundle.name}")
    require(entitlements.get("get-task-allow") is not True,
            f"debugger entitlement enabled: {bundle.name}")
    require(entitlements.get("com.apple.security.application-groups") == [GROUP_ID],
            f"signed App Group differs: {bundle.name}")
    require("com.apple.developer.private-cloud-compute" not in entitlements,
            "managed PCC enabled in standard distribution")
    if not is_extension:
        require(entitlements.get("com.apple.developer.icloud-container-identifiers") == [CLOUD_ID],
                "signed CloudKit container differs")
        require(entitlements.get("com.apple.developer.icloud-container-environment") == "Production",
                "distribution CloudKit environment is not Production")
        for capability in ("increased-memory-limit", "extended-virtual-addressing"):
            require(entitlements.get("com.apple.developer.kernel." + capability) is True,
                    f"signed memory capability missing: {capability}")

    profile_path = bundle / "embedded.mobileprovision"
    require(profile_path.is_file(), f"missing distribution profile: {bundle.name}")
    decoded = subprocess.run(["security", "cms", "-D", "-i", str(profile_path)], capture_output=True)
    require(decoded.returncode == 0, f"profile could not be decoded: {bundle.name}")
    profile = plistlib.loads(decoded.stdout)
    require(profile.get("TeamIdentifier") == [team], f"profile team differs: {bundle.name}")
    require(not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices"),
            f"profile is not for App Store distribution: {bundle.name}")
    require(profile["ExpirationDate"] > datetime.now(timezone.utc).replace(tzinfo=None),
            f"profile expired: {bundle.name}")
    granted = profile["Entitlements"]
    require(granted.get("application-identifier") == team + "." + identifier,
            f"profile application identifier differs: {bundle.name}")
    require(granted.get("get-task-allow") is False, f"profile permits debugging: {bundle.name}")
    require(GROUP_ID in granted.get("com.apple.security.application-groups", []),
            f"profile does not grant the shared App Group: {bundle.name}")
    if not is_extension:
        require(CLOUD_ID in granted.get("com.apple.developer.icloud-container-identifiers", []),
                "profile does not grant the historical CloudKit container")
        for capability in ("increased-memory-limit", "extended-virtual-addressing"):
            require(granted.get("com.apple.developer.kernel." + capability) is True,
                    f"profile does not grant memory capability: {capability}")
    with tempfile.TemporaryDirectory(prefix="ondevice-signature-") as directory:
        prefix = Path(directory) / "signer"
        extracted = subprocess.run(["codesign", "-d", f"--extract-certificates={prefix}", str(bundle)],
                                   capture_output=True)
        require(extracted.returncode == 0 and Path(str(prefix) + "0").is_file(),
                f"distribution signing certificate missing: {bundle.name}")
        require(Path(str(prefix) + "0").read_bytes() in profile["DeveloperCertificates"],
                f"signing certificate differs from profile: {bundle.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="built IOSLocalLLM.app or archive Products/Applications/IOSLocalLLM.app")
    parser.add_argument("--distribution-team", help="also verify App Store signing/profile metadata for this team (macOS)")
    args = parser.parse_args()
    require(not args.distribution_team or args.app, "distribution validation requires --app")
    project = (ROOT / "project.yml").read_text()
    require(set(re.findall(r"(?m)^\s*PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)", project)) ==
            {APP_ID, APP_ID + ".share", APP_ID + "Tests", APP_ID + "UITests"}, "project target identities differ")
    versions = set(re.findall(r'CFBundleShortVersionString:\s*"([^"]+)"', project))
    builds = set(re.findall(r'CURRENT_PROJECT_VERSION:\s*"([^"]+)"', project))
    require(len(versions) == 1 and len(builds) == 1, "project versions/builds are inconsistent")
    version, build = versions.pop(), builds.pop()
    require(tuple(map(int, version.split("."))) > (3, 2, 4), "candidate must be newer than live version 3.2.4")
    # Both entry points need the same override: CocoaPods builds open the
    # outer workspace rather than the generated project's internal workspace.
    for workspace in ("IOSLocalLLM.xcworkspace", "IOSLocalLLM.xcodeproj/project.xcworkspace"):
        mirror_path = ROOT / workspace / "xcshareddata/swiftpm/configuration/mirrors.json"
        mirrors = {entry["original"]: entry["mirror"]
                   for entry in json.loads(mirror_path.read_text())["object"]}
        for original in ("https://github.com/ml-explore/mlx-swift", "https://github.com/ml-explore/mlx-swift.git"):
            require(mirrors.get(original) == "https://github.com/PrismML-Eng/mlx-swift.git",
                    f"{workspace}: one-bit MLX fork mapping is missing")
    for name in ("IOSLocalLLM.entitlements", "IOSLocalLLM-PCC.entitlements", "IOSLocalLLM-Catalyst.entitlements"):
        entitlement = plist(ROOT / "IOSLocalLLM" / name)
        require(entitlement["com.apple.security.application-groups"] == [GROUP_ID], f"{name}: App Group changed")
        require(entitlement["com.apple.developer.icloud-container-identifiers"] == [CLOUD_ID], f"{name}: CloudKit identity changed")
    standard = plist(ROOT / "IOSLocalLLM/IOSLocalLLM.entitlements")
    require("com.apple.developer.private-cloud-compute" not in standard, "managed PCC capability enabled in standard build")
    share = plist(ROOT / "IOSLocalLLMShareExtension/IOSLocalLLMShareExtension.entitlements")
    require(share["com.apple.security.application-groups"] == [GROUP_ID], "extension App Group differs")
    for file, value in (("IOSLocalLLM/Models/AppBridge.swift", GROUP_ID),
                        ("IOSLocalLLMShareExtension/ShareViewController.swift", GROUP_ID),
                        ("IOSLocalLLM/Services/CloudSyncService.swift", CLOUD_ID)):
        require(value in (ROOT / file).read_text(), f"{file}: runtime identity differs from entitlements")
    # These names locate existing users' credentials, preferences and crash
    # recovery markers. They are independent of the displayed product name.
    for file, value in (
        ("Services/HFTokenStore.swift", "com.codelens.huggingface"),
        ("Services/Web/KeychainStore.swift", "com.codelens.webtool"),
        ("Services/Bridge/BridgePairingStore.swift", "com.codelens.bridge.pairings"),
        ("Services/Bridge/BridgeIdentity.swift", "com.codelens.bridge.privkey"),
        ("Services/BackgroundDownloadCoordinator.swift", "com.codelens.background-downloads"),
        ("Services/Voice/VoiceProfileRegistry.swift", "com.codelens.voice.profile."),
        ("Services/Web/WebToolService.swift", "codelens.webtool.settings.v1"),
        ("Services/MacroChain.swift", "codelens.macros.v1"),
        ("Services/ImageGenerationService.swift", "codelensImgGenInFlight"),
    ):
        require(value in (ROOT / "IOSLocalLLM" / file).read_text(), f"{file}: legacy persistence namespace changed")
    require("APPLICATION_EXTENSION_API_ONLY: YES" in project, "extension API checking is disabled")
    require(not (ROOT / "IOSLocalLLM/Services/ReviewPromptService.swift").exists(),
            "old custom sentiment-gated review prompt must not return")
    swift_sources = [p.read_text() for p in (ROOT / "IOSLocalLLM").rglob("*.swift")]
    require(not any("allowUnsafeMemoryLoad" in source for source in swift_sources),
            "memory-admission bypass must not return")
    extension_source = (ROOT / "IOSLocalLLMShareExtension/ShareViewController.swift").read_text()
    require("UIApplication" not in extension_source and "performSelector" not in extension_source,
            "share extension accesses unavailable application APIs")
    app_root = args.app or ROOT / "IOSLocalLLM"
    extension_root = (app_root / "PlugIns/IOSLocalLLMShareExtension.appex") if args.app else ROOT / "IOSLocalLLMShareExtension"
    check_info(plist(app_root / "Info.plist"), plist(extension_root / "Info.plist"), version, build if args.app else None)
    check_manifest(app_root / "PrivacyInfo.xcprivacy", {
        "NSPrivacyAccessedAPICategoryUserDefaults": "CA92.1",
        "NSPrivacyAccessedAPICategoryFileTimestamp": "C617.1",
        "NSPrivacyAccessedAPICategoryDiskSpace": "E174.1",
        "NSPrivacyAccessedAPICategorySystemBootTime": "35F9.1",
    })
    check_manifest(extension_root / "PrivacyInfo.xcprivacy", {"NSPrivacyAccessedAPICategoryFileTimestamp": "C617.1"})
    if args.app:
        require((app_root / "GeneratedImageSafety.mlmodelc").is_dir(),
                "local image safety classifier is missing from the built app")
        require((app_root / "ThirdPartyLicenses.txt").is_file(), "bundled dependency licenses are missing")
        restricted = [p.relative_to(app_root) for p in app_root.rglob("*")
                      if "fastvlm" in p.name.lower() or "fastvithd" in p.name.lower()]
        require(not restricted, f"research model artifacts are bundled: {restricted}")
        if args.distribution_team:
            check_distribution(app_root, args.distribution_team)
            check_distribution(extension_root, args.distribution_team, is_extension=True)
            print("Distribution signatures, profiles, production CloudKit and memory entitlements verified")
    print(f"App Store preflight passed: {version} ({build}), {APP_ID}" + ("; built bundles verified" if args.app else "; source configuration verified"))


if __name__ == "__main__":
    main()
