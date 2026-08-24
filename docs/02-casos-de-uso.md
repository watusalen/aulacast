# Especificação de Casos de Uso (Use Cases)
## Projeto: AulaCast - Transmissão de Tela em Rede Local (IFPI)

---

### Mapeamento de Atores
- **Professor (Host):** Usuário do aplicativo nativo no macOS responsável por iniciar a transmissão, gerenciar a sala, compartilhar arquivos e atender a dúvidas.
- **Aluno (Cliente):** Usuário do cliente Web (ou app) que conecta à sala na rede local para acompanhar a aula, enviar dúvidas e baixar arquivos.
- **Sistema (AulaCast Server):** O módulo de backend nativo em Swift rodando no Mac que gerencia a captura de tela, codificação, servidor HTTP/WebSocket e o estado da sala.

---

### UC-01: Iniciar Transmissão de Tela
- **Ator Principal:** Professor
- **Pré-condição:** O aplicativo AulaCast está aberto no macOS e com permissão de captura de tela concedida.
- **Fluxo Principal:**
  1. O professor abre o aplicativo AulaCast.
  2. O sistema detecta os monitores e janelas abertas e exibe no painel principal.
  3. O professor seleciona a fonte de transmissão (ex: "Display 1").
  4. O professor clica no botão **"Iniciar Transmissão"**.
  5. O sistema inicia a captura via `ScreenCaptureKit` e o servidor HTTP/WebSocket na porta 8080.
  6. O sistema ativa o anúncio de rede via Bonjour (`_aulacast._tcp`).
  7. O sistema atualiza o status para *"Transmitindo"* e exibe a URL local de acesso (ex: `http://192.168.1.15:8080`).
- **Fluxos Alternativos:**
  - *FA-01 (Mudar resolução/FPS):* Antes de clicar em Iniciar, o professor altera a taxa de quadros de 30fps para 15fps nas configurações.
- **Exceções:**
  - *EX-01 (Permissão de Captura Negada):* Se a permissão de Gravação de Tela do macOS não tiver sido autorizada nas Preferências do Sistema, o app exibe um alerta explicativo e um botão para abrir as Configurações do macOS.
  - *EX-02 (Porta 8080 Ocupada):* Se a porta 8080 estiver em uso por outra aplicação, o sistema tenta a porta 8081 automaticamente e notifica o professor.
- **Pós-condição:** O stream de vídeo está ativo e a página Web do aluno fica disponível na rede local.

---

### UC-02: Conectar à Sala de Aula
- **Ator Principal:** Aluno
- **Pré-condição:** O computador do aluno está conectado à mesma rede local (Wi-Fi/Ethernet) que o Mac do professor, e o UC-01 foi executado.
- **Fluxo Principal:**
  1. O aluno abre qualquer navegador web (Chrome, Firefox, Safari, Edge).
  2. O aluno digita a URL da sala fornecida pelo professor (ex: `http://192.168.1.15:8080` ou `http://aulacast-prof.local:8080`).
  3. O navegador carrega a interface Web do AulaCast servida pelo app macOS.
  4. O JavaScript do cliente estabelece uma conexão WebSocket com o servidor local.
  5. O servidor adiciona o novo cliente à lista de conexões ativas e começa a enviar os quadros de vídeo.
  6. A tela do professor passa a ser exibida no player do aluno.
- **Exceções:**
  - *EX-01 (Servidor Indisponível):* Se o professor não tiver iniciado a transmissão, o navegador exibe "Não foi possível conectar ao servidor". O cliente Web tenta reconectar automaticamente a cada 2s.
- **Pós-condição:** O aluno assiste à transmissão em tempo real.

---

### UC-03: Levantar a Mão (Pedir Ajuda)
- **Ator Principal:** Aluno
- **Atores Secundários:** Professor, Sistema
- **Pré-condição:** O aluno está conectado à transmissão (UC-02 ativo).
- **Fluxo Principal:**
  1. O aluno clica no botão **"Levantar a Mão"** na interface Web.
  2. O aluno é solicitado a inserir seu nome (caso ainda não tenha inserido).
  3. O cliente Web envia uma mensagem WebSocket do tipo `RAISE_HAND` com o nome do aluno.
  4. O aplicativo macOS do professor recebe a notificação.
  5. O sistema reproduz um som discreto no Mac do professor e incrementa o contador de dúvidas na Barra de Menus e no painel principal.
  6. O nome do aluno aparece destacado na lista de atendimento.
- **Fluxo Alternativo:**
  - *FA-01 (Abaixar a Mão):* O aluno clica novamente no botão **"Abaixar a Mão"**, cancelando o pedido. O professor é atualizado.
  - *FA-02 (Professor Atende):* O professor clica no ícone de checagem ao lado do nome do aluno na lista do Mac, marcando como atendido.

---

### UC-04: Compartilhar Arquivos com a Turma
- **Ator Principal:** Professor
- **Pré-condição:** Transmissão ativa (UC-01).
- **Fluxo Principal:**
  1. O professor arrasta um arquivo (ex: `exercicio_aula.py` ou `slides.pdf`) para a área de compartilhamento no app macOS.
  2. O sistema salva o arquivo no diretório público temporário da sessão.
  3. O sistema envia um evento WebSocket `NEW_FILE` para todos os alunos conectados.
  4. A aba **"Arquivos da Aula"** na interface Web dos alunos atualiza em tempo real mostrando o novo arquivo, tamanho e um botão **"Baixar"**.
  5. O aluno clica em **"Baixar"** e o navegador faz o download direto via HTTP GET na rede local.
- **Exceções:**
  - *EX-01 (Arquivo Excede Tamanho Máximo):* Se o arquivo for maior que 100MB, o app do professor exibe um aviso recomendando compactar o arquivo.

---

### UC-05: Enviar Mensagens no Chat Local
- **Ator Principal:** Aluno / Professor
- **Pré-condição:** Transmissão ativa (UC-01 e UC-02).
- **Fluxo Principal:**
  1. O aluno (ou professor) abre a aba de Chat na interface.
  2. Digita uma mensagem de texto e pressiona Enter.
  3. O evento WebSocket `CHAT_MESSAGE` envia a mensagem para o servidor nativo no Mac.
  4. O servidor registra a mensagem no histórico da sessão e retransmite (broadcast) para todos os clientes conectados.
  5. A mensagem é renderizada instantaneamente nos chats de todos os alunos e no app do professor.

---

### UC-06: Encerrar Transmissão
- **Ator Principal:** Professor
- **Pré-condição:** Transmissão em andamento.
- **Fluxo Principal:**
  1. O professor clica em **"Encerrar Transmissão"**.
  2. O sistema exibe um diálogo de confirmação.
  3. Ao confirmar, o sistema para a captura do `ScreenCaptureKit`, encerra o encoder de vídeo e fecha os WebSockets de forma limpa enviando um evento `STREAM_ENDED`.
  4. O anúncio Bonjour é desativado.
  5. A página dos alunos exibe a mensagem *"A transmissão foi encerrada pelo professor"*.