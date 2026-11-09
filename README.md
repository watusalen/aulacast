# AulaCast

Transmissão de tela em rede local, para qualquer pessoa: aula, reunião, suporte, apresentação.

O **anfitrião** transmite a própria tela num Mac, e os **participantes** assistem pelo navegador,
**sem instalar nada** e **sem depender da internet**. Tudo trafega pela rede local.

> **Origem.** O AulaCast nasceu nas aulas de programação do **Instituto Federal do Piauí — Campus
> Piripiri**, onde o projetor ruim, a internet instável e o firewall que bloqueia Meet, Zoom,
> Discord e Teams atrapalhavam ao mesmo tempo. Por isso ele opera só na LAN (Ethernet ou Wi-Fi),
> em portas HTTP comuns, 100% offline. O nome vem daí, mas o uso não se limita à sala de aula.

## Como funciona

```
   Mac do anfitrião                           Navegadores dos participantes
┌───────────────────────┐                   ┌──────────────────────────────┐
│  ScreenCaptureKit     │  H.264 (fMP4)     │  Chrome, Firefox, Safari,    │
│          ↓            │ ────────────────► │  Edge: MediaSource           │
│  Codificador          │  (reserva: MJPEG) │                              │
│  (VideoToolbox)       │   WebSocket       │  Chat · Arquivos · Mão       │
│  Servidor HTTP local  │ ◄───────────────► │  levantada                   │
└───────────────────────┘                   └──────────────────────────────┘
        Bonjour (_aulacast._tcp) e aulacast.local na rede local
```

- **Anfitrião:** app nativo macOS em Swift/SwiftUI, no estilo Material 3 Expressive.
- **Participantes:** página web servida pelo próprio Mac. Basta digitar `aulacast.local:8080` no
  navegador (o `http://` é opcional). Para quem não resolve `.local`, o botão "Copiar link" do app
  entrega o endereço pelo IP (`<ip-do-anfitrião>:8080`).
- **Vídeo:** H.264 em fMP4 (codificação por hardware, taxa-alvo calculada pela resolução e pelos quadros por segundo), tocado com
  `MediaSource`. Se o navegador não suporta ou a conexão cai repetidamente, a página cai para
  **MJPEG** (`<img>`, funciona em qualquer navegador) e **tenta voltar ao H.264 sozinha**, com
  espera crescente e sorteada, para a volta não derrubar a rede (ADR-004 e ADR-009).

## Funcionalidades

**Transmissão**
- Monitor inteiro ou uma janela, **trocável durante a transmissão**, sem derrubar ninguém
- **Ocultar apps**: com o monitor como fonte, o botão direito num app o tira da transmissão (mesmo em
  tela cheia). A escolha é lembrada; o selo de olho cortado no cartão mostra o que está oculto
- Qualidade ajustável ao vivo: 720p ou 1080p, 15, 30 ou 45 fps (padrão: 720p e 15 fps)
- Pausar sem encerrar; se a janela transmitida some, a transmissão pausa sozinha
- Encerrar mostra a transmissão parada na hora; a limpeza acontece em seguida

**Participantes**
- Entrada identificada: o participante informa o **nome** antes de assistir (revalidado no servidor)
- Lista com **uma linha por pessoa** (o mesmo IP é sempre a mesma pessoa), com o ícone de olho
  para quem está **vendo de fato** a transmissão, e não só conectado
- Clicar numa pessoa abre o **perfil**: tempo na transmissão, tempo vendo, saídas e os nomes que
  ela já usou
- **Lista de presença** em CSV ao encerrar (veja "Dados e privacidade")
- **Chat** reservado entre cada participante e o anfitrião (opcional: visível a todos), com links
  clicáveis e uma **mensagem fixada**
- **Levantar a mão**: o anfitrião vê quem levantou primeiro e abaixa com um clique
- **Compartilhar arquivos**: o anfitrião escolhe ou arrasta, e os participantes baixam pelo mesmo
  link da transmissão, sem internet

**Página do participante**
- Material 3, no desenho do Google Meet, para computador e celular; tela cheia pela tecla **F**;
  "Adicionar à Tela de Início" no iPhone
- Reconexão automática do vídeo e do chat, com o último quadro na tela (sem tela preta)
- A tela do participante **pode apagar por inatividade**: a Wake Lock só existe em `https://`, e a
  página é servida por `http://` na rede local

## Requisitos

- macOS 13 (Ventura) ou superior, Swift 5.9+
- Permissão de **Gravação de Tela** (o app orienta como conceder)
- Para rodar os testes do cliente web: Node.js recente (a v26 funciona; a v20 não carrega os módulos)

## Como executar

```bash
cd src
swift run AulaCast
```

Ao iniciar a transmissão, o app mostra o endereço para passar aos participantes.

