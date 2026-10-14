# Plano: substituir o MJPEG por compressão de vídeo de verdade

Este documento avalia como sair do MJPEG atual (`MJPEGFrameEncoder` + `MJPEGStreamerService`)
para um codec com predição entre quadros — sem quebrar as três coisas que fazem o AulaCast
funcionar hoje: **100% LAN/offline**, **aluno só abre o navegador** (sem instalar nada) e
**zero dependências de terceiros** no projeto (`Package.swift` só usa frameworks da Apple).

## 1. Por que o MJPEG dói

Cada quadro enviado hoje é um JPEG *intra* completo — nenhuma informação do quadro anterior é
aproveitada (`MJPEGFrameEncoder.swift:63-80`). Isso significa que mesmo quando só o cursor se
move ou uma linha de código é digitada, o quadro inteiro é recomprimido e reenviado do zero.

Isso já apareceu nos ajustes existentes:

- `QualitySettingsView.swift:38-40` tira 60 fps da lista porque, no MJPEG, dobrar a taxa
  dobra o tráfego sem melhorar a imagem — "o que trava não é o Mac, é a rede".
- A recomendação de 720p para "PCs antigos do laboratório" (`QualitySettingsView.swift:29`)
  é sobre a rede da sala compartilhada entre N alunos, não sobre a CPU do professor.

Um quadro 1080p em JPEG qualidade 0.6 de tela de código (texto + fundo sólido) costuma ficar
na faixa de dezenas de KB; a 30 fps isso já é alguns Mbps **por aluno**, num Wi-Fi de sala de
aula compartilhado com a turma inteira. Um codec com predição entre quadros (H.264/H.265) trata
"nada mudou" ou "só um retângulo mudou" como quase grátis — para o conteúdo típico de tela
compartilhada (texto parado, scroll, cursor), a redução de banda costuma ficar na casa de
5–15× em relação a JPEG-por-quadro. **Isso precisa ser medido no AulaCast antes de decidir
qualquer coisa** (ver Fase 0) — é só a ordem de grandeza que justifica a troca.

## 2. Restrições que moldam a escolha

1. **Sem app no aluno.** O cliente é `<img id="videoStream">` num navegador comum
   (`web-assets/index.html:74`), alimentado por `multipart/x-mixed-replace`
   (`MJPEGStreamerService.swift:76-80`). Qualquer novo formato tem que rodar dentro do que o
   navegador já sabe decodificar, sem plugin.
2. **Sem internet, de propósito.** O README é explícito: o firewall da instituição bloqueia
   Meet/Zoom/Discord/Teams, e o AulaCast existe justamente para não depender de nada externo.
   Isso descarta de saída qualquer coisa que espere STUN/TURN ou um servidor de sinalização
   fora da LAN.
3. **Servidor é HTTP puro, sem TLS.** `NetworkListenerService` não fala TLS hoje, e adicionar
   HTTPS aqui significa certificado autoassinado — cada aluno veria o aviso de "conexão não
   segura" do navegador ao entrar, o oposto do "só digita o IP" que o projeto vende.
   **Isso elimina a WebCodecs API como caminho direto**: ela só funciona em contexto seguro
   (HTTPS ou `localhost`) — um IP de LAN em HTTP puro não conta. Confirmado na documentação do
   MDN e na própria issue do W3C perguntando se dá para tirar essa exigência (ainda aberta).
4. **Zero dependências de terceiros.** O `Package.swift` de hoje não importa nenhuma lib
   externa; o `web-assets/js/vendor/` só tem um arquivo, para um bug pontual de navegador.
   Isso pesa contra qualquer opção que exija bibliotecas de codec de imagem que a Apple não
   oferece nativamente (ex.: WebP, que não tem encoder nativo no CoreImage/ImageIO).
5. **Parque de máquinas heterogêneo.** Alunos podem estar em PCs antigos do laboratório,
   Chromebooks, ou celular/tablet (o CSS de tela cheia do `index.html:26` já lida com iPhone).
   O codec de vídeo tem que ter decodificação universal — isso aponta para H.264 como base,
   não H.265/AV1 (ver seção 3.4).

## 3. Opções consideradas

### 3.1 WebRTC — descartado

Resolveria vídeo com predição entre quadros e baixa latência "de fábrica", mas:

- Puxa uma pilha inteira (ICE/SDP, `libwebrtc` ou equivalente) só para o caso de uso mais
  simples que existe: um produtor, muitos consumidores, mesma LAN, sem NAT a atravessar.
- Contraria a filosofia de zero dependências do projeto — não existe WebRTC "nativo" leve em
  Swift sem trazer uma lib de terceiros pesada (o próprio `libwebrtc` do Google passa de
  100 MB compilado).
- Cada aluno vira uma sessão SFU/mesh separada para o servidor gerenciar — muito mais estado
  do que uma conexão HTTP simples por aluno, que é o que `MJPEGStreamerService` já sabe fazer
  bem (ver os comentários cuidadosos sobre `esperandoQuadro`, backpressure, etc.).

Não é que WebRTC não funcione — é desproporcional ao problema.

### 3.2 WebCodecs (`VideoDecoder`) + H.264 cru via WebSocket/HTTP

É o caminho **tecnicamente mais leve e mais rápido**: sem contêiner nenhum, o servidor manda
Access Units H.264 (saída direta do `VTCompressionSession`) e o navegador decodifica com
`VideoDecoder.decode()`, pintando cada `VideoFrame` num `<canvas>`. Sem MP4, sem `MediaSource`,
sem *buffer* de `<video>` — é o que projetos como streaming de emulador/scrcpy-web fazem hoje
para latência mínima.

**Bloqueado pela restrição 3 (contexto seguro).** WebCodecs exige HTTPS ou `localhost`; um
`http://192.168.x.x:8080` de sala de aula não qualifica. Migrar o servidor inteiro para TLS
autoassinado só para habilitar isso pioraria a experiência de entrada (aviso de certificado em
cada aluno) pelo ganho de latência que o MSE (opção 3.3) já entrega "bom o suficiente" para uma
aula. **Fica registrado como possível Fase 3**, condicional a decidir também resolver TLS por
outro motivo — ver seção 5.

Suporte de navegador, hoje: Chrome/Edge desde a v94; Firefox desktop completo a partir da
v130 (sem Android); Safari com `VideoDecoder` desde 16.4 (só vídeo), pilha completa a partir da
26. Ou seja, mesmo sem o bloqueio de contexto seguro, ainda sobraria material para dar suporte
a Firefox Android e Safari mais antigo no laboratório.

