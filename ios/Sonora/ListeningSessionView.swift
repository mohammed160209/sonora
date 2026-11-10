import SwiftUI

/// Presents the Sonora Sessions controls without tying the connection to the sheet lifecycle.
struct ListeningSessionView: View {
    @Environment(ListeningSession.self) private var session
    @Environment(PlaybackController.self) private var playback
    @Environment(DownloadsStore.self) private var downloads
    @Environment(AccountStore.self) private var account
    @State private var name = ""
    @State private var code = ""
    @State private var server = ""
    @State private var serverToSave: String?
    @State private var memberToRemove: ListeningSession.Member?

    var body: some View {
        Form {
            if let invite = session.code {
                Section {
                    LabeledContent("ios-session-invite-code") {
                        Text(invite).monospacedDigit().textSelection(.enabled)
                    }
                    ShareLink(item: invite) {
                        Label("ios-session-share-code", systemImage: "square.and.arrow.up")
                    }
                    if session.busy { ProgressView("ios-session-reconnecting") }
                    Button(LocalizedStringKey(session.hosting ? "ios-session-end" : "ios-session-leave"), role: .destructive) {
                        session.leave()
                    }
                }
                Section("ios-session-members") {
                    ForEach(session.members) { member in
                        HStack {
                            Text(member.name)
                            Spacer()
                            if member.host { Text("ios-session-host").foregroundStyle(.secondary) }
                            if session.hosting && !session.isSelf(member) {
                                Button("ios-session-remove-member", systemImage: "person.crop.circle.badge.minus") {
                                    memberToRemove = member
                                }
                                .labelStyle(.iconOnly)
                            }
                        }
                    }
                }
            } else {
                Section {
                    TextField("ios-session-display-name", text: $name)
                        .textContentType(.nickname)
                    Button("ios-session-start", systemImage: "person.2.wave.2") {
                        session.start(name: name, playback: playback)
                    }
                    TextField("ios-session-invite-code", text: $code)
                        .keyboardType(.numberPad)
                        .onChange(of: code) { _, value in
                            code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                        }
                    Button("ios-session-join", systemImage: "arrow.right.circle") {
                        session.join(code: code, name: name, playback: playback)
                    }
                    .disabled(code.count != 6)
                    if session.busy { ProgressView("ios-session-connecting") }
                } footer: {
                    Text("ios-session-description")
                }
                .disabled(session.busy || downloads.isOffline)

                Section("ios-session-server") {
                    TextField("ios-session-server", text: $server)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("ios-session-save-server") { serverToSave = server }
                    Button("ios-session-use-official") {
                        serverToSave = ListeningSession.official.absoluteString
                    }
                }
                .disabled(session.busy || downloads.isOffline)
            }
            if let message = session.message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
            if downloads.isOffline {
                Section { Label("ios-offline-active", systemImage: "wifi.slash") }
            }
        }
        .appNavigationTitle("ios-listening-sessions")
        .onAppear {
            if name.isEmpty { name = account.name ?? "" }
            server = session.server.absoluteString
        }
        .task(id: serverToSave) {
            guard let address = serverToSave else { return }
            await session.saveServer(address)
            server = session.server.absoluteString
            serverToSave = nil
        }
        .confirmationDialog("ios-session-remove-member", isPresented: Binding(
            get: { memberToRemove != nil },
            set: { if !$0 { memberToRemove = nil } }
        ), titleVisibility: .visible, presenting: memberToRemove) { member in
            Button("ios-session-remove-member", role: .destructive) { session.kick(member) }
            Button("ios-cancel", role: .cancel) {}
        } message: { member in Text(member.name) }
    }
}