## Gerando o aplicativo, o instalador e o pacote da loja

```bash
./scripts/build-app.sh      # monta build/AulaCast.app (universal: Apple Silicon e Intel)
./scripts/gerar-dmg.sh      # monta o .app e o embala em build/AulaCast-1.0.0.dmg
AULACAST_SANDBOX_TESTE=1 ./scripts/gerar-appstore.sh /tmp/aulacast-sandbox   # teste local do sandbox
./scripts/gerar-appstore.sh # pacote .pkg para a Mac App Store (variáveis em docs/app-store-checklist.md)
```

- `AULACAST_BUILD=<n>` define o número do build (precisa crescer a cada envio à loja); a versão
  (`CFBundleShortVersionString`) é a `1.0.0`, definida em `scripts/build-app.sh`.
- `AULACAST_DEBUG_METRICS=1 ./scripts/gerar-dmg.sh` gera a variante de **depuração** (console de
  métricas no navegador do participante). Ela **nunca** vai para a loja: `gerar-appstore.sh` recusa.
- O `.dmg` traz o aplicativo e um atalho para a pasta Aplicativos. Para conferir a arquitetura:
  `lipo -archs build/AulaCast.app/Contents/MacOS/AulaCast` (deve mostrar `x86_64 arm64`).
- Para desenvolver, `swift run AulaCast` é o caminho mais liso: não esbarra na permissão de Gravação
  de Tela, porque o macOS atribui a captura ao Terminal, que já tem a permissão.

### Publicar na Mac App Store

O app tem **App Sandbox** (`scripts/AulaCast.entitlements`), categoria, conformidade de exportação
(`ITSAppUsesNonExemptEncryption = false`) e **manifesto de privacidade** (`scripts/PrivacyInfo.xcprivacy`,
sem rastreamento e sem coleta). Quem publica é o titular da conta Apple Developer: o certificado
de distribuição e o perfil de provisionamento ficam no Mac dele, **nunca no repositório**.

Passo a passo completo (App ID, certificados, App Store Connect, privacidade, notas para a revisão,
envio pelo Transporter) e a lista de riscos em [`docs/app-store-checklist.md`](docs/app-store-checklist.md);
a decisão em [ADR-007](docs/adr/ADR-007-distribuicao-mac-app-store-sandbox.md).

> **Ainda não verificado com um build assinado de distribuição:** o comportamento sob sandbox do
> servidor na porta 8080, do nome `aulacast.local`, da captura de tela e do Wi-Fi do Mac. O
> checklist traz o teste local (`AULACAST_SANDBOX_TESTE=1`) para fazer antes de enviar.

### A permissão de Gravação de Tela pede autorização a cada build

Sem certificado, o `codesign` assina de forma ad-hoc e a identidade do app vira o **hash do
binário**. Qualquer mudança no código muda esse hash, o macOS não reconhece mais o app e a
permissão precisa ser concedida de novo. Não é defeito do aplicativo.

**Como resolver de vez, sem conta paga da Apple:** crie um certificado de assinatura de código no
seu Mac. Em **Acesso às Chaves**: *Assistente de Certificado > Criar um certificado…*, nome
`AulaCast Local`, identidade **Autoassinado raiz**, tipo **Assinatura de código**. O
`build-app.sh` detecta e passa a usar esse certificado (outro nome: `AULACAST_CODESIGN_ID`). A
permissão passa a valer entre builds.

Mantenha **uma única cópia** do app (em `/Applications`): cópias com o mesmo identificador, mas
assinaturas diferentes, entram em conflito na permissão.

### O aviso do Gatekeeper (instalação fora da loja)

O `.dmg` é assinado de forma **ad-hoc**, sem Developer ID nem notarização (as duas exigem conta
paga). O macOS de quem receber vai recusar a primeira abertura. Para liberar, uma vez:

```bash
xattr -dr com.apple.quarantine /Applications/AulaCast.app
```

Depois, basta autorizar a Gravação de Tela em Ajustes do Sistema > Privacidade e Segurança.
(Clicar com o botão direito > Abrir não resolve em Macs Apple Silicon.)

## Dados e privacidade

Tudo fica no Mac do anfitrião; o app não envia nada para a internet nem para o desenvolvedor.

- **Lista de presença:** ao encerrar, um CSV em `~/Documents/AulaCast/Listas de presença/`
  (`lista-de-presenca-AAAA-MM-DD-HHmm.csv`; separador `;`, UTF-8 com BOM; colunas `Nome`, `Presença`,
  `Entrou`, `Saiu`, `Minutos na transmissão`, `Minutos vendo`, `Percentual vendo`). O aviso "Lista dos
  participantes salva" leva ao arquivo ao ser clicado.