### 3.3 MSE (Media Source Extensions) + fMP4 fragmentado com H.264 — recomendado

`MediaSource` **não está na lista de APIs restritas a contexto seguro** (diferente de
`EncryptedMediaExtensions`, que é uma API prima mas separada) — funciona em HTTP puro, como já
funciona hoje para DASH/HLS em qualquer CDN. Isso destrava o uso em cima do servidor atual sem
mexer em TLS.

**Desenho:**

- **Professor (Swift):** trocar `MJPEGFrameEncoder` por um encoder que usa
  `VTCompressionSession` (framework `VideoToolbox`, já disponível — zero dependência nova) para
  gerar H.264 com baixa latência. A Apple documenta esse modo especificamente para tempo real
  (sessão da WWDC21 "Explore low-latency video encoding with VideoToolbox"): baixa
  o buffer interno do encoder e evita reordenação de quadros B, que é o que introduziria atraso
  perceptível numa aula ao vivo.
- **Empacotamento:** os *access units* do VideoToolbox viram fragmentos fMP4 (`moof`/`mdat`),
  com um `ftyp`/`moov` inicial — um empacotador pequeno e específico (uma faixa de vídeo só,
  sem ABR, sem seek, sem DVR), do tamanho do `MJPEGFrameEncoder` atual, não uma lib de
  streaming genérica.
- **Transporte:** a mesma conexão HTTP persistente de hoje (`NWConnection`), só que em vez de
  `multipart/x-mixed-replace`, o corpo é `video/mp4` `chunked` contínuo — o mesmo padrão de
  "produtor empurra bytes, uma conexão por aluno" que `MJPEGStreamerService` já implementa,
  incluindo o backpressure via `.contentProcessed` que já existe.
- **Aluno:** troca `<img id="videoStream">` por `<video>`, alimentado via `fetch()` +
  `ReadableStream` (ou `MediaSource` clássico) fazendo `sourceBuffer.appendBuffer()` a cada
  fragmento que chega. É o mesmo truque usado por players de câmera IP/live streaming em HTTP
  puro (ex.: a família flv.js/mpegts.js resolve exatamente este problema — MPEG-TS → fMP4 →
  MSE — e documenta bem as armadilhas de iOS abaixo).

**Armadilha conhecida: iPhone/iPad.** Safari no iOS nunca teve o `MediaSource` clássico; desde
o iOS 17.1 existe o `ManagedMediaSource`, uma variante pensada para consumo tipo HLS (o
navegador decide quando buscar mais dados), não para um `appendBuffer` empurrado livremente
pelo servidor. Dá para adaptar (é o que mpegts.js faz desde a v1.8.0), mas exige um caminho de
inicialização diferente do MSE de desktop e não cobre iOS ≤ 17.0. Como o público de celular já
é atendido hoje pelo MJPEG sem drama nenhum, a decisão pragmática é: **feature-detectar
`MediaSource`/`ManagedMediaSource` e cair automaticamente para o `<img>` MJPEG atual quando
não houver suporte confiável** — o mesmo espírito de resiliência que o `StreamWatchdog` já tem
para quedas de conexão. Isto é: **o MJPEG não morre, vira o modo de compatibilidade.**

**Vendorizar (mpegts.js) vs. escrever na mão.** Duas opções, ambas viáveis:

| | Vendorizar uma lib pronta (ex. mpegts.js) | Empacotador + player próprios |
|---|---|---|
| Esforço inicial | Baixo (já resolve MPEG-TS/fMP4, ABR, quirks de iOS) | Médio-alto (fMP4 é um formato de caixas bem definido, mas com detalhes finos) |
| Superfície | Grande (recursos que o AulaCast nunca vai usar: seek, DVR, ABR, TS) | Mínima (uma faixa de vídeo, sem seek) |
| Alinhamento com o projeto | Quebra o "zero dependências" (ainda que só no lado do aluno) | Mantém o padrão atual (tudo autoral, comentado como o resto do `web-assets/js`) |
| Risco de bug obscuro de navegador | Baixo (lib testada por muita gente) | Médio — mas o projeto já navega bem esse tipo de risco (ver os comentários sobre o bug do WebKit 36536 em `stream-watchdog.js`) |

Dado o padrão do projeto (tudo em `web-assets/js/` é autoral e documentado com bugs de
navegador medidos na mão, e o único arquivo em `vendor/` é uma correção pontual, não um
framework), a recomendação é **escrever o empacotador fMP4 e o player MSE próprios**, do
tamanho mínimo que o caso de uso pede. É mais trabalho de implementação, mas fica auditável e
sem dependência nova — coerente com como o resto do repositório é construído.

### 3.4 H.265/HEVC e AV1 — não agora

- **HEVC:** o `VideoToolbox` até tem encoder de hardware para HEVC (é, aliás, a aposta
  principal da Apple — mais forte que AV1 no lado de encoder). O problema é do lado do aluno:
  suporte a decodificação de HEVC em Chrome/Firefox depende da plataforma (funciona bem em
  cima de decoder do sistema operacional — Windows recente, macOS — mas é inconsistente em
  Linux/Chromebook, comuns em laboratório escolar). H.264 é a única aposta com decodificação
  garantida em qualquer navegador/SO. HEVC pode voltar depois como um extra opcional,
  negociado via `MediaSource.isTypeSupported(...)`, quando os dois lados (Mac do professor +
  navegador do aluno) claramente suportam — nunca como único caminho.
- **AV1:** teria o menor bitrate dos três, mas o encoder de hardware da Apple para AV1 só
  chegou em chips de ponta muito recentes (M5 Pro/Max); nos M1–M4 e Intel — o parque real de
  quem roda o AulaCast hoje — o encode de AV1 seria por software, caro demais para tempo real
  a 1080p/30fps. Fora de cogitação para o encoder até isso mudar de patamar no hardware da
  Apple.

### 3.5 Ganho rápido sem trocar de arquitetura: melhorar o próprio JPEG

Antes de qualquer coisa acima, dá para espremer mais o MJPEG atual sem tocar no cliente:

- **Chroma subsampling e otimizações de `CIContext.jpegRepresentation`**: vale medir se o
  perfil de compressão atual já está no ponto ótimo para texto/UI (que tem bordas nítidas,
  diferente de foto), ou se um ajuste fino de qualidade por resolução/fps já embolsa 10–20%
  de banda de graça.
