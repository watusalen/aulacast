import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Arquivos que o professor disponibiliza para a turma baixar (SRP).
public struct SharedFilesPanelView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var arrastandoPorCima = false

    public init(viewModel: MainViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Arquivos da Aula (\(viewModel.sharedFiles.count))")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AC.textPrimary)
                Spacer()
                Button(action: escolherArquivos) {
                    Label("Compartilhar", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.acOutline(height: 28, cornerRadius: 7, fontSize: 12, horizontalPadding: 10))
                .help("Escolher arquivos para a turma baixar")
            }
            .padding(14)

            Divider()

            if let aviso = viewModel.sharedFilesNotice {
                Text(aviso)
                    .font(.system(size: 12))
                    .foregroundColor(AC.stopRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }

            if viewModel.sharedFiles.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 22))
                        .foregroundColor(AC.textTertiary)
                    Text("Arraste arquivos para cá ou clique em Compartilhar.")
                        .font(.system(size: 13))
                        .foregroundColor(AC.textSecondary)
                        .multilineTextAlignment(.center)
                    Text("Qualquer tipo de arquivo. A turma baixa pela página da aula.")
                        .font(.system(size: 12))
                        .foregroundColor(AC.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.sharedFiles) { arquivo in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: arquivo.url.path))
                                    .resizable()
                                    .frame(width: 22, height: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(arquivo.name)
                                        .font(.system(size: 14))
                                        .foregroundColor(AC.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(ByteCountFormatter.string(fromByteCount: arquivo.size, countStyle: .file))
                                        .font(.system(size: 12))
                                        .foregroundColor(AC.textSecondary)
                                }
                                Spacer()
                                Button(action: { viewModel.removeSharedFile(id: arquivo.id) }) {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.acIcon(size: 26, cornerRadius: 6, fontSize: 11))
                                .help("Parar de compartilhar")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(AC.panelBG)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AC.accent, lineWidth: 2)
                .opacity(arrastandoPorCima ? 1 : 0)
                .padding(4)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $arrastandoPorCima) { itens in
            receberArrastados(itens)
            return true
        }
    }

    private func escolherArquivos() {
        let painel = NSOpenPanel()
        painel.canChooseFiles = true
        painel.canChooseDirectories = false
        painel.allowsMultipleSelection = true
        painel.prompt = "Compartilhar"
        painel.message = "Escolha os arquivos que a turma vai poder baixar."
        guard painel.runModal() == .OK else { return }
        viewModel.shareFiles(painel.urls)
    }

    private func receberArrastados(_ itens: [NSItemProvider]) {
        for item in itens {
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in viewModel.shareFiles([url]) }
            }
        }
    }
}
