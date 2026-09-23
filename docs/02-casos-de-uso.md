# Especificação de Casos de Uso (Use Cases)
## Projeto: AulaCast - Transmissão de Tela em Rede Local (IFPI)

---

### Mapeamento de Atores
- **Professor (Host):** Usuário do aplicativo nativo no macOS responsável por iniciar a transmissão, acompanhar a presença da turma, compartilhar arquivos e responder às dúvidas.
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
  7. O sistema atualiza o status para *"Transmitindo"* e exibe a URL local de acesso (ex: `192.168.1.15:8080`; o `http://` é opcional — o navegador completa, e o Chrome não mostra aviso de HTTP para IP de rede local).
- **Fluxos Alternativos:**
  - *FA-01 (Mudar resolução/FPS):* O professor altera a resolução ou a taxa de quadros nas configurações, antes ou durante a transmissão; a mudança vale imediatamente, sem reiniciar a sessão.
  - *FA-02 (Trocar a fonte durante a aula):* O professor seleciona outro monitor ou janela na grade de fontes. O sistema troca o conteúdo transmitido sem encerrar a sessão nem desconectar os alunos.
  - *FA-03 (Pausar):* O professor congela a imagem para a turma sem encerrar a transmissão, e retoma depois.
- **Exceções:**
  - *EX-01 (Permissão de Captura Negada):* Se a permissão de Gravação de Tela do macOS não tiver sido autorizada, o app **não inicia a transmissão** — nem a captura, nem o servidor — e exibe a tela explicativa com um botão que solicita a permissão e abre os Ajustes do Sistema na seção correta. A tela reaparece a cada tentativa de transmitir, e não apenas na abertura do app. Como o macOS só aplica a permissão a partir da próxima execução, a mesma tela oferece **Reabrir o AulaCast**, que fecha e reabre o aplicativo.
  - *EX-02 (Captura interrompida pelo sistema):* Se a captura cair sozinha (monitor desconectado, permissão revogada), o app exibe o motivo ao professor e avisa os alunos com `STREAM_ENDED`, em vez de deixar a imagem congelada sem explicação. O servidor continua no ar, para a turma seguir conectada: o professor pode iniciar a transmissão de novo ou encerrar a sessão pelo botão de parada ao lado de "Iniciar Transmissão".
  - *EX-03 (Janela transmitida fechada ou minimizada):* Fechar só a janela (com o aplicativo dela aberto) ou minimizá-la não gera erro no ScreenCaptureKit: os quadros apenas param. O app confere a janela a cada 0,7 s e, se ela sumir, pausa a transmissão (os alunos veem "Transmissão pausada", não uma imagem congelada) e diz ao professor qual janela sumiu. Quando a janela volta ou o professor escolhe outra fonte, a aula retoma sozinha. O app não troca para o monitor inteiro por conta própria, porque o professor escolheu uma janela justamente para não mostrar o resto da tela.
- **Pós-condição:** O stream de vídeo está ativo e a página Web do aluno fica disponível na rede local.

---

### UC-02: Conectar à Sala de Aula
- **Ator Principal:** Aluno
- **Pré-condição:** O computador do aluno está conectado à mesma rede local (Wi-Fi/Ethernet) que o Mac do professor, e o UC-01 foi executado.
- **Fluxo Principal:**
  1. O aluno abre qualquer navegador web (Chrome, Firefox, Safari, Edge).
  2. O aluno digita a URL da sala fornecida pelo professor (ex: `192.168.1.15:8080`; o `http://` é opcional — o navegador completa, e o Chrome não mostra aviso de HTTP para IP de rede local).
  3. O navegador carrega a interface Web do AulaCast servida pelo app macOS.
  4. O sistema apresenta a tela de entrada e **só libera a aula após a identificação** (ver UC-06).
  5. O JavaScript do cliente estabelece uma conexão WebSocket com o servidor local.
  6. O servidor adiciona o novo cliente à lista de conexões ativas.
  7. O cliente abre o fluxo de vídeo em `GET /stream` e a tela do professor passa a ser exibida no player.
- **Exceções:**
  - *EX-01 (Servidor Indisponível):* Se o professor não tiver iniciado a transmissão, a página exibe "Reconectando à aula" e continua tentando sozinha, sem exigir recarregamento.
  - *EX-02 (Queda apenas do vídeo):* Como o vídeo trafega numa conexão separada do WebSocket, o cliente vigia o fluxo e o restabelece quando o navegador acusa erro nele, e sempre que o WebSocket reconecta. Limitação conhecida: Chrome e Safari não avisam quando uma resposta MJPEG já iniciada é cortada, então a queda só do vídeo, com o WebSocket de pé, pode deixar a imagem parada até a próxima reconexão.