- **Métricas da sessão:** `~/Documents/AulaCast/Metricas/sessao-*.jsonl`, com nome, IP, navegador e a
  qualidade da conexão de cada participante (fps, banda, quadros perdidos), mais o estado do Mac.
  Nunca grava o texto do chat nem títulos de janela. O arquivo se explica sozinho (a primeira linha
  é a legenda) e pode ser entregue a uma IA para gerar gráficos (ADR-006).
- Com o App Sandbox, essas pastas ficam no contêiner do app; o menu **Arquivo > Mostrar pasta de
  dados no Finder** (⇧⌘D) abre a pasta certa.
- Os nomes dos participantes são visíveis ao anfitrião e, se o chat visível estiver ligado, aos
  demais. Quem publica o app define a política de privacidade e as respostas de App Privacy.

## Testes

Duas suítes, sem dependências externas:

```bash
# Swift, modo core (padrão): só lógica pura, sem rede real nem codificador de hardware (298 testes)
cd src
swift run AulaCastTestRunner
# Swift, tudo: inclui portas reais, WebSocket ponta a ponta e H.264 de hardware (demora e custa mais)
swift run AulaCastTestRunner --tudo

# Cliente web (237 testes)
cd src/web-assets
node --test "tests/*.test.js"
```

## Estrutura

```
src/
  sources/aulacast/         # Núcleo (AulaCastCore)
    core/                   # Protocolos: captura, rede, codificação, observadores
    models/                 # Pessoas e presença, mensagens, fontes, lista de presença (CSV)
    managers/               # Estado dos participantes e do chat
    services/               # ScreenCaptureKit, servidor HTTP/WebSocket, H.264/fMP4, MJPEG, Bonjour, mDNS
    viewmodels/             # MainViewModel
    views/                  # Telas SwiftUI e tokens Material 3 (views/Material)
  sources/aulacast-app/     # Ponto de entrada do app
  tests/aulacast-tests/     # Suíte de testes Swift
  web-assets/               # Cliente web do participante (HTML/CSS/JS sem framework) e as fontes
scripts/                    # build-app.sh, gerar-dmg.sh, gerar-appstore.sh, entitlements, PrivacyInfo.xcprivacy, ícone
docs/                       # Índice (docs/README.md), requisitos, casos de uso, histórias, arquitetura, ADRs e padrões
```

A documentação segue o índice em [`docs/README.md`](docs/README.md), com glossário (anfitrião,
participante, transmissão, lista de presença) e as decisões de arquitetura (ADR-001 a ADR-009).

## Decisões de projeto

- **H.264/fMP4 como vídeo principal, MJPEG como reserva** (ADR-004, ADR-009). O MJPEG manda um JPEG
  inteiro por quadro e uma cópia por participante, o que não fecha em turmas grandes no Wi-Fi. O
  H.264 reduz a banda; o MJPEG fica para o que não suporta H.264, e a página volta ao H.264 sozinha.
- **Sem framework no cliente.** Os computadores costumam ser modestos; JavaScript puro carrega rápido
  e não exige build.
- **Servidor HTTP/WebSocket próprio** (`Network.framework`), sem dependências externas, alinhado ao
  uso offline.
- **Nome na rede por mDNS próprio** (`aulacast.local`), com renomeação automática se houver conflito
  (ADR-002); o IP continua disponível pelo botão "Copiar link".
- **Captura na proporção da fonte**, sem faixas pretas.
- **Identificação revalidada no servidor.** A lista de presença não confia só na checagem do navegador.
- **Métricas e lista de presença permanentes** em todo build; só o console de métricas no navegador é
  exclusivo da variante de depuração (ADR-006).
- **Vocabulário neutro** (anfitrião e participante), para não prender o app à sala de aula (ADR-008).
- **As duas telas em Material 3 Expressive, no desenho do Google Meet:** palco com a imagem,
  controles numa barra embaixo, um painel lateral por vez. No Mac, os tokens (cores, tipos, formas,
  movimento) foram escritos em SwiftUI, porque não há biblioteca Material mantida para macOS; no
  navegador, em CSS, com as mesmas fontes servidas pelo próprio app (`docs/04`, seções 4.2 e 4.3).

## Sobre o desenvolvimento: pair programming com IA

Este projeto foi construído **inteiramente em pair programming com IA** (Claude). Registro isso
de forma explícita porque considero que a autoria precisa ser transparente.

**Eu não domino Swift.** Não escrevi o código deste repositório. O que fiz foi:

- levantar os requisitos a partir de um problema real das aulas no IFPI;
- decidir o que o sistema deveria fazer e o que ficaria de fora;
- **validar cada entrega rodando o aplicativo** e apontando o que estava errado;
- rejeitar o que não servia — muitas vezes.

