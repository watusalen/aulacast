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
        VStack(alignment: .leading, spacing: 12) {
            M3Botao(titulo: "Compartilhar arquivo", icone: "upload_file", variante: .tonal, altura: 40) {
                escolherArquivos()
            }
            .help("Escolher arquivos para a turma baixar (ou arraste para cá)")
            .padding(.horizontal, 16)

            if let aviso = viewModel.sharedFilesNotice {
                HStack(alignment: .top, spacing: 8) {
                    M3Icone(nome: "warning", tamanho: 18, preenchido: true)
                    Text(aviso).m3(.bodySmall).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(M3.onErrorContainer)
                .padding(12)
                .m3Superficie(M3.errorContainer, canto: M3.Canto.medio)
                .padding(.horizontal, 16)
            }

            if viewModel.sharedFiles.isEmpty {
                VStack(spacing: 10) {
                    M3Icone(nome: "folder", tamanho: 40)
                        .foregroundColor(M3.onSurfaceVariant)
                    Text("Nenhum arquivo ainda")
                        .m3(.titleMedium)
                        .foregroundColor(M3.onSurface)
                    Text("Arraste arquivos para cá. Qualquer tipo serve; a turma baixa pela página da aula.")
                        .m3(.bodyMedium)
                        .foregroundColor(M3.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(viewModel.sharedFiles) { arquivo in
                            linha(arquivo)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                    .animation(M3.Mola.padrao, value: viewModel.sharedFiles)
                    .animation(M3.Mola.lenta, value: recentes)
                }
            }
        }
        .padding(.top, 4)
        .overlay(
            RoundedRectangle(cornerRadius: M3.Canto.extraGrande, style: .continuous)
                .stroke(M3.primary, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .opacity(arrastandoPorCima ? 1 : 0)
                .padding(6)
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

    /// Item de lista do Material: ícone à esquerda, nome, e uma informação por linha
    /// (o painel tem 360 pt; lado a lado o nome e o estado saíam cortados).
    private func linha(_ arquivo: SharedFile) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: M3.Canto.medio, style: .continuous)
                    .fill(M3.secondaryContainer)
                M3Icone(nome: "description", tamanho: 22)
                    .foregroundColor(M3.onSecondaryContainer)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(arquivo.name)
                    .m3(.bodyLarge)
                    .foregroundColor(M3.onSurface)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(arquivo.name)
                Text(ByteCountFormatter.string(fromByteCount: arquivo.size, countStyle: .file))
                    .m3(.bodyMedium)
                    .foregroundColor(M3.onSurfaceVariant)
                situacao(viewModel.fileDownloadStats[arquivo.id])
            }
            Spacer(minLength: 0)
            M3BotaoDeIcone(icone: "close", variante: .padrao, tamanho: 36, ajuda: "Parar de compartilhar") {
                viewModel.removeSharedFile(id: arquivo.id)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: M3.Canto.grande, style: .continuous)
                .fill(recentes.contains(arquivo.id) ? M3.tertiaryContainer : Color.clear)
        )
    }

    /// O estado do arquivo numa frase curta, que cabe no painel de 360 pt:
    /// ninguém baixou ainda → para quantos está disponível; já baixaram → "3 de 4
    /// baixaram". Downloads em andamento não aparecem: o que interessa ao professor é
    /// quem já tem o arquivo.
    private func situacao(_ estatisticas: FileDownloadStats?) -> some View {
        let alunos = viewModel.clientManager.identifiedClients.count
        let concluidos = estatisticas?.concluidos ?? 0
        let frase: String
        if concluidos > 0 {
            frase = alunos > 0 ? "\(min(concluidos, max(alunos, concluidos))) de \(max(alunos, concluidos)) baixaram"
                               : (concluidos == 1 ? "1 baixou" : "\(concluidos) baixaram")
        } else {
            switch alunos {
            case 0: frase = "Disponível para a turma"
            case 1: frase = "Disponível para 1 aluno"
            default: frase = "Disponível para \(alunos) alunos"
            }
        }
        return HStack(spacing: 6) {
            M3Icone(nome: concluidos > 0 ? "download" : "check_circle", tamanho: 16, preenchido: concluidos == 0)
                .foregroundColor(concluidos > 0 ? M3.onSurfaceVariant : M3.tertiary)
            Text(frase)
                .foregroundColor(M3.onSurfaceVariant)
        }
        .m3(.labelMedium)
        .lineLimit(1)
        .padding(.top, 2)
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
