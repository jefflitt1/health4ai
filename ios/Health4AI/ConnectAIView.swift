import SwiftUI
import UIKit

// MARK: - ConnectAIView

/// Copy-to-clipboard MCP configs for the stdio `health4ai` package (`pip install health4ai`),
/// for the three clients named in the mcp-server README: Claude Desktop, Claude Code, Cursor.
///
/// `DATABASE_URL` and `HEALTHKIT_USER_ID` are the server's own env var names
/// (mcp-server/README.md). The user id is prefilled when known (persisted at sign-in, see
/// `SignInView.signIn`); the database URL is ALWAYS a placeholder — health4ai never holds the
/// project's database password (a Postgres connection string, not the anon key this app uses),
/// so embedding a real one here is not possible and would be a security regression if it were.
struct ConnectAIView: View {
    @EnvironmentObject var syncState: SyncState
    @State private var copiedID: String? = nil

    private static let userIDDefaultsKey = "hkb.healthkitUserID"

    private var projectRef: String {
        guard let host = URL(string: syncState.supabaseProjectURL)?.host,
              let ref = host.split(separator: ".").first else { return "<project-ref>" }
        return String(ref)
    }

    private var databaseURLPlaceholder: String {
        "postgresql://postgres.\(projectRef):<YOUR-DB-PASSWORD>@aws-0-<region>.pooler.supabase.com:6543/postgres"
    }

    private var userID: String {
        UserDefaults.standard.string(forKey: Self.userIDDefaultsKey) ?? "<your-auth-user-id>"
    }

    private var claudeDesktopConfig: String {
        """
        {
          "mcpServers": {
            "health4ai": {
              "command": "health4ai",
              "env": {
                "DATABASE_URL": "\(databaseURLPlaceholder)",
                "HEALTHKIT_USER_ID": "\(userID)"
              }
            }
          }
        }
        """
    }

    private var claudeCodeCommand: String {
        "claude mcp add health4ai -e DATABASE_URL='\(databaseURLPlaceholder)' -e HEALTHKIT_USER_ID='\(userID)' -- health4ai"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Ask any AI about your health data")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 10) {
                    NumberedStep(number: 1, text: "Install the server: pip install health4ai")
                    NumberedStep(number: 2, text: "Copy the config below for your AI app")
                    NumberedStep(number: 3, text: "Replace <YOUR-DB-PASSWORD> with your database password")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                configCard(
                    id: "desktop",
                    title: "Claude Desktop",
                    instructions: "Paste into claude_desktop_config.json.",
                    body: claudeDesktopConfig
                )
                configCard(
                    id: "code",
                    title: "Claude Code",
                    instructions: "Run in a terminal.",
                    body: claudeCodeCommand
                )
                configCard(
                    id: "cursor",
                    title: "Cursor",
                    instructions: "Paste into Cursor Settings → MCP → mcp.json.",
                    body: claudeDesktopConfig
                )

                Text("DATABASE_URL is your Supabase project's Postgres connection string (transaction pooler; the database password, not the anon key), from Project Settings → Database → Connection string. HEALTHKIT_USER_ID is the signed-in Supabase Auth user id\(userID.hasPrefix("<") ? "" : ", already filled in above").")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            // iPad: caps the reading width instead of stretching a config block edge to edge.
            .frame(maxWidth: 700)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("Connect Your AI")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func configCard(id: String, title: String, instructions: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(instructions)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(body)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Button {
                UIPasteboard.general.string = body
                copiedID = id
            } label: {
                Label(copiedID == id ? "Copied" : "Copy",
                      systemImage: copiedID == id ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(copiedID == id ? "Copied \(title) config" : "Copy \(title) config")
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct NumberedStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .fontWeight(.semibold)
            Text(text)
        }
    }
}

#Preview {
    NavigationStack {
        ConnectAIView().environmentObject(SyncState())
    }
}
