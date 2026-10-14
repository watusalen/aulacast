# Documento de Arquitetura & Design de Software
## Projeto: AulaCast - Transmissão de Tela em Rede Local (IFPI)

---

### 1. Visão Geral da Arquitetura de Software

O **AulaCast** segue uma arquitetura baseada em **Host Nativo (macOS)** e **Clientes Leves (Web)** conectados por uma rede de área local (LAN). O servidor embarcado utiliza a API moderna de redes da Apple (`Network.framework`) para servir conteúdo estático (HTML/CSS/JS) e gerenciar conexões bidirecionais persistentes via **WebSockets**.

```mermaid
flowchart TB
    subgraph Host["Host macOS (App do Professor)"]
        UI["SwiftUI Dashboard"]
        SCK["ScreenCaptureKit Engine"]
        ENC["MJPEGFrameEncoder (CoreImage + GPU)"]
        NET["Network.framework (HTTP & WebSocket Server)"]
        MDNS["Bonjour / mDNS Advertiser"]

        UI --> SCK
        SCK --> ENC
        ENC --> NET
        UI <--> NET
        NET <--> MDNS
    end

    subgraph LAN["Rede Local LAN (Wi-Fi / Ethernet IFPI)"]
        WS1["Cliente Web 1 (Linux Lab IFPI)"]
        WS2["Cliente Web 2 (Windows / macOS)"]
    end

    NET <--> WS1
    NET <--> WS2
```

---

### 2. Componentes Principais do App macOS (Swift)

#### 2.1. `ScreenCaptureService` (`ScreenCaptureKit`)
- **Responsabilidade:** Capturar o conteúdo dos monitores ou janelas selecionadas com alta taxa de quadros e baixo overhead de memória.
- **Implementação:** Utiliza `SCStream` e `SCStreamOutput`. Envia amostras de vídeo (`CMSampleBuffer`) para o codificador.
- **Parâmetros:** formato `32BGRA`, `queueDepth = 5` (`ScreenCaptureService.swift:228`), fps padrão 30 (opções 15/30/45) e resolução 1080p ou 720p, na proporção da fonte e sem ampliar.
- **Ocultar apps (RF-19):** o menu de botão direito aparece nos cartões de janela (`SourcePickerView`) e marca o app inteiro (`hiddenBundleIDs`). A marcação só tem efeito quando o monitor é a fonte: `filtroDeMonitor` exclui esses apps da captura, mesmo em tela cheia. A escolha não é guardada entre execuções.

#### 2.2. `MJPEGFrameEncoder` (`CoreImage`)
- **Responsabilidade:** Converter `CMSampleBuffer` em quadros JPEG.
- **Decisões relevantes:**
  - O `CIContext` é criado **uma única vez** e reaproveitado. Recriá-lo por quadro compila shaders e aloca recursos de GPU repetidamente, inviabilizando o tempo real.
  - Quadros novos são **descartados enquanto o anterior ainda está sendo codificado**. Sem isso, uma codificação mais lenta que a captura enfileira quadros e o atraso cresce indefinidamente.
- **Qualidade:** JPEG fixo em 0,6 (`MJPEGFrameEncoder.swift:26`), sem ajuste conforme a rede.
- **Saída:** `Data` com o JPEG pronto para envio.

#### 2.3. `NetworkListenerService` & `WebSocketHandlerService` (`Network.framework`)
- **Responsabilidade:** Subir o ouvinte (`NWListener`) na porta 8080.
- **Rotas HTTP:**
  - `GET /`: Entrega o arquivo `index.html` (Player do Aluno).
  - `GET /styles.css` e `GET /js/*`: Recursos estáticos do cliente.
  - `GET /stream`: Fluxo de vídeo em `multipart/x-mixed-replace` (MJPEG), consumido por uma tag `<img>`. Servido por `MJPEGStreamerService`: um laço por aluno, que só envia o próximo quadro depois de o anterior sair **do app para o buffer de envio do sistema**, não até o aluno (ver 4.1.1).
  - `GET /arquivos/<id>`: download de arquivo compartilhado (`FileDownloadService`).
- **Rota WebSocket (`/ws`):** Gerencia conexões ativas e a troca de mensagens JSON (identificação, presença, chat e lista de arquivos).

> **O vídeo não trafega pelo WebSocket.** São duas conexões independentes: MJPEG sobre HTTP para a imagem e WebSocket para as mensagens. Por isso o cliente vigia as duas separadamente — uma pode cair enquanto a outra segue viva.

#### 2.4. `WebSocketFrameDecoder`
- **Responsabilidade:** Decodificar frames RFC 6455, isoladamente do gerenciamento de conexões.
- **Motivo de existir separado:** o TCP não respeita fronteira de mensagem. Uma leitura pode trazer dois frames colados ou metade de um, então o decodificador mantém um buffer próprio por conexão. Tratar cada leitura como exatamente um frame descartava mensagens em silêncio.

