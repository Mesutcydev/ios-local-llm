import SwiftUI

struct ImageParentalControlsView: View {
    @ObservedObject private var loc = LocalizationService.shared
    @State private var controls = ImageGenerationParentalControls.shared
    @State private var pin = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Image generation parental controls".tr, systemImage: "lock.shield")
                .font(.headline)
            Text("A parent or guardian can restrict image generation with a separate PIN. Keep this PIN private. Access locks again when the app backgrounds.".tr)
                .font(.footnote)
            if controls.isRestricted {
                if controls.isSessionUnlocked {
                    Button("Lock image generation now".tr) {
                        controls.lock()
                        ImageGenerationService.shared.clearForParentalLock()
                    }
                    Button("Remove parental restriction".tr, role: .destructive) {
                        _ = controls.removeRestriction()
                    }
                } else {
                    SecureField("Parental PIN".tr, text: $pin, prompt: Text("PIN"))
                        .textContentType(.password)
                        .keyboardType(.numberPad)
                        .frame(minHeight: 44)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("imageParentalPIN")
                    Button("Unlock image generation".tr) {
                        _ = controls.unlock(pin: pin)
                        pin = ""
                    }
                    .accessibilityIdentifier("imageParentalUnlock")
                }
            } else {
                Text("New parental PIN (6–12 digits)".tr)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("New parental PIN (6–12 digits)".tr, text: $pin, prompt: Text("PIN"))
                    .textContentType(.newPassword)
                    .keyboardType(.numberPad)
                    .frame(minHeight: 44)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("imageParentalNewPIN")
                Text("Confirm parental PIN".tr)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Confirm parental PIN".tr, text: $confirmation, prompt: Text("PIN"))
                    .textContentType(.newPassword)
                    .keyboardType(.numberPad)
                    .frame(minHeight: 44)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("imageParentalConfirmPIN")
                Button("Restrict image generation".tr) {
                    if controls.setPIN(pin, confirmation: confirmation) {
                        ImageGenerationService.shared.clearForParentalLock()
                    }
                    pin = ""
                    confirmation = ""
                }
                .accessibilityIdentifier("imageParentalRestrict")
            }
            if let error = controls.lastError {
                Text(error.tr).foregroundStyle(.red).font(.footnote)
            }
            Text("This feature lock does not verify age or replace content safeguards. Use Screen Time to restrict access to the entire app.".tr)
                .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.kSecondary)
        .padding()
    }
}
