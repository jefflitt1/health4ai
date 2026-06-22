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
            HealthKitStep(onDone: { onboardingComplete = true })
                .tag(2)
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

// MARK: - Step 3: HealthKit

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