#### 2.5. `BonjourAdvertiserService` e `MDNSHostnameService`
- **Responsabilidade:** Anunciar o serviço `_aulacast._tcp` usando `NWListener.service` no **próprio listener do servidor**, na porta fixa 8080. Antes o anúncio saía de um segundo listener, em porta sorteada a cada execução: quem achava a sala pelo Bonjour recebia uma porta que recusava conexão, e a porta mudava de aula para aula (ruim para liberar o app no firewall). Um nome repetido na rede é renomeado pelo sistema ("AulaCast - IFPI (2)") sem derrubar o servidor.
- **Nome `aulacast.local`:** `MDNSHostnameService` registra o nome por mDNS e o painel passa a mostrar `aulacast.local:8080` com a sessão aberta (`MainViewModel.swift:14-30`); antes disso mostra o IP. Redirecionar a porta 80 para esconder o `:8080` foi tentado e revertido (commit `0d38433`; `MainViewModel.swift:21-24`). Ver ADR-002.
- **Duas transmissões na rede:** o registro é único e o sistema avisa o conflito (`NameConflict`); `MDNSHostnameService` tenta `aulacast-2.local`, `-3` etc. (`proximoPasso`, até `maxAttempts` = 20). O nome só é divulgado depois de confirmado e é retirado ao se perder (conflito tardio, queda do `mDNSResponder`, troca de IP: `MainViewModel.updateServerURL`); sem nome confirmado ou sem rede (loopback), o painel mostra o IP. O `MainViewModel` recebe o serviço pelo protocolo `HostnameAdvertisingProtocol`, o que permite testá-lo com um dublê.

#### 2.6. Serviços de apoio
- `SystemActivityService`: evita o App Nap durante a transmissão.
- `SourceThumbnailProvider`: miniaturas da grade de fontes.
- `WebSocketFrameEncoder`: monta frames RFC 6455 de saída (par do `WebSocketFrameDecoder`).
- `FileDownloadService` e `SharedFile`: arquivos compartilhados (RF-17).

---

### 3. Protocolo de Comunicação WebSocket (JSON Schemas)

Toda a comunicação interativa utiliza o protocolo WebSocket na rota `/ws`. As mensagens trafegam em formato JSON estruturado com o campo `type`.

#### 3.1. Mensagem de Boas-Vindas (`CONNECTED`)
Enviada pelo servidor assim que o aluno conecta. Carrega o estado atual do chat e da
transmissão: sem isso, quem entra (ou reconecta) no meio da aula veria o campo de mensagem
liberado com o chat desligado, ou o último quadro congelado como se a aula estivesse ao vivo
quando ela está pausada ou encerrada. `stream` é `live`, `paused` ou `ended` (este com
`reason`). `chatVisibleToClass` diz se a conversa entre alunos está aberta (seção 3.12). `files` é a lista de arquivos compartilhados (seção 3.4). `pinned` só vem quando há mensagem fixada (seção 3.11).
```json
{
  "type": "CONNECTED",
  "payload": {
    "chatEnabled": true,
    "chatVisibleToClass": false,
    "stream": "paused",
    "files": [],
    "pinned": "Portal do Aluno: https://portal.exemplo.edu.br"
  }
}
```

#### 3.2. Identificação do Aluno (`IDENTIFY`)
Enviada pelo aluno na entrada. O servidor **revalida** o nome (de 2 a 40 caracteres) e
responde `IDENTIFY_ACCEPTED` ou `IDENTIFY_REJECTED` (com `payload.reason`). Só depois disso o
aluno aparece na lista do professor. O nome aceito fica guardado por conexão e é ele que
assina o chat.
```json
{
  "type": "IDENTIFY",
  "payload": {
    "name": "Ana Beatriz Sousa"
  }
}
```

#### 3.3. Presença na Tela (`PRESENCE`)
Enviada pelo aluno quando a aula deixa de estar (ou volta a estar) à vista.
```json
{
  "type": "PRESENCE",
  "payload": {
    "visible": false
  }
}
```

#### 3.4. Arquivos Compartilhados (`FILES` e `GET /arquivos/<id>`)
Enviada pelo servidor a todos quando o professor compartilha ou remove um arquivo; a mesma
lista vai em `payload.files` do `CONNECTED`. O download é uma requisição HTTP comum na porta
8080: o servidor só entrega arquivos da lista, pelo `id` sorteado, como
`application/octet-stream` com `Content-Disposition: attachment` (nome original em UTF-8,
RFC 6266/5987, e um nome só ASCII de reserva). O arquivo é lido do disco em pedaços de
256 KB, e o próximo só sai quando o anterior foi entregue — um arquivo grande não vai
inteiro para a memória. Id desconhecido, arquivo removido ou apagado do disco: 404.
```json
{
  "type": "FILES",
  "payload": {
    "files": [
      { "id": "5E0C…", "name": "Lista 3.pdf", "size": 184320 }
    ]
  }
}
```

