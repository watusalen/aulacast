# Documento de Especificação de Requisitos (SRS)
## Projeto: AulaCast (Transmissor de Tela em Rede Local - IFPI)

---

### 1. Introdução

#### 1.1. Contexto do Problema
Nas salas de aula e laboratórios do Instituto Federal do Piauí - Campus Piripiri (IFPI), os alunos enfrentam séria dificuldade para acompanhar as aulas expositivas e de programação devido a três fatores críticos:
1. **Projetor Multimídia Deficiente:** O projetor da sala possui baixa resolução, lâmpada fraca e baixo contraste, tornando impossível para os alunos (especialmente os sentados no fundo ou nas laterais da sala) enxergarem trechos de código-fonte, comandos no terminal ou detalhes da tela do professor.
2. **Conexão de Internet Instável:** A rede de internet externa da instituição é lenta e instável.
3. **Bloqueio por Firewall Institucional:** O firewall da rede do IFPI bloqueia tráfego e portas de conexão de áudio/vídeo de plataformas de conferência e streaming de terceiros (Google Meet, Discord, Zoom, Teams), impedindo completamente o uso dessas ferramentas.

#### 1.2. Objetivo da Solução (AulaCast)
O **AulaCast** foi projetado para contornar completamente o projetor, a instabilidade da internet e o firewall da instituição. Ele opera estritamente na **Rede Local (LAN)** (Ethernet ou Wi-Fi interno da sala), permitindo que o professor transmita a tela do seu computador macOS em alta definição e tempo real diretamente para as telas individuais dos alunos via tráfego local, **100% offline e sem passar pelo firewall da internet externa**.

#### 1.3. Escopo do Sistema
O aplicativo principal é um app nativo para macOS escrito em **Swift / SwiftUI** que atua como o *Host* (Servidor & Transmissor). Os clientes (Alunos) utilizam uma interface Web progressiva servida diretamente pelo app do professor, dispensando a instalação de aplicativos terceiros nos computadores do laboratório (Linux/Windows).

---

### 2. Requisitos Funcionais (RF)

