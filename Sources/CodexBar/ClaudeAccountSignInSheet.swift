import AppKit
import SwiftUI
import WebKit

struct ClaudeAccountSignInSheet: View {
    let settings: SettingsStore
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model = ClaudeAccountSignInModel()
    @State private var revealVerifiedEmail = false
    @State private var verificationTask: Task<Void, Never>?
    @State private var websiteDataStore = WKWebsiteDataStore.nonPersistent()

    private var isReconnecting: Bool {
        guard let email = self.model.verifiedEmail else { return false }
        return self.settings.tokenAccounts(for: .claude).contains {
            $0.externalIdentifier?.caseInsensitiveCompare(email) == .orderedSame
        }
    }

    private var displayedEmail: String {
        PersonalInfoRedactor.redactEmail(
            self.model.verifiedEmail,
            isEnabled: self.settings.hidePersonalInfo && !self.revealVerifiedEmail)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Claude account").font(.title2.bold())
            if self.model.verifiedEmail != nil {
                HStack {
                    Label("Verified: \(self.displayedEmail)", systemImage: "checkmark.seal")
                    if self.settings.hidePersonalInfo {
                        Button(self.revealVerifiedEmail ? "Hide email" : "Show email") {
                            self.revealVerifiedEmail.toggle()
                        }
                        .buttonStyle(.link)
                    }
                }
                TextField("Nickname (for example, Personal or Business)", text: self.$model.nickname)
                Text(self.isReconnecting
                    ? "This account is already saved. Reconnect to replace its expired session."
                    : "Midas will use this account to read Claude usage.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                Text("Sign in below, then click Continue to verify the account. Each account signs in separately.")
                    .foregroundStyle(.secondary)
                ClaudeAccountSignInWebView(websiteDataStore: self.websiteDataStore)
                    .frame(minHeight: 440)
                Text("If your sign-in method blocks this window, cancel and use Paste session key instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notice = self.model.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") {
                    self.model.clearVerification()
                    self.dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if self.model.isVerifying {
                    ProgressView().controlSize(.small)
                }
                if self.model.verifiedEmail != nil {
                    Button(self.isReconnecting ? "Reconnect account" : "Save account") {
                        if self.model.save(to: self.settings) {
                            self.onSaved()
                            self.dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") {
                        self.verificationTask = Task { @MainActor in
                            let cookies = await self.websiteDataStore.httpCookieStore.allCookies()
                            await self.model.verify(cookieHeader: ClaudeAccountSignInModel.sessionHeader(from: cookies))
                        }
                    }
                    .disabled(self.model.isVerifying)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
        .onDisappear {
            self.verificationTask?.cancel()
            self.model.clearVerification()
        }
    }
}

private struct ClaudeAccountSignInWebView: NSViewRepresentable {
    let websiteDataStore: WKWebsiteDataStore

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = self.websiteDataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if let url = URL(string: "https://claude.ai/login") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void)
        {
            decisionHandler(navigationAction.request.url?.scheme?.lowercased() == "https" ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures) -> WKWebView?
        {
            if navigationAction.request.url?.scheme?.lowercased() == "https" {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
