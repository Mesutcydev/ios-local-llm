import SwiftUI

/// Recovery keeps the failing model's runtime and selections intact. Alternate
/// models go through the same compatibility and installation flow as discovery.
struct FixRepoSheet: View {
    let model: DownloadableModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSearch = false
    @State private var showToken = false
    @State private var query = ""

    private var filter: HFSearchService.Filter {
        switch model.category {
        case .vlm: return .vlm
        case .assistant: return .textGen
        case .voice: return .all
        case .imageGen: return .all
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(model.displayName) {
                    if case .failed(let message) = model.state {
                        Text(message).textSelection(.enabled)
                    }
                    Text("Retry the same model after resolving the error. Choosing an alternative does not change your active model.")
                    Button("Retry download") { model.start(); dismiss() }
                }
                if model.lastFailureKind == .tokenRequired || model.lastFailureKind == .tokenRejected {
                    Section("Access required") {
                        Text("Check your Hugging Face token and accept the model's terms on its repository page.")
                        Button("Hugging Face token") { showToken = true }
                    }
                }
                Section("Choose an alternative") {
                    Text("Search results show device compatibility and model details before installation. Select the installed model from Models when it is ready.")
                    TextField("Model name or author/repository", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Find compatible models") { showSearch = true }
                }
                Section("Storage and connection") {
                    Text("For disk-space errors, remove an unused model in Models → Storage Cleanup. For connection errors, check your network and Wi-Fi-only download setting, then retry.")
                }
            }
            .navigationTitle("Download recovery")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showSearch) { HFSearchView(initialFilter: filter, initialQuery: query) }
            .sheet(isPresented: $showToken) { HFTokenSheet() }
        }
    }
}