| ID | Nome do Requisito | Descrição | Prioridade |
| :--- | :--- | :--- | :--- |
| **RF-01** | Captura de Tela Nativa | O aplicativo deve capturar o vídeo da tela do macOS em alta performance utilizando a API nativa `ScreenCaptureKit`. | **MUST** |
| **RF-02** | Seleção de Fonte | O professor deve poder escolher entre transmitir o Monitor Completo ou uma Janela de Aplicativo específica (ex: Xcode, Terminal, VS Code). | **MUST** |
| **RF-03** | Servidor Web/WebSocket Embutido | O aplicativo macOS deve subir um servidor HTTP e WebSocket na porta local 8080 (usando `Network.framework`). | **MUST** |
| **RF-04** | Streaming de Vídeo de Baixa Latência | O sistema deve codificar os quadros em JPEG e transmiti-los como fluxo MJPEG (`multipart/x-mixed-replace`) sobre HTTP, exibível por qualquer navegador sem plugin ou codec adicional. | **MUST** |
| **RF-05** | Anúncio de Serviço (Bonjour/mDNS) | O sistema deve anunciar o serviço na rede local usando o protocolo Bonjour (`_aulacast._tcp`, nome "AulaCast - IFPI"), na própria porta fixa do servidor (8080). Além do serviço Bonjour, o app registra o nome `aulacast.local` (`MDNSHostnameService`): com a sessão aberta, o painel mostra só `aulacast.local:8080`; o IP:8080 continua valendo como alternativa e sai pelo botão "Copiar link". **Duas transmissões na mesma rede:** o sistema não renomeia um registro mDNS único, ele avisa o conflito (`NameConflict`). O app escuta esse aviso e, sozinho, tenta `aulacast-2.local`, `aulacast-3.local` e assim por diante (até 20). O painel só mostra um nome depois de o sistema confirmá-lo, e volta para o IP se o nome se perder (conflito tardio, queda do `mDNSResponder`, troca de IP durante a aula, falta de rede). A porta 8080 não colide: cada Mac tem o próprio IP. Verificado com três registros na mesma máquina; **não** verificado com dois Macs reais. Redirecionar a porta 80 para esconder o `:8080` foi tentado e revertido (commit `0d38433`). | **MUST** |
| **RF-06** | Controles da Sessão de Transmissão | O professor deve ter botões intuitivos para **Iniciar**, **Pausar** (congelar imagem) e **Encerrar** a transmissão. | **MUST** |
| **RF-07** | Indicador de Alunos Conectados | O aplicativo deve exibir em tempo real a lista e a contagem total de alunos/dispositivos conectados à transmissão. | **MUST** |
| **RF-08** | Interface Web do Aluno | O cliente Web exibe o fluxo MJPEG numa `<img>` responsiva (não é um player `<video>`), com suporte a Tela Cheia (Full Screen). | **MUST** |
| **RF-09** | Chat Local Offline | Mensagens de texto na rede local. Por padrão, a mensagem do aluno é reservada com o professor (volta apenas para o autor); a do professor é vista por toda a turma. O professor pode abrir a conversa entre alunos (RF-18). | **SHOULD** |
| **RF-10** | Identificação do Aluno | Antes de assistir, o aluno deve informar o nome, validado tanto no cliente quanto no servidor. | **MUST** |
| **RF-11** | Notificação "Levantar a Mão" | O aluno levanta e abaixa a mão por um ícone no chat; o professor vê quem levantou, em ordem, e pode abaixar. Foi retirado e voltou a pedido da turma (feedback de 23/09/2026), mais discreto que o botão original. | **SHOULD** |
| ~~**RF-12**~~ | ~~Ícone na Barra de Menus (StatusItem)~~ | **Descartado.** Foi implementado e removido: o painel duplicava o que a janela principal já mostra, e um ícone permanente na barra de menus cobra atenção o tempo todo em troca de pouco. Era **SHOULD**, e a decisão foi não ter. | — |
| **RF-13** | Configuração de Qualidade de Vídeo | O professor pode alternar a resolução de saída (720p / 1080p) e taxa de quadros (15 / 30 / 45 fps), com efeito imediato na transmissão em andamento. | **SHOULD** |
| **RF-14** | Indicador de Presença Efetiva | O aplicativo deve distinguir alunos que estão com a transmissão à vista daqueles apenas conectados (janela minimizada, outra aba ou outro aplicativo em foco). | **SHOULD** |
| **RF-15** | Troca de Fonte em Transmissão | O professor pode trocar o monitor ou a janela transmitida durante a aula, sem encerrar a sessão nem desconectar os alunos. | **SHOULD** |
| **RF-16** | Mensagem Fixada | O professor fixa uma mensagem sua (um link, um prazo), que fica no topo do chat de toda a turma, inclusive de quem entra depois. | **SHOULD** |
| **RF-17** | Compartilhamento de Arquivos | O professor disponibiliza arquivos de qualquer tipo para a turma baixar pela página da aula, pela mesma porta 8080, sem internet. Pode tirar um arquivo da lista a qualquer momento, e o link deixa de funcionar. Pastas precisam ser compactadas antes. | **SHOULD** |
| **RF-18** | Chat Visível entre Alunos | Opção do professor, **desligada por padrão** e só disponível com o chat ligado: com ela ativa, a mensagem do aluno é vista por toda a turma (sem duplicar para quem escreveu). Os alunos conectados são avisados na hora quando a opção muda (`CHAT_VISIBILITY`). **Status: Proposto (já implementado na main).** | **COULD** |
| **RF-19** | Ocultar Apps da Transmissão | Com o monitor como fonte, o professor clica com o botão direito no cartão de um app e escolhe ocultá-lo ou mostrá-lo na transmissão, mesmo em tela cheia, inclusive com a transmissão em andamento. A escolha é guardada entre execuções, por app (bundle ID), e uma lista "Apps ocultos" permite mostrar de novo ou esquecer todos. Se um app oculto abrir durante a transmissão, o filtro é refeito, e ele pode aparecer por uma fração de segundo antes disso. **Status: Proposto.** | **COULD** |

