import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var syncState: SyncState
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("hkb.onboardingComplete") private var onboardingComplete = false

    @State private var step = 0

    var body: some View {
        TabView(selection: $step) {
            WelcomeStep(onNext: { step = 1 })
                .tag(0)
            PrivacyStep(onNext: { step = 2 })
                .tag(1)
            HostedSetupStep(onNext: { step = 3 })
                .tag(2)
            HealthKitStep(onDone: { onboardingComplete = true })
                .tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .animation(.easeInOut, value: step)
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 80))
                .foregroundStyle(.pink)
            VStack(spacing: 12) {
                Text("Your health data.\nAny AI. Your rules.")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("No export files. No middleman. health4ai syncs live from HealthKit — ready for any AI you trust, local or cloud.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Spacer()
            Button(action: onNext) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.pink)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }
}

// MARK: - Step 2: Privacy

private struct PrivacyStep: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            VStack(spacing: 12) {
                Text("Privacy by design")
                    .font(.largeTitle.bold())
                Text("Your health data travels in one direction: from your device to your backend. No export files. No cloud intermediaries.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            VStack(alignment: .leading, spacing: 16) {
                DataFlowRow(icon: "iphone", label: "Your iPhone", color: .primary)
                HStack {
                    Rectangle()
                        .fill(Color.green.opacity(0.4))
                        .frame(width: 2, height: 20)
                        .padding(.leading, 19)
                    Image(systemName: "arrow.down")
                        .foregroundStyle(.green)
                        .padding(.leading, 8)
                }
                DataFlowRow(icon: "server.rack", label: "Your backend only", color: .green)
            }
            .padding(.horizontal, 48)
            VStack(alignment: .leading, spacing: 10) {
                PrivacyBullet(text: "No export files — ever")
                PrivacyBullet(text: "No third-party servers")
                PrivacyBullet(text: "No analytics or crash reporting")
                PrivacyBullet(text: "Open source — audit every line")
                PrivacyBullet(text: "App Store privacy label: Data Not Collected")
            }
            .padding(.horizontal, 32)
            Spacer()
            Button(action: onNext) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.pink)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }
}

private struct DataFlowRow: View {
    let icon: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36)
            Text(label)
                .font(.headline)
                .foregroundStyle(color)
        }
    }
}

private struct PrivacyBullet: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.subheadline)
        }
    }
}

// MARK: - Step 3: Hosted Setup (setup-code flow)

private struct HostedSetupStep: View {
    @EnvironmentObject var syncState: SyncState
    @EnvironmentObject var authManager: AuthManager
    let onNext: () -> Void

    enum SetupPhase {
        case choosingMode     // hosted vs self-hosted
        case fetchingCode     // loading setup code
        case showingCode(String, Date)   // (code, expiresAt)
        case pastingToken     // user has been to AI, now pasting sync token
        case validating       // checking the token
        case connected        // success
        case error(String)
    }

