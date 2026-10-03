import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var syncState: SyncState
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("hkb.onboardingComplete") private var onboardingComplete = false

    @State private var step = Self.initialStep

    /// Design-gate screenshots only: simctl cannot swipe between pages, so
    /// `-h4aiOnboardingStep N` opens on page N. Release always starts at 0.
    private static var initialStep: Int {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-h4aiOnboardingStep"), i + 1 < args.count,
           let n = Int(args[i + 1]) {
            return n
        }
        #endif
        return 0
    }

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
                // Says up front what the app needs. Onboarding used to run three screens
                // without once saying it, then land the user on Home reading "Not
                // connected" with nothing pointing anywhere. Since 1.0.1 the default is a
                // Google Sheet, which needs only a Google account; the database is the
                // technical option.
                Text("Save your Apple Health data to a Google Sheet in your own Drive, then ask any AI about it. Prefer a database? You can sync to one you run instead.")
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
            .padding(.bottom, 4)
        }
        .scrollsWhenTall()
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
                    .multilineTextAlignment(.center)
                Text("Your health data goes from your device to the Google Sheet or database you choose. health4ai does not run a shared health-data server.")
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
                DataFlowRow(icon: "externaldrive", label: "Your Drive or database only", color: .green)
            }
            .padding(.horizontal, 48)
            VStack(alignment: .leading, spacing: 10) {
                PrivacyBullet(text: "No Health export files to manage")
                PrivacyBullet(text: "Your own Google Drive or database")
                PrivacyBullet(text: "No analytics or crash reporting")
                PrivacyBullet(text: "Open source: audit every line")
                PrivacyBullet(text: "You choose whether an AI runs locally or in the cloud")
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
            .padding(.bottom, 4)
        }
        .scrollsWhenTall()
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
    @State private var scope: HealthKitManager.DataScope = .essentials
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "heart.text.clipboard.fill")
                .font(.system(size: 64))
                .foregroundStyle(.pink)
            VStack(spacing: 12) {
                Text("Grant Health access")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Start with the minimum data needed for useful activity, sleep, and recovery insights. You can choose a broader scope explicitly.")
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
            // A menu Picker's button never grows vertically, so at accessibility sizes its
            // value clipped mid-word; a Menu with a wrapping label does grow (same fix as
            // Home's Data scope, Sasha build 59 gate).
            if dynamicTypeSize.isAccessibilitySize {
                Menu {
                    scopePicker
                } label: {
                    Label {
                        Text(scope.title)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .labelStyle(TrailingIconLabelStyle())
                }
                .accessibilityLabel("Health data")
                .accessibilityValue(scope.title)
                .disabled(isRequesting)
                .padding(.horizontal, 24)
            } else {
                scopePicker
                    .disabled(isRequesting)
                    .padding(.horizontal, 24)
            }
            Text(scope.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
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
                Button(action: completeOnboarding) {
                    Text(granted ? "Start Syncing" : "Skip for now")
                        .font(.subheadline)
                        .foregroundStyle(granted ? .pink : .secondary)
                }
                .padding(.bottom, 4)
            }
        }
        .scrollsWhenTall()
    }

    private var scopePicker: some View {
        Picker("Health data", selection: $scope) {
            ForEach(HealthKitManager.DataScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.menu)
    }

    private func requestAccess() {
        isRequesting = true
        Task {
            do {
                try await HealthKitManager.shared.requestAuthorization(scope: scope)
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

    private func completeOnboarding() {
        // Persist the default even when HealthKit access is skipped so a later
        // sign-in cannot silently expand the requested data scope.
        UserDefaults.standard.set(scope.rawValue, forKey: HealthKitManager.DataScope.storageKey)
        onDone()
    }
}

// MARK: - Large text

private extension View {
    /// The steps are a fixed column of spacers and text sized to one screen. At accessibility
    /// text sizes that column is taller than the screen and SwiftUI truncated the title and
    /// the explanation to a few words. Inside a scroll view the column keeps its centered
    /// layout whenever it fits and scrolls only when it does not.
    func scrollsWhenTall() -> some View {
        GeometryReader { proxy in
            ScrollView {
                self.frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(screenshotScrollAnchor)
        }
        // The page-index dots float over the bottom of every page. Ending the scroll area
        // above them means no line of text can sit under the dots at any text size; the
        // buttons' own bottom padding shrank by the same amount, so default size is unchanged.
        .padding(.bottom, 44)
    }

    /// Design-gate screenshots only: `-h4aiOnboardingBottom` opens each page
    /// scrolled to its end, since simctl cannot scroll. nil (the top) everywhere else.
    private var screenshotScrollAnchor: UnitPoint? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-h4aiOnboardingBottom") { return .bottom }
        #endif
        return nil
    }
}