---

### 3. Requisitos Não-Funcionais (RNF)

| ID | Categoria | Descrição | Critério de Aceite |
| :--- | :--- | :--- | :--- |
| **RNF-01** | **Independência da Internet** | O sistema deve funcionar **100% offline** em redes locais isoladas (LAN Ethernet ou roteadores Wi-Fi sem acesso externo). | Zero requisições para servidores externos ou serviços de nuvem. |
| **RNF-02** | **Latência** | O tempo de atraso entre o movimento na tela do professor e a renderização no aluno deve ser mínimo. | Latência média $\le 200\text{ms}$ em rede Ethernet e $\le 350\text{ms}$ em Wi-Fi 802.11n/ac. |
| **RNF-03** | **Desempenho (CPU/GPU)** | A codificação de vídeo deve usar a GPU no rasterizador de quadros e descartar quadros quando a codificação não acompanha a captura, para que o atraso não cresça sem limite. | Uso de CPU do app macOS $\le 15\%$ em chips Apple Silicon M1/M2/M3 durante transmissão 1080p@30fps. **Medição atual:** ~16% de **um núcleo** (monitor 1470×956 pontos, saída ~1660×1080, 30 fps; `docs/04`). A meta não diz se é por núcleo ou do total: se for por núcleo, está acima dela. **Pergunta em aberto:** qual a unidade da meta, e manter ou ajustar. |
| **RNF-04** | **Compatibilidade de Clientes** | O player do aluno deve ser compatível com navegadores modernos sem necessidade de plugins. | Compatível com Google Chrome, Mozilla Firefox, Apple Safari e Microsoft Edge em Linux, Windows e macOS. |
| **RNF-05** | **Zero Instalação nos Clientes** | Os alunos nos computadores do IFPI não devem necessitar de permissões de administrador ou instalação de software. | Acesso direto via `http://aulacast.local:8080` (ou `http://<ip-do-prof>:8080`, copiado pelo professor com "Copiar link"). |
| **RNF-06** | **Segurança no Servidor de Arquivos** | O servidor de arquivos estáticos deve prevenir *Directory Traversal*, impedindo acesso a qualquer caminho fora da pasta pública. | Comparação por componentes de caminho (não por prefixo de texto), bloqueando tanto `../` quanto pastas irmãs de nome semelhante. |
| **RNF-07** | **Identidade Visual (Material 3)** | A interface do professor segue o Material 3 Expressive, com Google Sans Flex e Material Symbols Rounded (`docs/04`, §4.2). | Suporte a Modo Escuro/Claro automático. |
| **RNF-08** | **Resiliência de Rede** | Reconexão automática em caso de desconexão temporária, tanto do canal de mensagens quanto do fluxo de vídeo, que trafegam em conexões distintas. | Tentativas a cada 2 segundos durante o primeiro minuto e, depois, em intervalos crescentes (até 15s) por tempo indeterminado — uma queda longa não deve exigir que a turma recarregue a página. |
| **RNF-09** | **Tolerância a Firewall Institucional** | O sistema deve trafegar exclusivamente pela sub-rede local interna pela porta fixa 8080 (HTTP, WebSocket e MJPEG). O mDNS (UDP 5353, multicast) é usado só para o nome `aulacast.local` e para o anúncio Bonjour, e costuma ser bloqueado por isolamento de clientes no Wi-Fi; nesse caso vale o IP. | Funcionamento normal mesmo em redes corporativas com bloqueio estrito de Discord, Zoom, Meet e conexões de saída. |
| **RNF-10** | **Escala da Transmissão** | **Proposto.** Uma turma de 40 alunos no Wi-Fi da sala deve ver vídeo fluido. Hoje cada quadro é codificado uma vez, mas enviado em uma cópia unicast por aluno (O(n·S) por quadro, `MJPEGStreamerService`). **Estimativa de pior caso (tela mudando a 30 fps), não medida:** com ~150–250 KB por quadro em 1080p/JPEG 0,6, são ~36–60 Mbps por aluno e ~1,4–2,4 Gbps para 40; com um Wi-Fi **suposto** de 100–300 Mbps úteis, daria ~2–5 fps por aluno. Com a tela parada o MJPEG não envia quadros novos, então a taxa real depende do conteúdo. **Objetivo (decisão do usuário, 14/10/2026): o máximo possível** — maximizar os quadros por segundo, minimizar a latência e reduzir a banda por aluno. Direção: H.264/fMP4 (commit `c63592b`), mantendo o MJPEG como compatibilidade; só navegador, sem app no aluno. | **Sem número fixo.** Critério: medir MJPEG e H.264 nas mesmas condições com as linhas `[Métricas]` do servidor (fps médio e mínimo por aluno, Mbps) e, a cada mudança, melhorar fps e banda sem piorar latência nem a legibilidade do texto. Os números alcançados passam a ser a referência e entram aqui depois da primeira medição em sala. |