#### 3.5. Envio de Mensagem de Chat (`CHAT_SEND`)
Mensagem de aluno vai ao professor e retorna **somente ao autor**. Já a mensagem do professor
é retransmitida a todos. O servidor é quem impõe essa separação — o cliente não decide. O
remetente é o nome aceito no `IDENTIFY` (um `sender` na mensagem é ignorado), e o texto é
cortado em 1000 caracteres. A resposta chega como `CHAT_MESSAGE` (`sender`, `text`, `isProf`).
```json
{
  "type": "CHAT_SEND",
  "payload": {
    "text": "Professor, como compilar o código pelo Terminal?"
  }
}
```

#### 3.6. Estado do Chat (`CHAT_STATE`)
Enviada a todos os alunos quando o professor liga ou desliga o chat nas configurações. O
servidor já descartava as mensagens com o chat desligado, mas em silêncio: o aluno escrevia,
enviava e o texto sumia sem explicação. Agora o campo e o botão ficam inativos na hora, sem
anunciar à turma que o professor desligou o chat. O descarte no servidor continua valendo — um
cliente adulterado que reative o campo segue sem alcançar o professor.
```json
{
  "type": "CHAT_STATE",
  "payload": {
    "enabled": "false"
  }
}
```

#### 3.7. Estado da Transmissão
Mensagens de controle enviadas pelo servidor: `STREAM_STARTED` quando a transmissão começa
(ou recomeça depois de uma queda), `STREAM_PAUSED` e `STREAM_RESUMED` quando o professor
congela ou retoma a imagem, e `STREAM_ENDED` quando a captura termina. O último estado
anunciado é repetido no `CONNECTED` de quem chega depois.
```json
{
  "type": "STREAM_ENDED",
  "payload": {
    "reason": "O monitor utilizado foi desconectado."
  }
}
```

#### 3.8. Batimento (`PING` / `PONG`)
O cliente manda `{"type":"PING"}` a cada 10 s e o servidor responde `{"type":"PONG"}`. Sem
nenhuma mensagem do servidor por 25 s, o cliente dá a conexão por morta e reconecta; sem
nenhum frame do cliente por 30 s, o servidor a encerra e tira o aluno da lista. É o que pega
o notebook que dormiu ou saiu do Wi-Fi sem fechar a conexão.

#### 3.9. Regras do protocolo impostas pelo servidor
Frames do navegador precisam vir mascarados. Frames de controle têm até 125 bytes e não são
fragmentados. Opcodes reservados e bits RSV encerram a conexão. Um `CLOSE` recebido é
devolvido antes de fechar.

#### 3.10. Mão levantada (`RAISE_HAND`, `RAISE_HAND_ACK`, `HAND_LOWERED`)
O aluno levanta ou abaixa a mão com `{"type":"RAISE_HAND","payload":{"active":true}}`, e o
servidor confirma com `RAISE_HAND_ACK` (mesmo `active`). Só vale depois do `IDENTIFY`
aceito, e o nome é sempre o do `IDENTIFY`, nunca um campo do payload: de outra forma um aluno
levantaria a mão em nome de um colega. Quando o professor abaixa a mão de alguém, só aquele
aluno recebe `{"type":"HAND_LOWERED"}`. A mão é estado da conexão: ao reconectar, o cliente
reenvia `RAISE_HAND` logo depois do `IDENTIFY`; ao sair, a mão sai com ele.

#### 3.11. Mensagem fixada (`CHAT_PINNED`)
O professor fixa uma mensagem sua (um link do Portal do Aluno, o prazo de uma lista) e ela
fica no topo do chat de toda a turma. Uma por vez: fixar outra substitui. O texto vai
serializado por `JSONSerialization` (aspas e quebras de linha chegam intactas); `null`
desafixa. Quem entra depois recebe a fixada no `CONNECTED`.
```json
{ "type": "CHAT_PINNED", "payload": { "text": "Lista 4: https://portal.exemplo.edu.br/l4" } }
{ "type": "CHAT_PINNED", "payload": { "text": null } }
```

#### 3.12. Chat entre alunos (`CHAT_VISIBILITY`)
Opção do professor (RF-18), **desligada por padrão**. Enviada a todos os alunos quando muda,
e o valor atual vai no `CONNECTED` (`chatVisibleToClass`). Com ela ligada, o servidor entrega a
mensagem do aluno a toda a turma, sem duplicar para o autor (`WebSocketHandlerService.swift:527-531`).
`visible` vai como string, como em `CHAT_STATE`. Ver ADR-003.
```json
{ "type": "CHAT_VISIBILITY", "payload": { "visible": "true" } }
```

#### 3.13. Métricas (`METRICS` / `METRICS_TABLE`)
**Só existe em build de depuração ou com `-DMETRICAS_DEBUG`** (`AULACAST_DEBUG_METRICS=1 scripts/build-app.sh`; `MetricasDebug.ativo`). Num build normal o `CONNECTED` não traz `metricas: "true"`, o navegador fica totalmente ocioso e o servidor ignora `METRICS`.

