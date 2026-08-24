import SwiftUI

/// Painel de Chat local no app do Professor (SRP).
public struct ChatPanelView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject private var chatManager: ChatManagerService
    @State private var messageText: String = ""

    public init(viewModel: MainViewModel) {
        self.viewModel = viewModel
        self._chatManager = ObservedObject(wrappedValue: viewModel.chatManager)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chat da Sala")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AC.textPrimary)
                .padding(14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(chatManager.messages) { msg in
                            HStack {
                                if msg.isProf { Spacer(minLength: 32) }

                                VStack(alignment: msg.isProf ? .trailing : .leading, spacing: 4) {
                                    if !msg.isProf {
                                        Text(msg.sender)
                                            .font(.system(size: 11))
                                            .foregroundColor(AC.textSecondary)
                                    }
                                    Text(msg.text)
                                        .font(.system(size: 14))
                                        .foregroundColor(msg.isProf ? .white : AC.textPrimary)
                                        .padding(.horizontal, 13)
                                        .padding(.vertical, 9)
                                        .background(msg.isProf ? AC.accent : AC.chatBubbleOther)
                                        .clipShape(bubbleShape(isProf: msg.isProf))
                                }

                                if !msg.isProf { Spacer(minLength: 32) }
                            }
                            .id(msg.id)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: chatManager.messages.count) { _ in
                    if let lastMsg = chatManager.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMsg.id, anchor: .bottom)
                        }
                    }
                }
            }
            .background(AC.panelBG)

            Divider()

            HStack(spacing: 10) {
                TextField("Mensagem para a turma…", text: $messageText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AC.inputBG))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AC.border, lineWidth: 1))
                    .onSubmit {
                        sendMessage()
                    }

                Button("Enviar") {
                    sendMessage()
                }
                .buttonStyle(.acFilled(AC.accent, height: 34, cornerRadius: 8, fontSize: 14, horizontalPadding: 16))
            }
            .padding(14)
        }
        .background(AC.panelBG)
    }

    private func bubbleShape(isProf: Bool) -> some Shape {
        ChatBubbleShape(sharpCorner: isProf ? .bottomTrailing : .bottomLeading)
    }

    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        viewModel.sendProfMessage(text: messageText)
        messageText = ""
    }
}

/// Balão de chat com um canto "pontudo" (estilo iMessage), compatível com macOS 13.
private struct ChatBubbleShape: Shape {
    enum Corner { case bottomLeading, bottomTrailing }

    let sharpCorner: Corner
    let radius: CGFloat = 16
    let sharpRadius: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        let bottomLeading = sharpCorner == .bottomLeading ? sharpRadius : radius
        let bottomTrailing = sharpCorner == .bottomTrailing ? sharpRadius : radius

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomTrailing))
        path.addArc(center: CGPoint(x: rect.maxX - bottomTrailing, y: rect.maxY - bottomTrailing), radius: bottomTrailing, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bottomLeading, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bottomLeading, y: rect.maxY - bottomLeading), radius: bottomLeading, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}
