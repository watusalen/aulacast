import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Arquivos que o professor disponibiliza para a turma baixar (SRP).
public struct SharedFilesPanelView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var arrastandoPorCima = false
    /// Arquivos recém-compartilhados, destacados por alguns segundos para o professor ver
    /// que entraram na lista da turma.
    @State private var recentes: Set<String> = []
    @State private var idsConhecidos: Set<String> = []

    public init(viewModel: MainViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(viewModel.sharedFiles.isEmpty ? "Nenhum arquivo compartilhado"
                     : viewModel.sharedFiles.count == 1 ? "1 arquivo disponível para a turma"
                     : "\(viewModel.sharedFiles.count) arquivos disponíveis para a turma")
                    .font(.system(size: 12))
                    .foregroundColor(AC.textSecondary)
                Spacer()
                Button(action: escolherArquivos) {
                    Label("Compartilhar", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.acOutline(height: 28, cornerRadius: 7, fontSize: 12, horizontalPadding: 10))
                .help("Escolher arquivos para a turma baixar")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

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
                            // Uma informação por linha: o painel lateral tem 360 pt, e com tudo
                            // lado a lado o nome, a disponibilidade e os downloads saíam cortados.
                            HStack(alignment: .top, spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: arquivo.url.path))
                                    .resizable()
                                    .frame(width: 26, height: 26)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(arquivo.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(AC.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(arquivo.name)
                                    HStack(spacing: 4) {
                                        Text(ByteCountFormatter.string(fromByteCount: arquivo.size, countStyle: .file))
                                        Text("·").foregroundColor(AC.textTertiary)
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(AC.liveGreen)
                                        Text(textoDeDisponivel)
                                    }
                                    .font(.system(size: 12))
                                    .foregroundColor(AC.textSecondary)
                                    .lineLimit(1)
                                    situacaoDosDownloads(viewModel.fileDownloadStats[arquivo.id])
                                }
                                Spacer(minLength: 4)
                                Button(action: { viewModel.removeSharedFile(id: arquivo.id) }) {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.acIcon(size: 24, cornerRadius: 6, fontSize: 10))
                                .help("Parar de compartilhar")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(recentes.contains(arquivo.id) ? AC.liveGreen.opacity(0.12) : Color.clear)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            Divider()
                        }
                    }
                    .animation(.easeOut(duration: 0.25), value: viewModel.sharedFiles)
                    .animation(.easeOut(duration: 0.6), value: recentes)
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
        .onAppear { idsConhecidos = Set(viewModel.sharedFiles.map(\.id)) }
        .onChange(of: viewModel.sharedFiles) { arquivos in
            let ids = Set(arquivos.map(\.id))
            let novos = ids.subtracting(idsConhecidos)
            idsConhecidos = ids
            guard !novos.isEmpty else { return }
            recentes.formUnion(novos)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                recentes.subtract(novos)
            }
        }
    }

    /// Para quantos alunos o arquivo já aparece. A lista chega na hora a quem está
    /// conectado, e a quem entrar depois junto com as boas-vindas.
    private var textoDeDisponivel: String {
        switch viewModel.clientManager.identifiedClients.count {
        case 0: return "Disponível (nenhum aluno conectado)"
        case 1: return "Disponível para 1 aluno"
        case let n: return "Disponível para \(n) alunos"
        }
    }

    @ViewBuilder
    private func situacaoDosDownloads(_ estatisticas: FileDownloadStats?) -> some View {
        if let estatisticas, estatisticas.emAndamento > 0 || estatisticas.concluidos > 0 {
            HStack(spacing: 10) {
                if estatisticas.concluidos > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(estatisticas.concluidos == 1 ? "baixado por 1" : "baixado por \(estatisticas.concluidos)")
                    }
                    .foregroundColor(AC.textSecondary)
                }
                if estatisticas.emAndamento > 0 {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
                        Text("baixando (\(estatisticas.emAndamento))")
                    }
                    .foregroundColor(AC.accent)
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
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