Cada 5 s o navegador manda a própria medição; o servidor (só de aluno já identificado) valida, guarda a última por conexão e, no mesmo relógio de 5 s do `[Métricas]`, manda a tabela a todos. **Todos veem os números e os nomes de todos, por decisão do usuário**; aparecem só no console (DevTools), nunca na página.
```json
{ "type": "METRICS", "payload": { "rota": "H.264", "fps": 29.5, "mbps": 2.25, "dropped": 2, "lagMs": 150 } }
{ "type": "METRICS_TABLE", "payload": { "alunos": 2, "alunosH264": 1, "alunosMJPEG": 1, "telaFps": 30, "mediaFps": 28, "minimoFps": 25, "mbps": 4.2,
  "rows": [ { "nome": "Ana", "rota": "H.264", "fps": 29.5, "mbps": 2.25, "dropped": 2, "lagMs": 150, "reportadoHa": 1.2 } ] } }
```
Validação: chaves conhecidas, `rota` em {`H.264`,`MJPEG`}, números finitos limitados (fps 0-240, mbps 0-1000, dropped >= 0, lagMs 0-3600000), 1 mensagem aceita por segundo por cliente, até 100 linhas; a linha some na desconexão. Na rota MJPEG o navegador não mede por quadro: manda só a rota e os números vão `null`.
Arquivo da sessão (também só no modo de depuração): `~/AulaCast-metricas/sessao-AAAAMMDD-HHmmss.jsonl`, um JSON por linha (`inicio`, `amostra` a cada 5 s com alunos conectados, `entrada`, `saida`, `fim`), limitado a ~20 MB (`truncado`).

`METRICS_TABLE` também traz `estourosDeFila`, `pedidosDeQuadroChave` e `bytesTotais` (bytes entregues ao buffer do sistema, MJPEG + H.264).
**`DEBUG_INFO` (mesma trava `metricas`)**: logo depois do `CONNECTED`, uma vez por conexão, `{ versao, porta, ip, h264, h264TaxaMinBps, h264TaxaMaxBps, quadroChaveMaxSeg, maxMp4PorIp, maxMp4Total, filaMaxBytes, filaMaxMs, pedidoQuadroChaveMs }`. Fps/resolução da captura, taxa-alvo exata e nome mDNS não vão (vivem no `MainViewModel`; acoplar o servidor a eles não compensa).
**Painel de depuração do aluno** (`debug-panel.js`): botão "Debug" e gaveta (folha inferior em tela estreita), criados só com `metricas: "true"`; abre expandido uma vez ao entrar. Traz a explicação de ponta a ponta e um log ao vivo (anel de 500 linhas, ms) de WebSocket, PING/PONG com RTT, tipos de mensagem do servidor (nunca o texto do chat), rota/codec/init segment, fragmentos, MSE, buffer, atraso, `playbackRate`, seeks e visibilidade, com "Copiar log" (fallback para http) e "Baixar .txt". Os módulos chamam `globalThis.AulaCastDebug?.log(...)`, que só existe com o painel.

---

### 4. Diagrama de Sequência: Fluxo de Transmissão & Interação

```mermaid
sequenceDiagram
    autonumber
    actor Prof as Professor (Mac)
    participant App as AulaCast macOS App
    participant Net as Embedded Server (8080)
    actor Aluno as Aluno (Web Client)

    Prof->>App: Clica em "Iniciar Transmissão"
    App->>App: Inicializa ScreenCaptureKit e o codificador MJPEG
    App->>Net: Sobe NWListener HTTP/WebSocket na porta 8080
    App->>Net: Ativa Anúncio Bonjour (_aulacast._tcp)

    Aluno->>Net: Digita aulacast.local:8080 (ou o IP) no navegador
    Net-->>Aluno: Retorna index.html, styles.css e os módulos JS
    Aluno->>Aluno: Preenche o nome na tela de entrada
    Aluno->>Net: Conecta ao WebSocket /ws
    Net-->>App: Novo cliente conectado (+1)
    Aluno->>Net: IDENTIFY (nome)
    Net->>Net: Revalida o nome no servidor
    Net-->>Aluno: IDENTIFY_ACCEPTED
    Net-->>App: Registra o aluno na lista de presença

    Aluno->>Net: GET /stream (conexão HTTP separada)
    loop Enquanto houver quadros novos
        App->>Net: Entrega quadro JPEG
        Net->>Aluno: Envia parte do multipart MJPEG
    end

    Aluno->>Net: PRESENCE (visible: false) ao sair da tela
    Net-->>App: Marca o aluno como "não assistindo"

    Prof->>App: Compartilha "Lista 3.pdf"
    App->>Net: Atualiza a lista de arquivos
    Net-->>Aluno: FILES (lista nova)
    Aluno->>Net: GET /arquivos/<id>
    Net-->>Aluno: Arquivo, em pedaços de 256 KB
```