- **WebP no lugar de JPEG**, mantendo a arquitetura `multipart/x-mixed-replace` como está
  (o navegador não liga para o `Content-Type` de cada parte, contanto que ele saiba decodificar
  — WebP em `<img>` funciona em todo navegador relevante hoje). Ganho típico de 25–35% sobre
  JPEG em qualidade equivalente. **Mas** não existe encoder de WebP nativo da Apple
  (nem CoreImage nem ImageIO oferecem), então isso quebraria o "zero dependências" do
  `Package.swift` para trazer uma lib como `libwebp`. Vale só como remendo de curtíssimo prazo
  se a Fase 1 (H.264/MSE) atrasar muito — o ganho é bem menor que o de sair do intra-only.

Esta opção **não é a recomendação principal**: é intra-only igual ao JPEG, então não ataca a
causa raiz (nenhum aproveitamento entre quadros). Fica registrada como plano B de baixo risco.

## 4. Recomendação

**Fase 1 é o alvo: H.264 via `VideoToolbox` empacotado em fMP4, entregue por `MediaSource` na
mesma conexão HTTP persistente de hoje, com o MJPEG atual preservado como modo de
compatibilidade automático.** Nenhuma dependência nova, nenhuma mudança de rede (continua HTTP
puro, mesma porta, mesmo Bonjour), maior ganho de banda por trabalho investido. Fase 2 (HEVC) e
Fase 3 (WebCodecs) ficam registradas como backlog condicional — não fazem parte do escopo de
execução abaixo.

## 5. Requisitos

### 5.1 Funcionais

- **RF1 — Fallback obrigatório.** Qualquer aluno cujo navegador não suporte
  `MediaSource`/`ManagedMediaSource` continua vendo a aula pelo caminho MJPEG atual, sem
  precisar fazer nada — troca automática, no mesmo espírito do `StreamWatchdog` de hoje.
