import CodexBarCore

@MainActor
extension StatusItemController {
    func runGeminiLoginFlow() async {
        if AntigravityOAuthConfig.resolvedClient() != nil {
            await self.runGeminiGoogleOAuthLoginFlow()
            return
        }
        let store = self.store
        let result = await GeminiLoginRunner.run {
            Task { @MainActor in
                await store.refresh()
                CodexBarLog.logger(LogCategories.login).info("Auto-refreshed after Gemini auth")
            }
        }
        guard !Task.isCancelled else { return }
        self.loginPhase = .idle
        self.presentGeminiLoginResult(result)
        let outcome = self.describe(result.outcome)
        self.loginLogger.info("Gemini login", metadata: ["outcome": outcome])
    }

    private func runGeminiGoogleOAuthLoginFlow() async {
        let store = self.store
        let credentialsStore = GeminiOAuthCredentialsStore.store()
        let phaseHandler: @Sendable (AntigravityLoginRunner.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in
                switch phase {
                case .waitingBrowser:
                    self?.loginPhase = .waitingBrowser
                }
            }
        }
        let result = await AntigravityLoginRunner.run(
            credentialsStore: credentialsStore,
            onPhaseChange: phaseHandler)
        {
            Task { @MainActor in
                if let credentials = try? credentialsStore.load() {
                    self.store.settings.upsertGeminiOAuthAccount(credentials)
                }
                await store.refresh()
                CodexBarLog.logger(LogCategories.login).info("Auto-refreshed after Gemini Google OAuth")
            }
        }
        guard !Task.isCancelled else { return }
        self.loginPhase = .idle
        self.presentAntigravityLoginResult(result)
        let outcome = self.describe(result.outcome)
        self.loginLogger.info("Gemini Google OAuth login", metadata: ["outcome": outcome])
        if case .success = result.outcome {
            self.postLoginNotification(for: .gemini)
        }
    }
}