---

### 4.1. Desempenho: o que foi medido e comparado com as práticas consolidadas

Medições feitas num MacBook Air (Apple Silicon), monitor 1470x956 pontos (Retina), 30 fps.

| Ponto | Prática de referência | Antes | Agora |
| :--- | :--- | :--- | :--- |
| Codificação JPEG | Trabalho mínimo por quadro na fila da captura (guia do ScreenCaptureKit) | `CIContext` → `CGImage` → `NSBitmapImageRep`: 6,0 ms de CPU por quadro 1080p | `CIContext.jpegRepresentation` direto do pixel buffer: 1,0 ms, mesmo tamanho de arquivo |
| CPU do app transmitindo | — | ~31% de um núcleo (monitor), ~27% (janela) | ~16% (monitor), ~14% (janela) |
| Tamanho da captura | Saída na proporção da fonte (exemplo "Capturing screen content in macOS" da Apple) | 16:9 fixo: faixas pretas no monitor 16:10; janela encostada no canto | Proporção da fonte, limitada a 1920x1080 ou 1280x720, sem ampliar |
| Último quadro no Safari | Repetir o último quadro quando a imagem para (como fazem servidores MJPEG como o µStreamer) | O WebKit só desenha uma parte quando a próxima chega (bug 36536): a turma via o quadro anterior, e quem entrava com a tela parada não via nada | O último quadro é repetido uma vez, 150 ms depois de a imagem parar |
| Delimitador multipart | RFC 2046: o separador é `--` + boundary | Cabeçalho declarava `boundary=--frame` e o corpo usava `--frame` | `boundary=frame` |
| Quadros `.idle` / `.suspended` | Descartar o que não é `.complete` (exemplo da Apple) | Já chegam sem imagem e morrem no codificador, sem custo | Igual |
| Janela transmitida sumiu | Consulta periódica (o exemplo da Apple consulta o conteúdo a cada 3 s) | — | `CGWindowListCopyWindowInfo` de uma janela a cada 0,7 s: 77 µs por consulta, 0,011% de um núcleo. O status `.suspended` do ScreenCaptureKit também avisa, mas não veio em todos os fechamentos medidos, então não serve sozinho |

Protocolo: MJPEG sobre HTTP continua sendo a escolha certa para o requisito de zero
instalação e rede local. WebRTC (usado pelo Deskreen) exige negociação e UDP; H.264 sobre
WebSocket com WebCodecs acumula atraso quando a rede congestiona, porque o TCP entrega tudo
em ordem — foi o motivo de a Helix.ml voltar a JPEG sequencial. O AulaCast faz algo parecido: cada aluno só recebe o próximo quadro quando o anterior terminou de sair
do app. Isso vale até o buffer de envio do sistema, não até o aluno, e a escolha do MJPEG foi
reavaliada para turmas grandes (4.1.1).

Fontes: exemplo "Capturing screen content in macOS" (Apple); WWDC22 10156 e 10155; README
do µStreamer (pikvm/ustreamer); bug 36536 do WebKit; bug 987135 do Firefox; "We Mass-Deployed
15-Year-Old Screen Sharing Technology" (blog da Helix.ml).

### 4.1.1. Limite de escala conhecido (RNF-10, Proposto)

O quadro é codificado **uma vez** e guardado em `latestFrameData`, mas cada aluno recebe uma
**cópia própria** por uma conexão TCP própria (`MJPEGStreamerService`). Com n alunos e quadro
de S bytes, o custo por quadro é O(n·S) de rede e de cópias de memória; só a codificação é O(1).

- **Banda (estimativa de pior caso, não medida):** com a tela mudando a 30 fps, 1080p e JPEG 0,6,
  ~150–250 KB por quadro dão ~36–60 Mbps por aluno e ~1,4–2,4 Gbps para 40 alunos. Com um Wi-Fi
  **suposto** de 100–300 Mbps úteis, seriam ~2–5 fps por aluno. Com a tela parada o servidor não envia
  quadros novos, então o número real depende do conteúdo. Falta medir (Fase 0).
- **Sem adaptação:** qualidade e fps não mudam com a rede, e o app não limita o buffer de envio (o atraso cresce até o tamanho do buffer do sistema).
  `.contentProcessed` indica que o dado entrou no buffer do sistema, não que o aluno o recebeu;
  um aluno lento acumula quadros velhos e vê atraso e rajadas.
- **Repetição por causa do Safari:** o último quadro é repetido uma vez (bug 36536 do WebKit) para
  **todos** os alunos, não só os do Safari: é uma rajada extra de n×S a cada pausa da tela.
