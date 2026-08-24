# Especificação de Casos de Uso (Use Cases)
## Projeto: AulaCast - Transmissão de Tela em Rede Local (IFPI)

---

### Mapeamento de Atores
- **Professor (Host):** Usuário do aplicativo nativo no macOS responsável por iniciar a transmissão, acompanhar a presença da turma e responder às dúvidas.
- **Aluno (Cliente):** Usuário do cliente Web que se identifica e conecta à sala na rede local para acompanhar a aula e enviar dúvidas.
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
  - *FA-01 (Mudar resolução/FPS):* O professor altera a resolução ou a taxa de quadros nas configurações, antes ou durante a transmissão; a mudança vale imediatamente, sem reiniciar a sessão.
  - *FA-02 (Trocar a fonte durante a aula):* O professor seleciona outro monitor ou janela na grade de fontes. O sistema troca o conteúdo transmitido sem encerrar a sessão nem desconectar os alunos.
  - *FA-03 (Pausar):* O professor congela a imagem para a turma sem encerrar a transmissão, e retoma depois.
- **Exceções:**
  - *EX-01 (Permissão de Captura Negada):* Se a permissão de Gravação de Tela do macOS não tiver sido autorizada, o app exibe uma tela explicativa e um botão que abre os Ajustes do Sistema na seção correta.
  - *EX-02 (Captura interrompida pelo sistema):* Se a captura cair sozinha (monitor desconectado, permissão revogada), o app encerra a sessão, exibe o motivo ao professor e avisa os alunos com `STREAM_ENDED`, em vez de deixar a imagem congelada sem explicação.
- **Pós-condição:** O stream de vídeo está ativo e a página Web do aluno fica disponível na rede local.

---

### UC-02: Conectar à Sala de Aula
- **Ator Principal:** Aluno
- **Pré-condição:** O computador do aluno está conectado à mesma rede local (Wi-Fi/Ethernet) que o Mac do professor, e o UC-01 foi executado.
- **Fluxo Principal:**
  1. O aluno abre qualquer navegador web (Chrome, Firefox, Safari, Edge).
  2. O aluno digita a URL da sala fornecida pelo professor (ex: `http://192.168.1.15:8080` ou `http://aulacast-prof.local:8080`).
  3. O navegador carrega a interface Web do AulaCast servida pelo app macOS.
  4. O sistema apresenta a tela de entrada e **só libera a aula após a identificação** (ver UC-06).
  5. O JavaScript do cliente estabelece uma conexão WebSocket com o servidor local.
  6. O servidor adiciona o novo cliente à lista de conexões ativas.
  7. O cliente abre o fluxo de vídeo em `GET /stream` e a tela do professor passa a ser exibida no player.
- **Exceções:**
  - *EX-01 (Servidor Indisponível):* Se o professor não tiver iniciado a transmissão, a página exibe "Reconectando à aula" e continua tentando sozinha, sem exigir recarregamento.
  - *EX-02 (Queda apenas do vídeo):* Como o vídeo trafega numa conexão separada do WebSocket, o cliente vigia o fluxo e o restabelece por conta própria, mesmo que o canal de mensagens permaneça ativo.
- **Pós-condição:** O aluno, já identificado, assiste à transmissão em tempo real.

---

### UC-03: Levantar a Mão (Pedir Ajuda)
- **Ator Principal:** Aluno
- **Atores Secundários:** Professor, Sistema
- **Pré-condição:** O aluno está conectado à transmissão (UC-02 ativo).
- **Fluxo Principal:**
  1. O aluno clica no botão **"Levantar a Mão"** na interface Web.
  2. O cliente Web envia uma mensagem WebSocket do tipo `RAISE_HAND` com a identificação do aluno.
  3. O aplicativo macOS do professor recebe a notificação.
  4. O sistema incrementa o contador de dúvidas na Barra de Menus e no painel principal.
  5. A linha do aluno é destacada na lista, com o ícone de mão levantada.
