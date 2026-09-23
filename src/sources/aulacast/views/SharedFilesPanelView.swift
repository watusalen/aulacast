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
                                    HStack(spacing: 4) {
                                        Text(ByteCountFormatter.string(fromByteCount: arquivo.size, countStyle: .file))
                                            .foregroundColor(AC.textSecondary)
                                        Text("·").foregroundColor(AC.textTertiary)
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(AC.liveGreen)
                                        Text(textoDeDisponivel)
                                            .foregroundColor(AC.textSecondary)
                                    }
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                }
                                Spacer()
                                situacaoDosDownloads(viewModel.fileDownloadStats[arquivo.id])
                                Button(action: { viewModel.removeSharedFile(id: arquivo.id) }) {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.acIcon(size: 26, cornerRadius: 6, fontSize: 11))
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
            VStack(alignment: .trailing, spacing: 2) {
                if estatisticas.emAndamento > 0 {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("baixando (\(estatisticas.emAndamento))")
                    }
                    .foregroundColor(AC.accent)
                }
                if estatisticas.concluidos > 0 {
                    Label(
                        estatisticas.concluidos == 1 ? "baixado por 1 aluno" : "baixado por \(estatisticas.concluidos) alunos",
                        systemImage: "arrow.down.circle.fill"
                    )
                    .foregroundColor(AC.textSecondary)
                }
            }
            .font(.system(size: 11))
            .frame(height: 30)
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
