import SwiftUI

struct SMSView: View {
    @EnvironmentObject private var state: MobileAppState
    @State private var showingCompose = false

    var body: some View {
        NavigationStack {
            Group {
                if state.contacts.isEmpty {
                    ContentUnavailableView("暂无短信", systemImage: "message", description: Text("收到或提交短信后，会话会显示在这里。"))
                } else {
                    List(state.contacts) { contact in
                        NavigationLink(value: contact) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(contact.peer).font(.headline)
                                    Spacer()
                                    if contact.unreadCount > 0 {
                                        Text("\(contact.unreadCount)")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(.indigo, in: Capsule())
                                    }
                                }
                                Text(contact.lastContent.isEmpty ? "（无内容）" : contact.lastContent)
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                                Text(contact.lastTimestamp).font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("短信")
            .navigationDestination(for: SMSContact.self) { contact in
                ThreadView(contact: contact)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Task { await state.refreshContacts() } } label: { Image(systemName: "arrow.clockwise") }
                    Button { showingCompose = true } label: { Image(systemName: "square.and.pencil") }
                        .disabled(!state.smsEnabled)
                }
            }
            .refreshable { await state.refreshContacts() }
            .sheet(isPresented: $showingCompose) { ComposeSMSView() }
            .task { await state.refreshContacts() }
        }
    }
}

private struct ThreadView: View {
    @EnvironmentObject private var state: MobileAppState
    let contact: SMSContact
    @State private var reply = ""
    @State private var deleteCandidate: SMSMessage?

    var body: some View {
        Group {
            if state.messages.isEmpty {
                ContentUnavailableView("暂无会话内容", systemImage: "text.bubble", description: Text("下拉刷新，或直接在下方回复。"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(state.messages) { message in
                                bubble(message)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding()
                    }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: state.messages.last?.id) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .navigationTitle(contact.peer)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom) {
                TextField("回复短信", text: $reply, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button("回复") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy || !state.smsEnabled || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(.bar)
        }
        .task { await state.selectContact(contact) }
        .refreshable { await state.selectContact(contact) }
        .alert(item: $deleteCandidate) { message in
            Alert(
                title: Text("删除这条短信？"),
                primaryButton: .destructive(Text("删除")) { Task { await state.deleteMessage(message) } },
                secondaryButton: .cancel()
            )
        }
    }

    private func bubble(_ message: SMSMessage) -> some View {
        HStack {
            if message.outgoing { Spacer(minLength: 45) }
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 5) {
                Text(message.content)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(message.outgoing ? Color.indigo : Color.secondary.opacity(0.15))
                    .foregroundStyle(message.outgoing ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                HStack(spacing: 8) {
                    Text(message.timestamp)
                    Button(role: .destructive) { deleteCandidate = message } label: { Image(systemName: "trash") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if !message.outgoing { Spacer(minLength: 45) }
        }
    }

    private func submit() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            if await state.sendSMS(phone: contact.peer, message: text, contact: contact) { reply = "" }
        }
    }
}

private struct ComposeSMSView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("接收号码") {
                    TextField("例如 +国家/地区码和号码", text: $phone)
                        .keyboardType(.phonePad)
                    Text("普通号码请包含国际区号；中国大陆使用 +86。运营商短号码可直接填写。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("短信内容") {
                    TextEditor(text: $message).frame(minHeight: 140)
                }
            }
            .navigationTitle("新建短信")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提交") {
                        Task {
                            if await state.sendSMS(phone: phone, message: message, contact: nil) { dismiss() }
                        }
                    }
                    .disabled(phone.isEmpty || message.isEmpty || state.isBusy)
                }
            }
        }
    }
}