- **Como medir:** o servidor escreve no log, a cada 5 s e só com alunos com o vídeo aberto, uma
  linha `[Métricas] N alunos | tela X fps | por aluno: média Y fps, mínimo Z fps | W Mbps`.
  Vem de contadores no `MJPEGStreamerService` (quadros publicados, bytes e quadros distintos por
  aluno) e de `StreamRates.entre` (diferença entre duas fotografias, dividida pelo tempo real do
  intervalo). É o que chegou ao buffer de envio do sistema, **um teto** do que o aluno vê; a
  repetição do Safari conta bytes, mas não quadros. O fps por aluno no navegador não é medido.
- **Direção em estudo:** codec com predição entre quadros (H.264 em fMP4, via MSE no navegador,
  sem app no aluno), mantendo o MJPEG como compatibilidade. Há uma implementação de referência
  na branch local `compressao-video-h264` (commit `c63592b`), fora da main. Integrado na branch `integracao-teste`: ver ADR-004 (Proposto) e a medição `[Métricas]`.
  As metas numéricas dependem de medição (RNF-10).

### 4.2. Tela do professor: Material 3 Expressive no desenho do Google Meet

A tela do professor segue o **Material 3 Expressive** (Google, 2025) e a organização do **Google Meet**:
um palco escuro com a prévia, uma barra de controles embaixo e um painel lateral que mostra uma área por vez.
Continua mínima: cada informação tem um lugar só.

- **Barra inferior em três partes, como a do Meet:**
  - *Esquerda:* estado da aula num chip ("Ao vivo 12:04", "Pausada", "Interrompida", "Fora do ar") e o endereço
    da turma com botão de copiar. O endereço nunca é cortado. Se a janela estreita, o chip mostra só o ponto
    e o tempo.
  - *Centro:* os controles da aula (o que apresentar, pausar, qualidade) e a ação principal, "Iniciar
    transmissão" ou a pílula vermelha "Encerrar", no lugar do "Sair da chamada" do Meet.
  - *Direita:* os botões dos painéis (Alunos, Chat, Arquivos), com contadores. O botão do painel aberto
    fica preenchido e troca o círculo por um quadrado arredondado: é o *shape morph* do M3 Expressive.
- **Painel lateral, uma área por vez:** um cartão arredondado (28 pt) com título e botão de fechar. Clicar
  no botão do painel já aberto fecha o painel, como no Meet. O painel "Apresentar" (escolha de tela ou
  janela) também fica ali. O painel e a aba abertos são lembrados, e ⌥⌘I abre e fecha.
- **Não lidas:** as mensagens dos alunos que chegam com o chat fora de vista contam no botão do chat, num
  badge vermelho.
- **Chat:** no topo, o controle "Alunos podem escrever", onde o Meet põe o "Permitir que todos enviem
  mensagens". Antes ele ficava escondido no popover de qualidade. Abaixo vem o aviso de quem vê o quê. As
  mensagens aparecem sem balões (nome, hora e texto) e o campo de mensagem é uma pílula.
- **Alunos:** a lista segue o painel Pessoas do Meet. Cada aluno tem um avatar com as iniciais, numa cor
  fixa pelo nome, e uma linha "com a aula à vista" ou "em outra janela ou aba". No topo, um resumo diz
  quantos estão com a aula à vista.
- **Qualidade:** a resolução e os quadros por segundo são escolhidos em *connected button groups*, o
  substituto do segmented button no M3 Expressive.
- **Tokens:** o código tem os papéis de cor do M3 (surface containers tonais, primary, error e outros, com
  a paleta do Google para o modo claro e o escuro), a escala de tipos (display → label), os cantos 4/8/12/16/28, as
  molas de movimento (rígidas para efeitos, amortecidas para posição) e as camadas de estado (8% no hover,
  10% no clique). Tudo está em `views/Material/M3.swift`.
- **Fontes:** o texto usa a **Google Sans Flex** (SIL OFL 1.1) e os ícones usam os **Material Symbols
  Rounded** (Apache 2.0), as fontes do Material 3. As duas são variáveis: o ícone do painel aberto
  aparece preenchido pelo eixo FILL. Foram reduzidas ao alfabeto latino e aos cerca de 50 ícones usados:
  270 KB e 65 KB, com as licenças ao lado em `src/web-assets/fonts`, a mesma pasta que a página do aluno usa. O app as registra em tempo de execução
  (`CTFontManagerRegisterFontsForURL`) e, se não achar, volta para a fonte do sistema.
- **Por que não uma biblioteca:** o *Material Components for iOS* está em modo de manutenção desde 2021 e
  é UIKit/iOS. Não há biblioteca Material mantida para SwiftUI no macOS, então os tokens foram escritos
  à mão a partir da especificação.

