import CodexBarCore

struct LocalInferenceProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .localInference

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "private runtime counters" }
    }
}