- **Fluxo Alternativo:**
  - *FA-01 (Abaixar a Mão):* O aluno clica novamente no botão, cancelando o pedido. O professor é atualizado.
- **Regra de negócio:** Assim como no Google Meet, **somente o próprio aluno abaixa a própria mão**. O professor apenas observa quem está com a mão levantada; não há ação de "marcar como atendido".

---

### UC-04: Enviar Mensagens no Chat Local
- **Ator Principal:** Aluno / Professor
- **Pré-condição:** Transmissão ativa (UC-01 e UC-02).
- **Fluxo Principal:**
  1. O aluno usa o painel de chat, sempre visível ao lado da transmissão.
  2. Digita uma mensagem de texto e pressiona Enter.
  3. O evento WebSocket `CHAT_MESSAGE` envia a mensagem para o servidor nativo no Mac.
  4. O servidor registra a mensagem no histórico da sessão e retransmite (broadcast) para todos os clientes conectados.
  5. A mensagem é renderizada instantaneamente nos chats de todos os alunos e no app do professor.

---

### UC-05: Encerrar Transmissão
- **Ator Principal:** Professor
- **Pré-condição:** Transmissão em andamento.
- **Fluxo Principal:**
  1. O professor clica em **"Parar Transmissão"**.
  2. O sistema para a captura do `ScreenCaptureKit`, encerra o servidor e fecha as conexões.
  3. O anúncio Bonjour é desativado.
  4. A página dos alunos passa a exibir o estado de reconexão, voltando sozinha caso o professor reinicie a transmissão.

---

### UC-06: Identificar-se para Entrar na Aula
- **Ator Principal:** Aluno
- **Atores Secundários:** Sistema, Professor
- **Pré-condição:** O aluno abriu o endereço da sala no navegador (UC-02, passo 3).
- **Fluxo Principal:**
  1. O sistema exibe a tela de entrada, cobrindo a aula.
  2. O aluno informa o **nome completo** e a **matrícula do IFPI** no formato `202XXXXTADSXXXX`.
  3. O cliente valida o formato e sinaliza o erro específico quando houver (tamanho, prefixo, curso ou dígitos).
  4. Ao enviar, o cliente transmite `IDENTIFY` pelo WebSocket.
  5. O servidor **revalida a matrícula** e responde `IDENTIFY_ACCEPTED`.
  6. A tela de entrada é liberada e o aluno passa a ver a transmissão.
  7. O nome e a matrícula aparecem na lista de presença do professor.
- **Fluxos Alternativos:**
  - *FA-01 (Retorno na mesma sessão):* Se o aluno recarregar a página, a identificação guardada na sessão é reaproveitada e ele entra direto.
- **Exceções:**
  - *EX-01 (Matrícula fora do padrão):* O cliente impede o envio e explica o que está errado.
  - *EX-02 (Cliente adulterado):* Se um `IDENTIFY` inválido chegar ao servidor sem passar pelo formulário, ele responde `IDENTIFY_REJECTED` e o aluno não entra na lista de presença.
- **Pós-condição:** O aluno está identificado e visível na lista de presença.

---

### UC-07: Acompanhar a Presença Efetiva da Turma
- **Ator Principal:** Professor
- **Atores Secundários:** Aluno, Sistema
- **Pré-condição:** Há alunos conectados (UC-02 e UC-06).
- **Fluxo Principal:**
  1. O cliente Web de cada aluno monitora se a aula está de fato à vista.
  2. Ao minimizar a janela, trocar de aba ou colocar outro aplicativo em foco, o cliente envia `PRESENCE` com `visible: false`.
  3. Ao retornar, envia `visible: true`.
  4. O app do professor atualiza o ícone da linha do aluno: **olho aberto** para quem está acompanhando, **olho cortado** para quem está apenas conectado.
  5. O cabeçalho da lista mostra quantos alunos estão realmente com a transmissão à vista.
- **Regra de negócio:** "Conectado" e "assistindo" são estados distintos. A contagem de presença efetiva considera apenas quem está com a aula visível.