A IA fez a implementação: arquitetura, código Swift, cliente web, testes e documentação.

### Crítica honesta: as telas geradas por IA

A parte visual foi, de longe, a mais frustrante do processo, e é onde a limitação apareceu com
mais clareza.

**A IA não enxerga o que produz.** Ela escreve código de interface sem ter noção do resultado.
As primeiras telas saíram genéricas — aquele visual de template que não diz nada. Precisei
repetir "está feio" várias vezes, com pouca evolução, porque *"feio"* não é acionável para quem
não vê a tela. A situação só destravou quando passei a fornecer **mockups concretos** e a IA
passou a **tirar prints do app e olhar o próprio resultado**. Aí sim ela convergiu.

Alguns defeitos visuais reais que passaram e precisaram ser apontados por mim:

| O que aconteceu | Causa |
| :--- | :--- |
| Botões de ícone viraram "pílulas" verticais estreitas | Largura aplicada por fora do estilo; o fundo encolhia até o ícone |
| Cards da grade se sobrepunham e não redimensionavam | A imagem em `scaledToFill` ditava o tamanho do card, estourando a coluna |
| A tela inteira rolava, em vez de só a lista de fontes | `ScrollView` no lugar errado da hierarquia |
| O card "Abra um app para vê-lo aqui" aparecia duplicado | Lógica preenchia a linha toda em vez de mostrar um convite só |
| A Central de Controle aparecia como "janela" para transmitir | Faltava filtrar por camada de janela |
| O VS Code sumia da lista | A API omitia janelas em outra Área de Trabalho |
| Textos sem acento ("Levantar a Mao", "transmissao") | Descuido de digitação num projeto em português |

E o pior de todos: **a tela do aluno ficou completamente quebrada** por um detalhe de CSS. Os
avisos de "Reconectando", "Sem conexão" e "Transmissão pausada" apareciam todos ao mesmo tempo
sobre o vídeo, porque o atributo `hidden` do HTML perde para um `display: flex` declarado na
folha de estilos. A IA escreveu o bug e não percebeu — quem percebeu fui eu, abrindo a página.

### O que funcionou muito bem

O contraste com a parte visual é grande. Em **lógica, protocolo e concorrência**, a IA foi
consistentemente melhor do que eu conseguiria avaliar sozinho:

- Encontrou uma **falha de segurança real** que já estava no código: a verificação contra
  *directory traversal* usava comparação de prefixo de texto, então uma pasta irmã de nome
  parecido (`web-assets-secreto`) passava como se fosse interna.
- Diagnosticou por que a transmissão travava: o contexto de renderização estava sendo recriado
  a cada quadro, e quadros atrasados se acumulavam sem limite.
- Identificou que o vídeo e o chat trafegam em **conexões separadas**, e que só o chat
  reconectava — o vídeo podia congelar para sempre enquanto a interface dizia "Conectado".
- Descobriu que frames de WebSocket colados no mesmo pacote TCP faziam mensagens de chat
  serem **descartadas em silêncio**.

Em vários desses casos ela **reverteu a própria correção para provar que o teste falhava sem
ela** — o que uma vez revelou que um teste que eu teria aceitado não cobria nada de fato.

### O que aprendi sobre o processo

1. **A IA também erra, e erra calada.** Vários bugs corrigidos aqui foram introduzidos por ela
   em rodadas anteriores. A diferença é a velocidade com que são encontrados e corrigidos
   quando você aponta o sintoma.
2. **Validar rodando é indispensável.** Quase todo defeito relevante apareceu ao usar o app, não
   ao ler o código. Sem alguém abrindo a tela e dizendo "isto está errado", o projeto teria
   ficado bonito no papel e quebrado na prática.
3. **Feedback vago custa caro.** "Está feio" gerou rodadas perdidas. "O botão de pausa está
   virando uma pílula estreita" foi resolvido de primeira.
4. **Não saber Swift deixou de ser a barreira** — mas saber o que eu queria, e conseguir
   reconhecer quando não era aquilo, passou a ser a habilidade que realmente importa.

É um processo assombroso, e por isso mesmo exige mais atenção, não menos: a facilidade de gerar
código funcional esconde o quanto ainda depende de alguém disposto a conferir cada entrega.

## Licença

Projeto acadêmico desenvolvido no IFPI — Campus Piripiri.

Componentes de terceiros incluídos, com as licenças junto:
- **Google Sans Flex**, © Google, [SIL Open Font License 1.1](src/web-assets/fonts/GoogleSansFlex-OFL.txt);
- **Material Symbols Rounded**, © Google, [Apache License 2.0](src/web-assets/fonts/MaterialSymbols-LICENSE.txt).

As fontes foram reduzidas aos caracteres e ícones usados pelo app e servem às duas telas.