- **Pós-condição:** O aluno, já identificado, assiste à transmissão em tempo real.

---

### UC-03: Levantar a Mão (Pedir Ajuda)
Foi retirado e voltou a pedido da turma, como um ícone pequeno ao lado do campo de mensagem.
- **Ator:** Aluno (e Professor).
- **Fluxo:**
  1. O aluno toca na mão; ela fica preenchida e o servidor confirma (`RAISE_HAND_ACK`).
  2. No professor, o aluno sobe para o topo da lista com a mão destacada, e o botão Alunos mostra quantas mãos há.
  3. O aluno abaixa a mão no mesmo ícone, ou o professor abaixa pela lista (`HAND_LOWERED`), e o aluno vê "O professor abaixou sua mão".
- **Regras:** vale só para aluno identificado; funciona com o chat desligado; ao reconectar, a mão é reenviada.

---

### UC-04: Enviar Mensagens no Chat Local
- **Ator Principal:** Aluno / Professor
- **Pré-condição:** Transmissão ativa (UC-01 e UC-02).
- **Fluxo Principal (aluno escreve):**
  1. O aluno usa o painel de conversa, sempre visível ao lado da transmissão.
  2. Digita uma mensagem de texto e pressiona Enter.
  3. O cliente envia `CHAT_SEND` ao servidor no Mac.
  4. O servidor entrega a mensagem **ao app do professor** e a devolve **apenas ao autor**,
     para que ele veja o próprio texto no histórico.
- **Fluxo Principal (professor responde):**
  1. O professor escreve no painel de chat do aplicativo.
  2. O servidor retransmite a mensagem para **todos** os alunos conectados.
- **Regra de negócio:** a conversa do aluno é **reservada com o professor**. Mensagens de aluno
  não circulam pela turma; só as do professor são vistas por todos. Retransmiti-las a todos
  transformava o chat em conversa paralela durante a aula.

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
  2. O aluno informa o **nome completo**.
  3. O cliente valida o preenchimento e sinaliza o erro específico quando houver (campo vazio ou nome curto demais).
  4. Ao enviar, o cliente transmite `IDENTIFY` pelo WebSocket.
  5. A tela de entrada é liberada e o aluno passa a ver a transmissão.
  6. O servidor **revalida o nome** (de 2 a 40 caracteres) e responde `IDENTIFY_ACCEPTED`; se responder `IDENTIFY_REJECTED`, a tela de entrada volta com o motivo e o nome salvo é descartado.
  7. O nome aparece na lista de presença do professor.
- **Fluxos Alternativos:**
  - *FA-01 (Retorno na mesma sessão):* Se o aluno recarregar a página, a identificação guardada na sessão é reaproveitada e ele entra direto.
- **Exceções:**
  - *EX-01 (Nome não preenchido):* O cliente impede o envio e explica o que está errado.
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

---

### UC-08: Compartilhar Arquivos com a Turma
- **Ator Principal:** Professor
- **Atores Secundários:** Aluno, Sistema
- **Pré-condição:** O app está aberto; para os alunos baixarem, o servidor precisa estar no ar (UC-01).
- **Fluxo Principal:**
  1. O professor clica em **Compartilhar** no painel "Arquivos da Aula" (ou arrasta arquivos para ele) e escolhe um ou mais arquivos, de qualquer tipo.
  2. O sistema registra cada arquivo com um identificador sorteado e envia a lista nova a todos os alunos conectados (`FILES`).
  3. A página do aluno mostra "Arquivos do professor" com nome e tamanho; no celular, o botão do menu ganha um ponto e o chat avisa "O professor compartilhou: …".
  4. O aluno toca no arquivo e o navegador o baixa (`GET /arquivos/<id>`), com o nome original.
  5. No painel do professor, cada arquivo mostra "Disponível para N alunos" (a lista já chegou à página deles), e, conforme a turma termina de baixar, "n de N baixaram" (downloads em andamento não aparecem). Compartilhar não envia nada — o arquivo fica no Mac e cada aluno baixa direto dele —, então o que o professor acompanha são os downloads, não um envio.
- **Fluxos Alternativos:**
  - *FA-01 (Parar de compartilhar):* O professor remove o arquivo da lista; ele some da página dos alunos e o link passa a responder 404.
  - *FA-02 (Aluno chega depois):* A lista vai nas boas-vindas (`CONNECTED`).
- **Exceções:**
  - *EX-01 (Pasta):* Pastas não são compartilhadas; o painel pede para compactá-las antes.
  - *EX-02 (Arquivo apagado ou movido do disco):* O download responde 404, sem afetar a transmissão.
- **Regra de negócio:** O aluno só alcança os arquivos da lista, pelo identificador; não há como chegar a outro arquivo do Mac pela URL.
