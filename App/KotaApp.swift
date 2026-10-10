import AuthenticationServices
import SwiftUI
import WidgetKit

@main
struct KotaApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @AppStorage(Kota.showsUsedKey, store: Kota.defaults) private var showsUsed = false
    @State private var accounts = Account.all
    @State private var snapshot = Snapshot.cached
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: self.$path) {
            List {
                ForEach(self.accounts) { account in
                    NavigationLink(value: account.id) { self.row(account) }
                }
                .onMove { self.accounts.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in
                    for index in offsets { self.accounts[index].deleteSecrets() }
                    self.accounts.remove(atOffsets: offsets)
                }
                if self.accounts.isEmpty {
                    Text("Tap + to add an account.").foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Show used instead of left", isOn: self.$showsUsed)
                } footer: {
                    Text("Widgets show accounts in this order: the first one (small), two (medium), four (large).")
                }
            }
            .navigationTitle("Kota")
            .navigationDestination(for: UUID.self) { id in
                if let index = self.accounts.firstIndex(where: { $0.id == id }) {
                    AccountDetailView(account: self.$accounts[index]) {
                        self.path = []
                        self.accounts[index].deleteSecrets()
                        self.accounts.remove(at: index)
                    }
                    .onDisappear { Task { await self.refresh() } }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(ProviderKind.allCases) { kind in
                            Button(kind.label) { self.add(kind) }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .refreshable { await self.refresh() }
            .task { await self.refresh() }
            .onChange(of: self.accounts) { _, new in Account.all = new }
            .onChange(of: self.showsUsed) { WidgetCenter.shared.reloadAllTimelines() }
        }
    }

    private func row(_ account: Account) -> some View {
        let usage = self.snapshot.providers.first { $0.id == account.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(account.name).font(.headline)
                if account.name != account.kind.label {
                    Text(account.kind.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(usage?.windows ?? [], id: \.self) { UsageBar(window: $0) }
            if let error = usage?.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func add(_ kind: ProviderKind) {
        let count = self.accounts.count(where: { $0.kind == kind })
        let account = Account(kind: kind, name: count == 0 ? kind.label : "\(kind.label) \(count + 1)")
        self.accounts.append(account)
        self.path = [account.id]
    }

    private func refresh() async {
        Account.all = self.accounts
        self.snapshot = await UsageFetcher.fetchAll()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

struct AccountDetailView: View {
    @Binding var account: Account
    let onDelete: () -> Void
    @State private var pasted = ""
    @State private var signedIn = false
    @State private var showsClaudeLogin = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Name") {
                TextField(self.account.kind.label, text: self.$account.name)
            }
            Section {
                switch self.account.kind {
                case .claude:
                    Button("Sign in to claude.ai") { self.showsClaudeLogin = true }
                    SecureField("…or paste the sessionKey cookie", text: self.$pasted)
                case .codex:
                    Button("Sign in with ChatGPT") { Task { await self.signInToCodex() } }
                    SecureField("…or paste an access token", text: self.$pasted)
                case .opencodeGo:
                    Link("Get an API key at opencode.ai", destination: URL(string: "https://opencode.ai/auth")!)
                    SecureField("OpenCode API key", text: self.$pasted)
                }
                if !self.pasted.isEmpty {
                    Button("Save") { self.store(self.pasted) }
                }
                LabeledContent("Status", value: self.signedIn ? "Signed in" : "Not signed in")
            } header: {
                Text("Sign-in")
            } footer: {
                Text(self.help)
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Section {
                Button("Delete account", role: .destructive, action: self.onDelete)
            }
        }
        .navigationTitle(self.account.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { self.signedIn = self.account.secret() != nil }
        .sheet(isPresented: self.$showsClaudeLogin) {
            NavigationStack {
                ClaudeLoginView { sessionKey in
                    self.showsClaudeLogin = false
                    self.store(sessionKey)
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign in to Claude")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { self.showsClaudeLogin = false }
                    }
                }
            }
        }
        .alert("Kota", isPresented: Binding(
            get: { self.message != nil },
            set: { if !$0 { self.message = nil } }))
        {} message: {
            Text(self.message ?? "")
        }
    }

    private var help: String {
        switch self.account.kind {
        case .claude:
            "Signing in here keeps a separate session per account, so you can add several. " +
                "If the sign-in page won't work (Google sign-in can be blocked in in-app browsers), use " +
                "\"Continue with email\" or paste the cookie."
        case .codex:
            "Each sign-in is private to this account, so you can add several ChatGPT accounts. " +
                "A pasted token can't renew itself."
        case .opencodeGo:
            "Create an API key in the OpenCode console and paste it here."
        }
    }

    private func store(_ token: String) {
        // A new credential replaces the whole session, including any Codex refresh token.
        self.account.setSecret("", .refresh)
        if self.account.setSecret(token) {
            self.pasted = ""
            self.signedIn = self.account.secret() != nil
        } else {
            self.message = "Couldn't save to the Keychain. Check that both targets are signed with the same team "
                + "and App Group."
        }
    }

    private func signInToCodex() async {
        do {
            try await CodexSignIn.run(for: self.account)
            self.signedIn = true
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // User closed the sheet.
        } catch {
            self.message = "ChatGPT sign-in failed: \(error.localizedDescription)"
        }
    }
}