- **RF2 — Nova rota de vídeo.** `GET /stream.mp4` entrega H.264 empacotado em fMP4 fragmentado,
  por uma conexão HTTP persistente (mesmo padrão de "produtor empurra bytes, uma conexão por
  aluno" que `/stream` já usa). A rota `/stream` (MJPEG) continua existindo, inalterada.
- **RF3 — Encoder plugável.** O novo encoder implementa `VideoEncoderProtocol`
  (`core/VideoEncoderProtocol.swift`) e se conecta ao pipeline de captura exatamente como
  `MJPEGFrameEncoder` hoje (via `MainViewModel.encoderService`, `MainViewModel.swift:123,149`) —
  nenhuma mudança em `ScreenCaptureService`.
- **RF4 — Qualidade ao vivo.** Trocar resolução/fps em `QualitySettingsView` durante a aula
  precisa continuar valendo na hora para o novo encoder, do jeito que já vale para o MJPEG
  (`ScreenCaptureService.swift:34-44`).
- **RF5 — Medição comparável.** Deve dar para medir, no mesmo cenário, para MJPEG e para H.264:
  bytes por quadro, bytes/segundo agregados e tempo de CPU gasto codificando por quadro.
- **RF6 — Paridade operacional.** Parar a transmissão, trocar de fonte (monitor/janela) e a
  tela do professor ficar parada continuam funcionando sem reiniciar o servidor — paridade com
  `MJPEGStreamerService.reset()` e o "modo pausado" descrito em
  `MJPEGStreamerService.swift:134-136`.

### 5.2 Não funcionais

- **RNF1 — Zero dependências novas.** Nem no `Package.swift` (só `VideoToolbox`, framework da
  Apple, já disponível), nem em `web-assets/js/` (JS vanilla, sem lib de terceiros vendorizada).
- **RNF2 — Continua HTTP puro.** Nenhuma mudança para TLS/HTTPS nesta fase.
- **RNF3 — Baixa latência.** `VTCompressionSession` configurado no modo de baixa latência
  (sem quadros B, sem buffer de reordenação) — é aula ao vivo, não vídeo sob demanda.
- **RNF4 — Testável sem permissão de Gravação de Tela.** Encoder e empacotador têm que ser
  testáveis com `CVPixelBuffer`/NALs sintéticos, sem depender de `ScreenCaptureKit` real — só a
  verificação final end-to-end (navegador de verdade) precisa da app rodando de verdade.
- **RNF5 — Mesmos padrões do repositório.** Um serviço por responsabilidade (SRP), comentário só
  onde o "porquê" não é óbvio, testes no estilo manual `assertTest`/`[PASS]`/`[FAIL]` que já
  existe em `tests/aulacast-tests/TestRunnerMain.swift` (não há XCTest no projeto), nomes e
  comentários em PT-BR como o resto do código.

### 5.3 Critérios de aceite da Fase 1 (definição de pronto)

1. O relatório de baseline (Fase 0) está commitado antes de qualquer linha do encoder H.264.
2. Com o app rodando de verdade, Chrome e Safari (desktop) num outro computador da mesma LAN
   assistem `/stream.mp4` via MSE com atraso imperceptível numa aula normal (referência: o
   próprio MJPEG de hoje, que já é considerado "bom o suficiente").
3. Forçar a detecção de `MediaSource` a falhar (feature-detect manual, não precisa de aparelho
   antigo de verdade) faz o cliente cair para `<img>`/MJPEG sem erro visível para o aluno.
4. Trocar fonte de captura ou pausar a tela do professor não derruba a conexão `/stream.mp4`.
5. Relatório final compara bytes/quadro e CPU de MJPEG vs. H.264, no mesmo cenário da Fase 0.

## 6. Contratos de interface (fixados agora para permitir trabalho em paralelo)

Estes tipos definem as costuras entre os pedaços da Fase 1. Fixá-los aqui deixa cada tarefa da
seção 7 testável sozinha, contra dados sintéticos, sem esperar as outras terminarem.

```swift
// Novo arquivo: core/H264AccessUnitProtocol.swift

/// Um quadro H.264 já codificado, em Annex-B (cada NAL prefixado por start code
/// 0x00 0x00 0x00 0x01). Quando `isKeyFrame`, `data` inclui SPS e PPS antes do IDR slice —
/// é o suficiente para o empacotador fMP4 montar o `moov`/`avcC` sem precisar de mais nada.
public struct H264AccessUnit {
    public let data: Data
    public let presentationTime: CMTime
    public let isKeyFrame: Bool

    public init(data: Data, presentationTime: CMTime, isKeyFrame: Bool) {
        self.data = data
        self.presentationTime = presentationTime
        self.isKeyFrame = isKeyFrame
    }
}

/// Quem recebe os access units do encoder H.264 (o empacotador fMP4, na Fase 1).
public protocol H264AccessUnitReceiverProtocol: AnyObject {
    func didReceiveAccessUnit(_ unit: H264AccessUnit)
}

// Novo arquivo: core/FMP4FragmentProtocol.swift

/// Quem recebe os bytes já prontos para escrever na conexão HTTP.
///
/// `isInitSegment` é verdadeiro só na primeira entrega de cada conexão nova (o `ftyp`+`moov`,
/// que o `SourceBuffer` do navegador exige antes de qualquer `moof`); depois disso é sempre
/// `false` (um fragmento `moof`+`mdat`, tipicamente um por quadro-chave/GOP).
public protocol FMP4FragmentReceiverProtocol: AnyObject {
    func didReceiveFragment(_ data: Data, isInitSegment: Bool)
}
```

Duas observações que valem para quem for implementar contra estes contratos:

- **Annex-B, não AVCC.** Escolha deliberada: Annex-B (start codes) é o que `VTCompressionSession`
  costuma devolver mais diretamente e é fácil de inspecionar a olho nu/com `xxd` num teste. A
  conversão para o formato de tamanho-prefixado que o `avcC`/`stsd` do MP4 exige é
  responsabilidade do empacotador (tarefa T1.3), não do encoder.
- **Um único init segment por conexão**, gerado a partir do primeiro quadro-chave que a conexão
  daquele aluno vir a receber — não é um arquivo estático gravado uma vez para o processo
  inteiro, porque a resolução pode mudar ao vivo (RF4) e o `avcC` muda com ela.

## 7. Plano de execução

Tarefas pequenas e de responsabilidade única, no espírito do resto do repositório. As da
"Onda 1" não dependem umas das outras — podem ser feitas por agentes em paralelo, cada um em seu
próprio worktree, testando contra os contratos da seção 6 e não contra o código-fim das outras.

### Fase 0 (independente, pode rodar em paralelo com a Onda 1 da Fase 1)

- **T0 — Instrumentação e medição do MJPEG atual.** Ver instrução do agente em 8.1.
- **T0-manual — Rodar a medição de verdade.** Não é tarefa de agente: exige o app empacotado
  rodando com permissão de Gravação de Tela concedida, e um navegador de verdade assistindo.
  Depois que T0 estiver mesclado: gerar o `AulaCast.app` (`scripts/build-app.sh`), abrir a aula,
  reproduzir cada combinação de `QualitySettingsView` (720p/1080p × 15/30/45) por ~30s com
  conteúdo representativo (editor de código, terminal rolando, slide parado), e salvar a saída
  do exportador de métricas em `docs/baseline-mjpeg-AAAA-MM-DD.md`. Isso é o que a Fase 1 vai
  comparar contra — sem isso, T1.7 não tem com o que comparar.

### Fase 1 — Onda 1 (paralela)

- **T1.2 — Encoder H.264 (`VideoToolbox`).** Instrução em 8.2.
- **T1.3 — Empacotador fMP4.** Instrução em 8.3. Testável com NALs sintéticos, sem esperar T1.2.
- **T1.5 — Player MSE no cliente.** Instrução em 8.4. Testável contra um arquivo `.mp4`
  fragmentado qualquer (gerado com `ffmpeg -movflags frag_keyframe+empty_moov`, se houver
  `ffmpeg` disponível), sem esperar nada do lado Swift.

### Fase 1 — Onda 2 (depende da Onda 1)

- **T1.4 — Transporte HTTP + rota `/stream.mp4`.** Instrução em 8.5. Depende de T1.3 (consome
  `FMP4FragmentReceiverProtocol` de verdade).

### Fase 1 — Onda 3 (integração final, sequencial)

- **T1.6 — Integração de ponta a ponta.** Instrução em 8.6. Junta T1.2 → T1.3 → T1.4 → T1.5 de
  verdade, faz a verificação manual dos critérios de aceite (seção 5.3) e escreve o relatório
  comparativo final (equivalente a T0-manual, mas para H.264) em
  `docs/comparativo-mjpeg-h264-AAAA-MM-DD.md`.
- **T1.8 — Rollout.** Só depois de T1.6 fechar todos os critérios de aceite: atualizar
  `README.md` (diagrama da seção "Como funciona") e decidir se `QualitySettingsView` precisa de
  algum indicador de qual modo está ativo. Pequeno, não precisa de instrução própria de agente.

## 8. Instruções para os agentes

Cada bloco abaixo é o prompt para um agente novo (contexto zerado — não é fork desta conversa),
pensado para rodar isolado (`isolation: "worktree"`), do jeito que o resto do projeto já é
desenvolvido (branches/worktrees pequenos e focados, ver `.claude/worktrees/`). Cole o bloco
inteiro como `prompt` na chamada da ferramenta de agente.

### 8.1 — T0: Instrumentação e medição do MJPEG

```
Você vai instrumentar o encoder de vídeo do AulaCast (app macOS em Swift, SPM puro, sem
dependências de terceiros — ver src/Package.swift) para medir o custo do MJPEG atual antes de
uma futura troca para H.264. NÃO troque o encoder nem mude o comportamento de produção — esta
tarefa é só medição.

Leia primeiro: src/sources/aulacast/services/MJPEGFrameEncoder.swift (o encoder atual) e
src/sources/aulacast/core/FrameReceiverProtocol.swift (os protocolos de saída).

Crie um novo serviço SRP, `FrameMetricsRecorder` (novo arquivo em
src/sources/aulacast/services/FrameMetricsRecorder.swift), que registra, por quadro: tamanho em
bytes dos dados codificados e duração da codificação (medida com `DispatchTime` ou
`CFAbsoluteTimeGetCurrent`, em volta da chamada de codificação). Ele deve expor um resumo
agregado (bytes/quadro médio, bytes/segundo agregado assumindo a taxa de quadros atual, tempo
médio de CPU por quadro) e um jeito de exportar isso como texto/Markdown simples (não precisa de
CSV nem de UI bonita — um `String` formatado que dá para colar num arquivo já serve).

Instrumente `MJPEGFrameEncoder` para alimentar esse recorder a cada quadro codificado, sem
mudar sua interface pública (`VideoEncoderProtocol`) nem o comportamento observável por quem já
usa a classe. Pense em como expor o resumo para quem estiver rodando o app manualmente (ex.: um
atalho de teclado ou item de menu que imprime o resumo atual no console, já que o app roda via
terminal/Xcode durante desenvolvimento — veja como outras partes do app expõem estado para
depuração antes de inventar um mecanismo novo).

Escreva testes no MESMO estilo do arquivo tests/aulacast-tests/TestRunnerMain.swift: sem XCTest
(o projeto não usa), blocos numerados "TESTE N: ..." com `assertTest(condição, "descrição")` e
contagem de PASS/FAIL no final. Adicione seus testes lá, seguindo o padrão dos testes vizinhos.
Os testes devem alimentar o recorder com dados sintéticos (tamanhos e durações inventados, sem
precisar de `CMSampleBuffer` real nem de permissão de Gravação de Tela) e verificar que os
agregados batem com a conta manual.

Rode a suíte de testes existente (é um executável SPM — veja como
AulaCastTestRunner é definido em src/Package.swift, o alvo se chama `AulaCastTestRunner`) e
garanta que passa 100%, incluindo os testes que já existiam antes de você mexer.

Não adicione nenhuma dependência ao Package.swift. Não toque na rota HTTP nem no cliente web.
Ao final, descreva num resumo curto como alguém vai, na prática, rodar o app e coletar os
números (isso vai virar um passo manual documentado no PLANO-COMPRESSAO-DE-VIDEO.md, mas você
não precisa editar esse arquivo — só descrever o passo a passo na sua resposta final).
```

### 8.2 — T1.2: Encoder H.264 via VideoToolbox

```
Você vai criar um novo encoder de vídeo H.264 para o AulaCast (app macOS em Swift, SPM puro,
zero dependências de terceiros — src/Package.swift só usa frameworks da Apple, e é para
continuar assim). Ele vai substituir, no futuro, o MJPEG atual — mas esta tarefa entrega só o
encoder, isolado, sem mexer no resto do pipeline.

Leia primeiro, para entender o padrão a seguir:
- src/sources/aulacast/services/MJPEGFrameEncoder.swift (o encoder atual: implementa
  VideoEncoderProtocol, recebe CMSampleBuffer, evita reentrância com um lock de "já estou
  codificando", entrega o resultado por um `outputReceiver`).
- src/sources/aulacast/core/VideoEncoderProtocol.swift e core/FrameReceiverProtocol.swift (os
  protocolos existentes).

Contrato que você precisa fixar (crie o arquivo, não existe ainda):
src/sources/aulacast/core/H264AccessUnitProtocol.swift, com exatamente este conteúdo:

    import Foundation
    import CoreMedia

    public struct H264AccessUnit {
        public let data: Data
        public let presentationTime: CMTime
        public let isKeyFrame: Bool

        public init(data: Data, presentationTime: CMTime, isKeyFrame: Bool) {
            self.data = data
            self.presentationTime = presentationTime
            self.isKeyFrame = isKeyFrame
        }
    }

    public protocol H264AccessUnitReceiverProtocol: AnyObject {
        func didReceiveAccessUnit(_ unit: H264AccessUnit)
    }

Crie `H264FrameEncoder` (novo arquivo services/H264FrameEncoder.swift) implementando
`VideoEncoderProtocol` (o mesmo protocolo que `MJPEGFrameEncoder` implementa), usando
`VTCompressionSession` do framework VideoToolbox (framework do sistema, sem novo pacote no
Package.swift). Requisitos do encoder:

- Modo de baixa latência: configure a sessão para não usar quadros B e minimizar o buffer de
  reordenação/atraso (pesquise `kVTCompressionPropertyKey_RealTime` e as flags de baixa latência
  documentadas pela Apple para VTCompressionSession — o objetivo é uma aula ao vivo, não vídeo
  gravado). Não combine taxa de bits constante com o modo de baixa latência se a documentação
  indicar incompatibilidade — confira antes de configurar.
- Saída em Annex-B: cada quadro entregue via `H264AccessUnitReceiverProtocol.didReceiveAccessUnit`
  deve ter os NALs prefixados por start code (0x00 0x00 0x00 0x01), não o formato
  tamanho-prefixado (AVCC) que o `CMBlockBuffer` do VideoToolbox devolve por padrão — você vai
  precisar converter. Quando `isKeyFrame == true`, inclua SPS e PPS (extraídos da
  `CMFormatDescription` do sample buffer de saída) como NALs próprios antes do IDR, no mesmo
  Data.
- Igual ao MJPEGFrameEncoder: descarte silenciosamente (sem crashar, sem enfileirar) um quadro
  novo se o anterior ainda está sendo codificado, e trate sample buffers "idle"/sem imagem sem
  custo.
- Exponha uma propriedade pública `outputReceiver: EncodedFrameReceiverProtocol?` para
  continuar satisfazendo `VideoEncoderProtocol` (assim ele é um substituto direto de
  MJPEGFrameEncoder nesse ponto de extensão), MAS os dados reais de vídeo devem sair por um
  segundo receptor, `h264OutputReceiver: H264AccessUnitReceiverProtocol?` — decida se
  `EncodedFrameReceiverProtocol.didReceiveEncodedFrame` também é chamado (ex. com os bytes
  Annex-B brutos, para manter compatibilidade de tipo) ou se ele fica sem uso nesta classe;
  documente a decisão com um comentário curto explicando o porquê.

Testes: siga o estilo manual de tests/aulacast-tests/TestRunnerMain.swift (sem XCTest, blocos
"TESTE N: ...", `assertTest`). Construa `CMSampleBuffer`s sintéticos a partir de
`CVPixelBuffer`s gerados em memória (cor sólida, ou um gradiente simples) — não dependa de
ScreenCaptureKit nem de permissão de Gravação de Tela. Verifique pelo menos:
- O primeiro quadro codificado chega marcado como `isKeyFrame == true` e contém SPS/PPS (procure
  os NALs tipo 7 e 8 no Annex-B).
- Uma sequência de quadros idênticos ainda produz saída válida (não trava, não crasha).
- Um sample buffer sem imagem (idle) não gera access unit nenhum e não deixa o encoder num
  estado inconsistente para o próximo quadro real.

Não toque em MainViewModel, ScreenCaptureService, NetworkListenerService nem em nada do cliente
web — isso é tarefa de outro agente, que vai integrar este encoder depois. Não adicione
dependências ao Package.swift.
```

### 8.3 — T1.3: Empacotador fMP4

```
Você vai escrever um empacotador ISO-BMFF (fMP4 fragmentado) mínimo para o AulaCast, que
transforma access units H.264 em bytes que o `MediaSource`/`SourceBuffer` de um navegador aceita
via `appendBuffer`. É um componente pequeno e específico — uma faixa de vídeo só, sem áudio, sem
seek, sem DVR, sem ABR — não é para reimplementar um muxer de propósito geral.

O contrato de entrada já está fixado, em core/H264AccessUnitProtocol.swift (crie este arquivo se
ele ainda não existir no repositório, com exatamente este conteúdo — outro agente pode estar
criando o encoder que produz esses dados em paralelo, então o contrato precisa ser idêntico):

    import Foundation
    import CoreMedia

    public struct H264AccessUnit {
        public let data: Data
        public let presentationTime: CMTime
        public let isKeyFrame: Bool

        public init(data: Data, presentationTime: CMTime, isKeyFrame: Bool) {
            self.data = data
            self.presentationTime = presentationTime
            self.isKeyFrame = isKeyFrame
        }
    }

    public protocol H264AccessUnitReceiverProtocol: AnyObject {
        func didReceiveAccessUnit(_ unit: H264AccessUnit)
    }

`data` chega em Annex-B (NALs com start code 0x00 0x00 0x00 0x01); quando `isKeyFrame`, o SPS e
o PPS vêm como NALs próprios antes do IDR, dentro do mesmo `data`.

Crie o contrato de saída, core/FMP4FragmentProtocol.swift:

    import Foundation

    public protocol FMP4FragmentReceiverProtocol: AnyObject {
        func didReceiveFragment(_ data: Data, isInitSegment: Bool)
    }

Crie `FMP4Packager` (novo arquivo services/FMP4Packager.swift), que implementa
`H264AccessUnitReceiverProtocol` e entrega para um `outputReceiver: FMP4FragmentReceiverProtocol?`:

1. Na primeira vez que receber um access unit com `isKeyFrame == true`, monte e entregue (com
   `isInitSegment: true`) um segmento de inicialização ISO-BMFF válido: `ftyp` (major brand
   `isom`, compatível com `iso5`/`avc1`) seguido de `moov` com uma única `trak` de vídeo H.264,
   `avcC` construído a partir do SPS/PPS extraídos daquele access unit, e os campos de
   `mvex`/`trex` que um `SourceBuffer` de fMP4 fragmentado exige para aceitar fragmentos depois.
   Extraia SPS/PPS/dimensões (largura/altura) direto dos NALs, sem depender de nada do
   VideoToolbox.
2. Para cada access unit (inclusive os que geraram o init segment), monte e entregue (com
   `isInitSegment: false`) um fragmento `moof`+`mdat`: sequência de fragmento incrementando,
   `tfdt` com o tempo de apresentação convertido para a escala de tempo da faixa, `trun` com o
   tamanho e as flags de sync sample corretas (quadro-chave vs. não), e o NAL convertido de
   Annex-B para o formato tamanho-prefixado (length-prefixed, 4 bytes big-endian) que o `avcC`
   exige dentro do `mdat` — não deixe start codes dentro do `mdat`.
3. Se a resolução mudar (um novo access unit com SPS diferente do usado no init segment atual),
   gere um novo init segment antes do próximo fragmento — o método que entrega fragmentos para
   uma conexão de aluno precisa saber que a próxima entrega para ELE é outro init segment; deixe
   isso explícito na API pública da classe (ex.: um método para "iniciar uma nova sessão de
   entrega" que reseta o que já foi mandado para aquele consumidor específico, já que o mesmo
   `FMP4Packager` serve todos os alunos ao mesmo tempo e cada aluno entra em um ponto diferente
   do fluxo — pense em como `MJPEGStreamerService.updateFrame`/`serveStream` resolvem esse mesmo
   problema hoje para inspiração de desenho, mesmo que a implementação seja diferente).

Testes: estilo manual de tests/aulacast-tests/TestRunnerMain.swift (sem XCTest). Construa
`H264AccessUnit`s sintéticos (bytes de NAL inventados, mas estruturalmente válidos — SPS/PPS
mínimos, um IDR mínimo, um P-frame mínimo) SEM depender do encoder da tarefa T1.2 nem de
VideoToolbox. Verifique pelo menos:
- O init segment começa com uma caixa `ftyp` válida (4 bytes de tamanho + "ftyp") e contém uma
  `moov`.
- Um fragmento `moof`+`mdat` tem o `mdat` do tamanho certo e sem start codes Annex-B dentro.
- Se houver `ffprobe` ou `mp4box`/`mp4dump` disponível no ambiente, valide também rodando a
  ferramenta sobre os bytes gerados (concatenando init segment + um fragmento num arquivo
  temporário) e conferindo que ela reconhece o arquivo como MP4 válido com uma faixa de vídeo
  H.264; se a ferramenta não estiver disponível, não trate isso como falha — documente que a
  validação ficou só na inspeção manual das caixas.

Não toque em MainViewModel, ScreenCaptureService, NetworkListenerService, no encoder da tarefa
T1.2, nem no cliente web. Não adicione dependências ao Package.swift.
```

### 8.4 — T1.5: Player MSE no cliente

```
Você vai criar o player de vídeo do lado do aluno no AulaCast (site estático em JS vanilla,
servido pelo próprio Mac do professor — sem bundler, sem framework, ver src/web-assets/js/).
Hoje o vídeo é um <img id="videoStream"> alimentado por MJPEG via
src/web-assets/js/stream-watchdog.js. Você vai adicionar um caminho novo, baseado em
`<video>` + Media Source Extensions, que tenta primeiro e cai para o caminho MJPEG existente
quando não for possível usar MSE — o MJPEG não pode ser removido nem quebrado por esta tarefa.

Leia primeiro:
- src/web-assets/index.html (onde está o `<img id="videoStream">`, dentro de `.video-wrap`).
- src/web-assets/js/stream-watchdog.js (o `StreamWatchdog` atual — leia os comentários com
  atenção: eles documentam comportamentos medidos à mão em Chrome e WebKit que você precisa
  respeitar ao decidir quando trocar de modo).
- src/web-assets/js/main.js (onde o `StreamWatchdog` é instanciado e ligado ao resto da página).

Crie `src/web-assets/js/video-stream-player.js`, um módulo ES (mesmo estilo dos outros arquivos
em web-assets/js/: comentários em PT-BR explicando o "porquê", não o "o quê"; exporta uma
classe). Ele deve:

1. Detectar suporte via feature detection real, não sniffing de user-agent: verificar se
   `window.MediaSource` ou `window.ManagedMediaSource` existem E se
   `MediaSource.isTypeSupported('video/mp4; codecs="avc1.42E01E"')` (ou o construtor
   equivalente de `ManagedMediaSource`) retorna `true`. Trate qualquer exceção ao tentar como
   "sem suporte", não como erro fatal.
2. Quando houver suporte: buscar `/stream.mp4` (a rota ainda não existe no servidor — construa
   contra um arquivo `.mp4` fragmentado local para testar; se houver `ffmpeg` disponível no
   ambiente, gere um de teste com algo como
   `ffmpeg -f lavfi -i testsrc=duration=5:size=1280x720:rate=30 -c:v libx264 -movflags
   frag_keyframe+empty_moov+default_base_moof -f mp4 fixture.mp4`; se não houver `ffmpeg`,
   documente isso e teste só a lógica de feature-detection/fallback, deixando um comentário
   claro sobre o que não pôde ser testado de ponta a ponta), ler a resposta com
   `fetch()` + `response.body.getReader()`, e ir chamando `sourceBuffer.appendBuffer()` a cada
   pedaço que chegar — sem esperar a resposta inteira (isto é vídeo ao vivo, não um arquivo
   completo).
3. Ao inicializar `ManagedMediaSource` (caminho do iOS 17.1+), siga a documentação da WebKit
   para a sequência de inicialização exigida (o `<video>` precisa estar no DOM antes de criar o
   `ManagedMediaSource`, entre outros detalhes específicos) — pesquise a documentação oficial da
   Apple/WebKit antes de implementar, não assuma que o fluxo é idêntico ao `MediaSource` clássico.
4. Se a inicialização falhar em qualquer ponto (exceção, `sourceended`, `sourceclose`,
   `appendBuffer` rejeitando por `QuotaExceededError` de forma persistente, etc.), cair para o
   caminho MJPEG existente automaticamente: a classe deve aceitar uma referência ao
   `StreamWatchdog` (ou a uma função equivalente de "usar o modo antigo") e chamá-la nesse caso,
   sem exigir nenhuma ação do aluno.
5. Não modifique o comportamento do `StreamWatchdog` nem do `<img>` existente — esta tarefa
   ADICIONA um caminho novo, escolhido antes de decidir qual dos dois usar; não reescreva a
   lógica de reconexão que já existe lá.

Escreva testes no MESMO estilo dos testes existentes em src/web-assets/tests/ (veja
stream-watchdog.test.js como referência de estilo e runner usado) cobrindo pelo menos: a
detecção de suporte retornando falso cai para o caminho de fallback sem lançar exceção; um erro
do `MediaSource` depois de já ter iniciado também aciona o fallback.

Não toque no `index.html` além do mínimo necessário para o `<video>` conviver com o `<img>`
existente (ex.: os dois elementos podem coexistir escondidos/visíveis conforme o modo ativo —
decida a abordagem mais simples e documente). Não adicione bibliotecas de terceiros (sem
vendorizar mpegts.js nem similares — é para ser autoral, como o resto de web-assets/js/). Não
toque em nenhum arquivo Swift.
```

### 8.5 — T1.4: Transporte HTTP e rota `/stream.mp4`

```
Você vai adicionar a rota de streaming de vídeo H.264/fMP4 no servidor HTTP do AulaCast (app
macOS em Swift, usando o framework Network — NWListener/NWConnection). Hoje existe uma rota
equivalente para MJPEG; você vai criar a irmã dela para o novo formato, SEM remover ou alterar
a existente.

Leia primeiro:
- src/sources/aulacast/services/MJPEGStreamerService.swift inteiro — é o modelo a seguir: uma
  conexão HTTP por aluno, mantida viva, com backpressure via `.contentProcessed` (o próximo
  envio só sai quando o anterior terminou), contagem de streams ativos, e tratamento de aluno
  saindo/tela parada. Leia os comentários com atenção — eles explicam decisões não óbvias
  (ex.: por que existe `esperandoQuadro`, por que a espera de "tela parada" foi trocada de
  polling por notificação).
- src/sources/aulacast/services/NetworkListenerService.swift, principalmente o método
  `receiveRequest` (por volta da linha 199) e o roteamento por método+caminho (por volta da
  linha 242: `else if metodo == "GET" && caminho == "/stream"`).
- core/FMP4FragmentProtocol.swift (crie se ainda não existir, com exatamente este conteúdo —
  outro agente pode estar criando o empacotador que produz esses dados em paralelo):

    import Foundation

    public protocol FMP4FragmentReceiverProtocol: AnyObject {
        func didReceiveFragment(_ data: Data, isInitSegment: Bool)
    }

Crie `MP4StreamerService` (novo arquivo services/MP4StreamerService.swift), implementando
`FMP4FragmentReceiverProtocol`, espelhando o desenho de `MJPEGStreamerService` mas adaptado ao
formato: em vez de `multipart/x-mixed-replace` com uma parte JPEG por vez, o corpo HTTP é
`Content-Type: video/mp4` com `Transfer-Encoding: chunked`, contínuo — primeiro o init segment
mais recente (para QUALQUER conexão nova, mesmo que ela chegue no meio de uma aula em
andamento), depois todo fragmento que chegar dali em diante, em ordem, respeitando o mesmo
princípio de backpressure (não acumular fragmentos atrasados num aluno de rede lenta — decida
se isso significa descartar fragmentos não-chave para quem está atrasado, documentando a
decisão, já que ao contrário do MJPEG aqui um fragmento perdido pode quebrar a decodificação até
o próximo quadro-chave).

Preste atenção especial a: uma conexão nova que chega precisa do init segment mais recente ANTES
de qualquer fragmento — guarde o último init segment recebido (como `MJPEGStreamerService`
guarda `latestFrameData`) e mande-o assim que a conexão abrir, mesmo que ele tenha chegado muito
antes da conexão existir. Exponha `activeStreamCount` e um `reset()` com o mesmo propósito que
`MJPEGStreamerService` tem hoje (esquecer o estado quando o servidor para, para a próxima aula
não abrir mostrando o quadro-chave da anterior).

Adicione a rota em `NetworkListenerService`: `GET /stream.mp4` chamando o novo serviço, ao lado
da checagem existente de `/stream` (não substitua a existente). Siga o padrão de nomes e
comentários já usado nesse arquivo (PT-BR, comentário só quando o "porquê" não é óbvio).

Testes no estilo manual de tests/aulacast-tests/TestRunnerMain.swift (sem XCTest). Você pode
testar a lógica de `MP4StreamerService` (armazenamento do init segment, entrega para uma
conexão simulada, contagem de streams ativos, reset) com dados sintéticos, sem precisar de uma
conexão TCP real — veja se já existe algum duplo de teste (`TestDoubles.swift`) para
`NWConnection` ou similar que você possa reaproveitar antes de criar um novo.

Não toque no encoder H.264 nem no empacotador fMP4 (são tarefas de outros agentes) — construa
contra o protocolo `FMP4FragmentReceiverProtocol` acima. Não toque no cliente web. Não adicione
dependências ao Package.swift.
```

### 8.6 — T1.6: Integração de ponta a ponta

```
As peças da Fase 1 de troca do MJPEG por H.264 no AulaCast foram construídas em paralelo, cada
uma testada isoladamente contra contratos fixos:
- H264FrameEncoder (encoder H.264 via VideoToolbox) — entrega H264AccessUnit
- FMP4Packager (empacotador fMP4) — consome H264AccessUnit, entrega fragmentos fMP4
- MP4StreamerService + rota GET /stream.mp4 — consome fragmentos fMP4, serve por HTTP
- video-stream-player.js — cliente MSE que consome /stream.mp4, com fallback para o MJPEG atual

Sua tarefa é ligar essas quatro peças de verdade e verificar que funcionam juntas. Leia o
arquivo PLANO-COMPRESSAO-DE-VIDEO.md na raiz do repositório inteiro antes de começar — ele tem o
contexto completo (por que cada decisão foi tomada) e a lista de critérios de aceite (seção
5.3) que esta tarefa precisa fechar.

Passos:
1. Em MainViewModel.swift, exponha uma forma de escolher entre `MJPEGFrameEncoder` (atual) e
   `H264FrameEncoder` (novo) — para esta fase de desenvolvimento, um jeito simples de alternar
   (variável de ambiente, ou uma flag interna) é suficiente; NÃO é para expor isso na UI do
   professor ainda (isso é a tarefa T1.8, e só depois desta aqui fechar todos os critérios de
   aceite).
2. Encadeie H264FrameEncoder -> FMP4Packager -> MP4StreamerService: o `outputReceiver`/
   `h264OutputReceiver` do encoder aponta para o packager, o `outputReceiver` do packager aponta
   para o streamer.
3. Rode `swift build` e resolva qualquer incompatibilidade de tipo/assinatura que apareça entre
   as peças (é esperado que existam pequenos ajustes de encaixe — cada peça foi construída contra
   o contrato, não contra a implementação real das outras).
4. Rode a suíte de testes completa (AulaCastTestRunner) e confirme 100% de PASS.
5. Gere o app empacotado (scripts/build-app.sh) e verifique manualmente, com um navegador de
   verdade noutro computador da mesma rede: `http://<ip-do-professor>:<porta>/stream.mp4` abre e
   mostra a tela do professor atualizando ao vivo, tanto em Chrome quanto em Safari.
6. Force (temporariamente, no código do cliente) a detecção de MSE a falhar e confirme que o
   aluno cai para o MJPEG sem erro visível.
7. Troque a fonte de captura (monitor -> janela) e pause a tela do professor durante o teste do
   passo 5; confirme que o stream H.264 não trava nem derruba a conexão.
8. Escreva um relatório em docs/comparativo-mjpeg-h264-AAAA-MM-DD.md comparando, nas mesmas
   combinações de resolução/fps testadas no baseline (docs/baseline-mjpeg-*.md, se já existir),
   bytes/quadro e CPU de MJPEG vs. H.264.

Se algum critério de aceite da seção 5.3 do plano não fechar, não force a integração como
"pronta" — documente exatamente o que falhou e onde, para virar a próxima tarefa. Não conclua
esta tarefa reportando sucesso se o teste manual em navegador de verdade (passo 5) não foi
executado — esse passo não pode ser simulado.
```

## 9. Riscos e como mitigar

- **iOS/iPadOS com `ManagedMediaSource`:** cobertura de aparelho por aparelho incerta até
  testar em sala. Mitigação: fallback automático para MJPEG é obrigatório, não opcional, desde
  o primeiro commit da Fase 1.
- **fMP4 escrito à mão tem detalhes finos** (alinhamento de `moof`, `tfdt`, `trun` etc.) que
  divergem sutilmente entre Chrome e Safari. Mitigação: validar cedo com os dois motores reais
  (o projeto já testa em WKWebView e Chrome, ver `stream-watchdog.js`), não só num navegador.
- **VideoToolbox em modo baixa latência tem restrições de configuração** (ex.: não combina
  taxa de bits constante com o modo de baixa latência) — checar a documentação da sessão da
  Apple ao implementar, não assumir os mesmos parâmetros do encoder offline comum.
- **Regressão de robustez:** o MJPEG atual tem tratamento cuidadoso de aluno saindo, tela
  parada, backpressure, etc. O novo caminho precisa do mesmo nível de cuidado antes de virar
  padrão — por isso o MJPEG continua sendo o modo seguro enquanto a Fase 1 amadurece.

## 10. O que não fazer agora

- **Não adotar WebRTC.** Desproporcional ao problema (produtor único, mesma LAN).
- **Não migrar para HTTPS só para habilitar WebCodecs.** O custo de UX (aviso de certificado
  em cada aluno) não se paga pelo ganho de latência, que a Fase 1 já não tem como problema.
- **Não mirar em AV1 no encoder** enquanto o hardware Apple relevante para o parque de
  professores de hoje não tiver encoder de AV1 decente.
- **Não trazer uma lib de terceiros no cliente "só porque é mais rápido de implementar"** sem
  antes tentar a versão própria mínima — é o padrão que o resto do `web-assets/js/` segue.

## Fontes

- [MDN — Features restricted to secure contexts](https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Secure_Contexts/features_restricted_to_secure_contexts) — WebCodecs exige HTTPS/localhost.
- [W3C WebCodecs — issue #383, "Can we drop the secure context (https) requirement?"](https://github.com/w3c/webcodecs/issues/383) — confirma que a exigência é intencional e segue em aberto.
- [MDN — MediaSource](https://developer.mozilla.org/en-US/docs/Web/API/MediaSource) — `MediaSource` não está na lista de contexto seguro.
- [Apple WWDC21 — "Explore low-latency video encoding with VideoToolbox"](https://developer.apple.com/videos/play/wwdc2021/10158/) — modo de baixa latência do `VTCompressionSession`.
- [Radiant Media Player — Managed Media Source no iPhone (Safari 17.1)](https://www.radiantmediaplayer.com/blog/at-last-safari-17.1-now-brings-the-new-managed-media-source-api-to-iphone.html)
- [mpegts.js (xqq) — README](https://github.com/xqq/mpegts.js/blob/master/README.md) — prior art de MPEG-TS/fMP4 → MSE em HTTP puro, incluindo o caminho de `ManagedMediaSource` no iOS desde a v1.8.0.
- [caniuse — WebCodecs API](https://caniuse.com/webcodecs) — suporte por navegador/versão.
- Cobertura de HEVC em Chrome/Firefox (inconsistente por SO/plataforma) e do encoder de AV1 em Apple Silicon (HEVC-first; AV1 só em chips recentes de ponta) — levantado via busca em setembro de 2026, vale reconferir antes de decidir a Fase 2.
