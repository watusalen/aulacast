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
| **RF-04** | Streaming de Vídeo de Baixa Latência | O sistema deve encodificar e transmitir o fluxo de vídeo (H.264 / MJPEG em tempo real) para os navegadores conectados. | **MUST** |
| **RF-05** | Anúncio de Serviço (Bonjour/mDNS) | O sistema deve anunciar o serviço na rede local usando o protocolo Bonjour (`_aulacast._tcp`), permitindo resolução por nome (ex: `aulacast-prof.local`). | **MUST** |
| **RF-06** | Controles da Sessão de Transmissão | O professor deve ter botões intuitivos para **Iniciar**, **Pausar** (congelar imagem) e **Encerrar** a transmissão. | **MUST** |
| **RF-07** | Indicador de Alunos Conectados | O aplicativo deve exibir em tempo real a lista e a contagem total de alunos/dispositivos conectados à transmissão. | **MUST** |
| **RF-08** | Interface Web do Aluno (Player) | O cliente Web deve fornecer um player de vídeo HTML5 responsivo com suporte a Tela Cheia (Full Screen). | **MUST** |
| **RF-09** | Chat Local Offline | Sistema de mensagens de texto bidirecional entre o professor e os alunos conectados na sala. | **SHOULD** |
| **RF-10** | Compartilhamento de Arquivos Local | O professor pode fazer upload/drag-and-drop de arquivos (códigos fonte, PDFs) para download imediato pelos alunos. | **SHOULD** |
| **RF-11** | Notificação "Levantar a Mão" | O aluno pode clicar em um botão no cliente web para notificar o professor que possui uma dúvida. | **SHOULD** |
| **RF-12** | Ícone na Barra de Menus (StatusItem) | O aplicativo do Mac deve ter um ícone na barra de menus superior permitindo acesso rápido a controles e notificações. | **SHOULD** |
| **RF-13** | Configuração de Qualidade de Vídeo | O professor pode alternar a resolução de saída (720p / 1080p) e taxa de quadros (15fps / 30fps) conforme o desempenho da rede. | **COULD** |

---

### 3. Requisitos Não-Funcionais (RNF)

| ID | Categoria | Descrição | Critério de Aceite |
| :--- | :--- | :--- | :--- |
| **RNF-01** | **Independência da Internet** | O sistema deve funcionar **100% offline** em redes locais isoladas (LAN Ethernet ou roteadores Wi-Fi sem acesso externo). | Zero requisições para servidores externos ou serviços de nuvem. |
| **RNF-02** | **Latência** | O tempo de atraso entre o movimento na tela do professor e a renderização no aluno deve ser mínimo. | Latência média $\le 200\text{ms}$ em rede Ethernet e $\le 350\text{ms}$ em Wi-Fi 802.11n/ac. |
| **RNF-03** | **Desempenho (CPU/GPU)** | A codificação de vídeo no Mac do professor deve utilizar aceleração por hardware. | Uso de CPU do app macOS $\le 15\%$ em chips Apple Silicon M1/M2/M3 durante transmissão 1080p@30fps. |
| **RNF-04** | **Compatibilidade de Clientes** | O player do aluno deve ser compatível com navegadores modernos sem necessidade de plugins. | Compatível com Google Chrome, Mozilla Firefox, Apple Safari e Microsoft Edge em Linux, Windows e macOS. |
| **RNF-05** | **Zero Instalação nos Clientes** | Os alunos nos computadores do IFPI não devem necessitar de permissões de administrador ou instalação de software. | Acesso direto via URL `http://<ip-do-prof>:8080`. |
| **RNF-06** | **Segurança no Upload** | O módulo de compartilhamento de arquivos deve prevenir ataques de *Directory Traversal* e execução remota de scripts. | Arquivos salvos exclusivamente em diretório temporário isolado (`/tmp/aulacast_files/`). |
| **RNF-07** | **Design Nativo macOS (HIG)** | A interface do professor deve seguir estritamente o *Apple Human Interface Guidelines*. | Suporte a Modo Escuro/Claro automático, tipografia San Francisco e atalhos globais de teclado. |
| **RNF-08** | **Resiliência de Rede** | Reconexão automática em caso de desconexão temporária do cliente Web. | O cliente tenta reconectar automaticamente a cada 2 segundos por até 1 minuto. |
| **RNF-09** | **Tolerância a Firewall Institucional** | O sistema deve trafegar exclusivamente pela sub-rede local interna via portas HTTP/WebSocket padrão. | Funcionamento normal mesmo em redes corporativas com bloqueio estrito de Discord, Zoom, Meet e conexões de saída. |