---

### 4. Perguntas em Aberto
1. **RNF-03:** a meta de 15% é por núcleo ou do total? Manter e otimizar, ou ajustar para os ~16% de um núcleo medidos?
2. **RNF-10:** com o objetivo "o máximo possível", falta a primeira medição em sala (40 alunos): qual o fps, a banda por aluno e a latência alcançados? Qual o Wi-Fi real da sala (padrão e banda medida)?
3. **RF-18 e RF-19:** as prioridades (COULD) estão corretas?
4. **RF-05:** o comportamento de conflito de nome foi verificado com três registros na mesma máquina. Falta conferir com dois Macs reais na mesma rede, inclusive o que acontece com um conflito tardio (volta do sono, duas redes que se juntam).

---

### RF-20: Tempo de cada aluno na aula (Proposto)
O professor clica na linha de um aluno na aba Alunos e vê um painel com: tempo **na aula**, tempo **com a aula à vista** (aba visível e em foco, não é rastreio do olhar), porcentagem, saídas da aula, maior trecho sem sair e desconexões e voltas. O tempo conta só com a transmissão no ar e sem pausa; abas simultâneas da mesma pessoa contam uma vez. Regras de identidade: ADR-005. O perfil também lista os **nomes usados** pela pessoa (linha do tempo, com a marca "mesmo IP") e continua abrindo depois que o aluno sai; clicar no nome do aluno no chat abre o mesmo perfil.

---

### RF-21: Chamada em CSV ao encerrar (Proposto)
Ao encerrar a transmissão (Parar, queda da captura ou falha do servidor), se ao menos uma pessoa se identificou, o app grava `~/Documents/AulaCast/Listas de presença/lista-de-presenca-AAAA-MM-DD-HHmm.csv` (hora local, nunca sobrescreve: sufixo `-2`, `-3`). Formato: separador `;`, UTF-8 com BOM, CRLF, decimais com vírgula; colunas `Nome;Presença;Entrou;Saiu;Minutos na aula;Minutos com a aula à vista;Percentual à vista`. Uma linha por **pessoa** (a identidade do ADR-005 junta reconexões e nomes ligados pelo IP; Nome = o mais recente), em ordem alfabética; quem se identificou é "Presente"; quem nunca se identificou não entra. Nomes digitados por alunos são escapados (aspas RFC 4180) e fórmulas neutralizadas (`=`, `+`, `-`, `@`, tab, CR no início ganham apóstrofo). Sem diálogo: um aviso (snackbar) "Chamada salva (N alunos)" com "Mostrar no Finder", que some em ~8 s; falha de disco mostra "Não foi possível salvar a chamada" e não derruba o app.