Referências: [Material 3 Expressive](https://m3.material.io/blog/building-with-m3-expressive);
[cores](https://m3.material.io/styles/color/roles), [formas](https://m3.material.io/styles/shape/corner-radius-scale)
e [movimento](https://m3.material.io/styles/motion/overview/how-it-works) no m3.material.io;
[button groups](https://m3.material.io/components/button-groups/overview);
[Google Sans Flex](https://fonts.google.com/specimen/Google+Sans+Flex);
[Material Symbols](https://github.com/google/material-design-icons);
[Google Meet](https://workspace.google.com/products/meet/);
[Material Components iOS em manutenção](https://github.com/material-components/material-components-ios).

### 4.3. Tela do aluno: o mesmo desenho, do lado do navegador

A página do aluno foi refeita com os mesmos tokens do professor (cores claro/escuro, tipos,
formas, fontes), servidos pelo próprio app, sem internet. O que mudou, e por quê (feedback da
turma, triado de forma enxuta em `docs/feedback-tela-do-aluno.md`):

- **Palco + barra + painel, como no Meet:** a imagem num palco escuro; embaixo, o estado ("Ao
  vivo", "Pausada", "Reconectando…") e o nome com que o aluno entrou à esquerda, e os botões
  **Chat** e **Arquivos** à direita, cada um com seu contador. Uma área por vez no
  painel lateral, que o aluno fecha para ganhar tela.
- **Celular:** em pé, o painel sobe como folha por cima da imagem (tocar fora ou Esc fecha);
  deitado, a barra vira um trilho vertical à direita e a imagem ganha a altura inteira. Alvos
  de toque de 48 px e margens do entalhe do iPhone (`safe-area-inset`).
- **Tela cheia como a do YouTube:** vai para a tela cheia só a imagem (e os avisos de pausa e
  reconexão), sem barra nem painel. O botão fica na própria imagem, no canto de baixo à
  direita, como nos players: aparece quando o mouse passa por cima e some parado (na tela
  cheia, o cursor some junto); no celular fica sempre à vista. A tecla **F** e o duplo clique
  na imagem entram e saem. (Na primeira versão a tela cheia levava a página inteira, como no
  Meet, e a turma achou que a tela "nunca ficava cheia".) O Safari do iPhone não põe imagem em tela cheia;
  lá o caminho é "Adicionar à Tela de Início": o `manifest.webmanifest` (`display:
  fullscreen`) e as metas `apple-mobile-web-app-*` abrem a aula como app, sem a barra do
  navegador.
- **Mão levantada:** um ícone pequeno ao lado do campo de mensagem, que funciona mesmo com o
  chat desligado. O professor vê quem levantou primeiro no topo da lista e pode abaixar.
- **Links e mensagem fixada:** os links nas mensagens do professor viram clicáveis (só
  `http(s)://` e `www.`, montados com DOM, nunca `innerHTML`); a fixada fica no topo do chat.
  Com isso, "materiais e links da aula" não precisou de uma área nova: arquivos já têm o painel
  Arquivos, e links vão pelo chat.
- **Imagem que não pisca:** o vigia do vídeo só troca o `src` quando precisa (antes, cada
  reconexão reiniciava o vídeo duas vezes) e, ao trocar ou quando a conexão cai, pinta o
  último quadro num `<canvas>` por cima até chegar o quadro novo. Medido no Chrome 153 e no
  WebKit: nenhum quadro vazio na troca; antes, cerca de 1,85 s de área vazia. Com a conexão
  caída o aluno vê a imagem parada com um aviso pequeno, e não mais uma tela preta.
- **Tela que não apaga:** a Wake Lock API só existe em `https://`, e a aula é `http://`. O
  módulo `manter-tela-acesa.js` usa a API quando pode e, fora disso, a técnica do NoSleep.js
  (MIT): um vídeo minúsculo em laço, iniciado no gesto de "Entrar na aula". Medido com `pmset
  -g assertions`: Chrome e WebKit seguram a tela acordada. O vídeo **não pode ser mudo**
  (`muted` não segura a tela em nenhum dos dois), precisa estar no DOM (fora da tela, 1 px)
  e custa 3 a 4 pontos de CPU no Chrome. No celular, por ter trilha de áudio (silenciosa), pode
  pausar a música de outro app.

### 5. Estrutura de Arquivos e Módulos do Código Fonte

O projeto usa **Swift Package Manager** (sem `.xcodeproj`), com o núcleo isolado na biblioteca
`AulaCastCore` para que a suíte de testes possa exercitá-lo sem abrir a interface.

```text
AulaCast/
├── docs/
│   ├── 01-especificacao-requisitos.md
│   ├── 02-casos-de-uso.md
│   ├── 03-historias-de-usuario.md
│   ├── 04-arquitetura-e-design.md
│   ├── feedback-tela-do-aluno.md
│   ├── README.md                          # Índice (RF, RNF, UC, US, ADR)
│   ├── padroes.md
│   └── adr/                               # Decisões de arquitetura
├── README.md
├── scripts/                               # build-app.sh, gerar-dmg.sh, gerar-icone.swift
└── src/
    ├── Package.swift
    ├── sources/
    │   ├── aulacast-app/
    │   │   └── AulaCastApp.swift              # Executável AulaCast
    │   └── aulacast/                          # Biblioteca AulaCastCore
    │       ├── core/                          # Protocolos (DIP/ISP)
    │       │   ├── ScreenCaptureProtocol.swift
    │       │   ├── VideoEncoderProtocol.swift
    │       │   ├── NetworkServerProtocol.swift
    │       │   ├── FrameReceiverProtocol.swift
    │       │   └── EventObserverProtocols.swift
    │       ├── models/
    │       │   ├── ConnectedClient.swift      # Identificação e presença
    │       │   ├── ChatMessage.swift
    │       │   ├── DisplaySource.swift
    │       │   ├── SharedFile.swift
    │       │   └── VideoResolution.swift
    │       ├── managers/
    │       │   ├── ClientManagerService.swift
    │       │   └── ChatManagerService.swift
    │       ├── services/
    │       │   ├── ScreenCaptureService.swift
    │       │   ├── ShareableContentFetcher.swift
    │       │   ├── ScreenRecordingPermissionService.swift
    │       │   ├── MJPEGFrameEncoder.swift
    │       │   ├── MJPEGStreamerService.swift
    │       │   ├── NetworkListenerService.swift
    │       │   ├── WebSocketHandlerService.swift
    │       │   ├── WebSocketFrameDecoder.swift
    │       │   ├── WebSocketFrameEncoder.swift
    │       │   ├── FileDownloadService.swift
    │       │   ├── MDNSHostnameService.swift
    │       │   ├── SystemActivityService.swift
    │       │   ├── SourceThumbnailProvider.swift
    │       │   ├── StaticFileProviderService.swift
    │       │   ├── BonjourAdvertiserService.swift
    │       │   └── WebAssetsPathResolver.swift
    │       ├── viewmodels/
    │       │   └── MainViewModel.swift
    │       └── views/
    │           ├── Material/M3.swift          # Tokens e componentes do Material 3
    │           ├── MainDashboardView.swift    # Palco + barra inferior (desenho do Meet)
    │           ├── ClassInspectorView.swift   # Painel lateral (uma área por vez)
    │           ├── SourcePickerView.swift
    │           ├── StudentListView.swift
    │           ├── ChatPanelView.swift
    │           ├── SharedFilesPanelView.swift
    │           ├── QualitySettingsView.swift
    │           └── AulaCastPalette.swift      # Cores da marca
    ├── tests/aulacast-tests/
    │   ├── TestRunnerMain.swift               # Suíte executável
    │   └── TestDoubles.swift                  # Dublês de captura, rede e codificação
    └── web-assets/                            # Cliente do aluno (sem framework)
        ├── index.html
        ├── styles.css                         # Tokens do Material 3 (claro e escuro)
        ├── manifest.webmanifest               # "Adicionar à Tela de Início" em tela cheia
        ├── apple-touch-icon.png
        ├── favicon-32.png, favicon-192.png     # Ícone na aba do navegador
        ├── fonts/                             # Google Sans Flex e Material Symbols (+ licenças),
        │                                      #   usadas também pela tela do professor
        ├── js/
        │   ├── main.js
        │   ├── entry-gate.js                  # Tela de identificação
        │   ├── student-identity.js            # Nome do aluno na sessão
        │   ├── presence-reporter.js           # Presença na tela
        │   ├── socket-client.js               # WebSocket + reconexão
        │   ├── stream-watchdog.js             # Vigia o MJPEG; segura o último quadro
        │   ├── manter-tela-acesa.js           # Wake Lock ou vídeo em laço (NoSleep.js)
        │   ├── vendor/nosleep-media.js        # Vídeos do NoSleep.js (MIT)
        │   ├── chat-manager.js
        │   ├── links.js                       # Links clicáveis, montados com DOM
        │   ├── raise-hand.js                  # Mão levantada
        │   ├── files-list.js
        │   ├── ui-controller.js
        │   └── config.js
        └── tests/                             # Testes com node --test
```

---

### 6. Estratégia de Testes

Duas suítes, ambas **sem dependências externas** — coerente com o requisito de operação offline.

| Suíte | Como executar | Cobre |
| :--- | :--- | :--- |
| Swift | `swift run AulaCastTestRunner` | Domínio (turma, chat, identificação, presença), segurança (directory traversal), protocolo WebSocket (frames colados, partidos e malformados) e integração ponta a ponta com servidor e WebSocket reais |
| Cliente Web | `node --test "tests/*.test.js"` | 12 arquivos: identificação do aluno, reconexão (`socket-client`, `config`), watchdog do vídeo, presença, chat (`chat-manager`), mensagens do servidor (`main-messages`), interface (`ui-controller`), lista de arquivos, links, mão levantada e manter a tela acesa |

Os testes de integração sobem um `NetworkListenerService` real numa porta de teste e se
conectam como um aluno de verdade, em vez de simular as camadas — vários defeitos deste
projeto viviam justamente nas emendas entre camadas, invisíveis a testes isolados.