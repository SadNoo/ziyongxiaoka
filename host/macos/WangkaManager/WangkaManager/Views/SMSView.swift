import SwiftUI

struct SMSView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingCompose = false
    @State private var replyText = ""
    @State private var messageToDelete: SMSMessage?
    @State private var showingThreadDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("短信").font(.largeTitle.bold())
                    Spacer(minLength: 16)
                    Button { Task { await state.refreshContacts() } } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    Button { showingCompose = true } label: {
                        Label("新建短信", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.smsEnabled)
                }
                Text("发送普通号码时请填写 +国家/地区码；中国大陆使用 +86。运营商短号码可直接填写。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            if !state.smsEnabled {
                Label("当前为网卡模式，短信引擎已停用。切换到双模式或短信模式后才能收发。", systemImage: "info.circle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            Divider()
            GeometryReader { geometry in
                HSplitView {
                    contactList.frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                    threadView.frame(minWidth: 340, maxWidth: .infinity)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .sheet(isPresented: $showingCompose) {
            ComposeSMSView().environmentObject(state)
        }
        .task {
            state.setSMSViewActive(true)
            await state.refreshContacts()
        }
        .onDisappear { state.setSMSViewActive(false) }
        .alert(item: $messageToDelete) { message in
            Alert(
                title: Text("删除这条短信？"),
                message: Text("删除后无法恢复。仅删除短信中心历史记录。"),
                primaryButton: .destructive(Text("删除")) {
                    guard let contact = state.selectedContact else { return }
                    Task { _ = await state.deleteSMSMessage(message, from: contact) }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .alert("永久删除整个会话？", isPresented: $showingThreadDeleteConfirmation) {
            Button("删除会话", role: .destructive) {
                guard let contact = state.selectedContact else { return }
                Task { _ = await state.deleteSMSThread(contact) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除当前号码的全部短信历史，无法恢复。仅删除短信中心历史记录。")
        }
    }

    private var contactList: some View {
        List {
            if state.contacts.isEmpty {
                EmptyStateView(title: "暂无短信", symbol: "message", description: "收到或提交短信后，会话会显示在这里。")
            } else {
                ForEach(state.contacts) { contact in
                    Button { Task { await state.selectContact(contact) } } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(contact.peer).font(.headline).lineLimit(1)
                                Spacer()
                                let unread = state.unreadCount(for: contact)
                                if unread > 0 {
                                    Text("\(unread)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(.indigo)
                                        .clipShape(Capsule())
                                }
                            }
                            Text(contact.lastContent.isEmpty ? "（无内容）" : contact.lastContent)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(contact.lastTimestamp)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        state.selectedContactID == contact.id ? Color.indigo.opacity(0.12) : Color.clear
                    )
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var threadView: some View {
        if let contact = state.selectedContact {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.peer).font(.title2.bold())
                        Text(contact.deviceName ?? contact.localPhone ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        showingThreadDeleteConfirmation = true
                    } label: {
                        Label("删除会话", systemImage: "trash")
                    }
                    .disabled(state.isBusy)
                }
                .padding(16)
                Divider()

                ScrollViewReader { proxy in
                    Group {
                        if state.messages.isEmpty {
                            EmptyStateView(
                                title: "暂无会话内容",
                                symbol: "text.bubble",
                                description: "点击刷新重试，或直接在下方回复。"
                            )
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(state.messages) { message in
                                        messageBubble(message)
                                    }
                                    Color.clear.frame(height: 1).id("thread-bottom")
                                }
                                .padding(20)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                    .onAppear { scrollToBottom(proxy) }
                    .onChange(of: state.messages.last?.id) { _ in scrollToBottom(proxy) }
                }

                Divider()
                replyComposer(contact)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(title: "请选择会话", symbol: "text.bubble", description: "从左侧选择联系人，或新建一条短信。")
        }
    }

    private func replyComposer(_ contact: SMSContact) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("回复短信", text: $replyText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { submitReply(to: contact) }
            Button(state.isBusy ? "提交中…" : "回复") {
                submitReply(to: contact)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                state.isBusy
                    || !state.smsEnabled
                    || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(14)
    }

    private func submitReply(to contact: SMSContact) {
        let submitted = replyText
        guard !submitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await state.sendSMS(phone: contact.peer, message: submitted, contact: contact) {
                replyText = ""
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("thread-bottom", anchor: .bottom)
            }
        }
    }

    private func messageBubble(_ message: SMSMessage) -> some View {
        HStack {
            if message.outgoing { Spacer(minLength: 60) }
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 5) {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(message.outgoing ? Color.indigo : Color.primary.opacity(0.07))
                    .foregroundStyle(message.outgoing ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack(spacing: 5) {
                    Text(message.timestamp)
                    if message.outgoing, message.status == 2 {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    if message.outgoing, message.status == 3 {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                    Button(role: .destructive) {
                        messageToDelete = message
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .help("删除短信")
                    .disabled(state.isBusy)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if !message.outgoing { Spacer(minLength: 60) }
        }
    }
}

private struct ComposeSMSView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("新建短信").font(.title.bold())
                Spacer()
                Button("取消") { dismiss() }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("接收号码").font(.headline)
                TextField("例如 +国家/地区码和号码", text: $phone)
                    .textFieldStyle(.roundedBorder)
                Text("请包含国际区号，不会自动补 +86；其他国家或地区请填写对应区号。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("短信内容").font(.headline)
                TextEditor(text: $message)
                    .font(.body)
                    .frame(height: 150)
                    .padding(6)
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(.quaternary) }
                Text("\(message.count) 个字符").font(.caption).foregroundStyle(.secondary)
            }
            if let error = state.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(state.isBusy ? "正在提交…" : "提交短信") {
                    Task {
                        if await state.sendSMS(phone: phone, message: message, contact: nil) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    state.isBusy
                        || phone.trimmingCharacters(in: .whitespaces).isEmpty
                        || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { state.clearMessages() }
    }
}