    @State private var phase: SetupPhase = .choosingMode
    @State private var pastedToken: String = ""
    @State private var codeRefreshID = UUID()  // forces code refresh

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Connect to your AI")
                    .font(.largeTitle.bold())
                    .padding(.top, 60)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .center)

                switch phase {
                case .choosingMode:
                    choosingModeView
                case .fetchingCode:
                    fetchingView
                case .showingCode(let code, let exp):
                    showingCodeView(code: code, expiresAt: exp)
                case .pastingToken:
                    pastingTokenView
                case .validating:
                    validatingView
                case .connected:
                    connectedView
                case .error(let msg):
                    errorView(msg)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Mode picker

    private var choosingModeView: some View {
        VStack(spacing: 20) {
            Text("How do you want to store your health data?")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 24)

            VStack(spacing: 12) {
                ModeCard(
                    icon: "sparkles",
                    title: "health4.ai cloud",
                    subtitle: "Zero config. Your AI sets it up in 30 seconds.",
                    recommended: true,
                    action: { fetchSetupCode() }
                )
                ModeCard(
                    icon: "server.rack",
                    title: "Self-hosted",
                    subtitle: "Your own Supabase or any REST endpoint.",
                    recommended: false,
                    action: {
                        syncState.connectionType = .supabase
                        onNext()
                    }
                )
            }
            .padding(.top, 8)
        }
    }

    private struct ModeCard: View {
        let icon: String
        let title: String
        let subtitle: String
        let recommended: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 16) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(recommended ? .pink : .secondary)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(title).font(.headline)
                            if recommended {
                                Text("Recommended")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.pink.opacity(0.15))
                                    .foregroundStyle(.pink)
                                    .clipShape(Capsule())
                            }
                        }
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(recommended ? Color.pink.opacity(0.4) : Color.clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Fetching code

    private var fetchingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.4)
                .padding(.top, 60)
            Text("Generating your setup code…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Showing code

    private func showingCodeView(code: String, expiresAt: Date) -> some View {
        VStack(spacing: 28) {
            Text("Take this code to your AI")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 20)

            // Big code display
            VStack(spacing: 8) {
                Text(code)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundStyle(.pink)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                    .background(Color(UIColor.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                CountdownView(expiresAt: expiresAt) {
                    fetchSetupCode() // expired — auto-refresh
                }
            }

            // Copyable prompt
            VStack(alignment: .leading, spacing: 10) {
                Text("Say this to Claude (or any MCP-enabled AI):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CopyablePrompt(code: code)
            }

            Button(action: { phase = .pastingToken }) {
                Text("I've done it — paste my sync token →")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.pink)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            Button(action: fetchSetupCode) {
                Text("Generate a new code")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Pasting token

    private var pastingTokenView: some View {
        VStack(spacing: 24) {
            Text("Paste the sync token your AI gave you")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 20)

            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 48))
                .foregroundStyle(.pink)

            VStack(alignment: .leading, spacing: 8) {
                Text("Sync token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("h4_sk_…", text: $pastedToken, axis: .vertical)
                    .font(.system(.caption, design: .monospaced))
                    .padding(12)
                    .background(Color(UIColor.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(3)
            }

            Button(action: validateToken) {
                Text("Verify & Connect")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(pastedToken.hasPrefix("h4_sk_") ? Color.pink : Color.secondary)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!pastedToken.hasPrefix("h4_sk_"))

            Button(action: { phase = .choosingMode }) {
                Text("Start over")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Validating

    private var validatingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.4)
                .padding(.top, 60)
            Text("Verifying your connection…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Connected

    private var connectedView: some View {
        VStack(spacing: 28) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .padding(.top, 40)
            Text("Connected!")
                .font(.largeTitle.bold())
            Text("Your health data table is ready. One last step: grant HealthKit access so syncing can begin.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            Button(action: onNext) {
                Text("Grant Health Access →")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.pink)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
                .padding(.top, 40)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: { phase = .choosingMode }) {
                Text("Try again")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.pink)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - Actions

    private func fetchSetupCode() {
        phase = .fetchingCode
        Task {
            guard let url = URL(string: "\(SyncState.hostedAPIBase)/setup") else {
                phase = .error("Invalid API URL"); return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    phase = .error("Setup service unavailable. Try again."); return
                }
                let body = try JSONDecoder().decode(SetupCodeResponse.self, from: data)
                let exp  = ISO8601DateFormatter().date(from: body.expires_at) ?? Date().addingTimeInterval(1800)
                await MainActor.run { phase = .showingCode(body.code, exp) }
            } catch {
                await MainActor.run { phase = .error(error.localizedDescription) }
            }
        }
    }

    private func validateToken() {
        let token = pastedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("h4_sk_") else { return }
        phase = .validating
        Task {
            guard let url = URL(string: "\(SyncState.hostedAPIBase)/validate?token=\(token)") else {
                phase = .error("Invalid URL"); return
            }
            do {
                let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url))
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    phase = .error("Token not recognized. Go back to your AI and ask for the sync token again."); return
                }
                let body = try JSONDecoder().decode(ValidateResponse.self, from: data)
                guard body.valid else {
                    phase = .error("Token not recognized. Go back to your AI and ask for the sync token again."); return
                }
                try authManager.saveHostedSyncToken(token)
                await MainActor.run {
                    syncState.connectionType = .hosted
                    syncState.isAuthenticated = true
                    phase = .connected
                }
            } catch {
                await MainActor.run { phase = .error(error.localizedDescription) }
            }
        }
    }
}

// MARK: - Countdown Timer

private struct CountdownView: View {
    let expiresAt: Date
    let onExpired: () -> Void
    @State private var remaining: TimeInterval = 0

    var body: some View {
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        Text("Expires in \(String(format: "%d:%02d", mins, secs))")
            .font(.caption)
            .foregroundStyle(remaining < 120 ? .orange : .secondary)
            .onAppear { tick() }
    }

    private func tick() {
        remaining = expiresAt.timeIntervalSinceNow
        if remaining <= 0 { onExpired(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick() }
    }
}

// MARK: - Copyable Prompt

private struct CopyablePrompt: View {
    let code: String
    @State private var copied = false

    private var promptText: String {
        "I just downloaded health4.ai. Please set up my health data table. My setup code is: \(code)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(promptText)
                .font(.system(.caption, design: .serif))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = promptText
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .pink)
                    .font(.caption)
            }
        }
        .padding(12)
        .background(Color(UIColor.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Step 4: HealthKit

private struct HealthKitStep: View {
    @EnvironmentObject var syncState: SyncState
    @EnvironmentObject var authManager: AuthManager
    let onDone: () -> Void

    @State private var isRequesting = false
    @State private var granted = false
    @State private var error: String? = nil

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "heart.text.clipboard.fill")
                .font(.system(size: 64))
                .foregroundStyle(.pink)
            VStack(spacing: 12) {
                Text("Grant Health access")
                    .font(.largeTitle.bold())
                Text("health4ai needs read access to sync your data. You control which types are shared.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            if granted {
                Label("Access granted", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 24)
            }
            Spacer()
            VStack(spacing: 12) {
                if !granted {
                    Button(action: requestAccess) {
                        HStack {
                            if isRequesting { ProgressView().scaleEffect(0.8) }
                            Text(isRequesting ? "Requesting…" : "Allow Health Access")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.pink)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(isRequesting)
                    .padding(.horizontal, 32)
                }
                Button(action: onDone) {
                    Text(granted ? "Start Syncing" : "Skip for now")
                        .font(.subheadline)
                        .foregroundStyle(granted ? .pink : .secondary)
                }
                .padding(.bottom, 48)
            }
        }
    }

    private func requestAccess() {
        isRequesting = true
        Task {
            do {
                try await HealthKitManager.shared.requestAuthorization()
                await MainActor.run {
                    isRequesting = false
                    granted = true
                }
            } catch {
                await MainActor.run {
                    isRequesting = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Response types

private struct SetupCodeResponse: Decodable {
    let code: String
    let expires_at: String
}

private struct ValidateResponse: Decodable {
    let valid: Bool
}
