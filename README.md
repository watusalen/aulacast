# AulaCast

Transmissão de tela em rede local para salas de aula, criada para o **Instituto Federal do Piauí — Campus Piripiri**.

O professor transmite a própria tela e os alunos assistem pelo navegador, **sem instalar nada** e **sem depender da internet**. Tudo trafega pela rede local da sala.

## O problema

Nas aulas de programação do IFPI, três coisas atrapalham ao mesmo tempo:

1. **O projetor é ruim** — baixa resolução e pouco contraste, então quem senta no fundo não consegue ler código no editor nem no terminal.
2. **A internet é instável.**
3. **O firewall da instituição bloqueia** Meet, Zoom, Discord e Teams.

O AulaCast contorna os três: opera só na LAN (Ethernet ou Wi-Fi da sala), em portas HTTP comuns, **100% offline**.

## Como funciona

```
   Mac do professor                          Computadores dos alunos
┌──────────────────────┐                  ┌──────────────────────────┐
│  ScreenCaptureKit    │   HTTP + MJPEG   │  Navegador               │
│         ↓            │ ───────────────► │  (Chrome, Firefox,       │
│  Codificação JPEG    │                  │   Safari, Edge)          │
│         ↓            │   WebSocket      │                          │
│  Servidor local      │ ◄──────────────► │  Chat · Mão levantada    │
└──────────────────────┘                  └──────────────────────────┘
        Bonjour (_aulacast._tcp) na rede local
```

- **Professor:** app nativo macOS em Swift/SwiftUI.
- **Alunos:** página web servida pelo próprio Mac do professor — basta abrir `http://<ip-do-professor>:8080`.

## Funcionalidades

- Transmissão do monitor inteiro ou de uma janela específica, **trocável durante a aula** sem derrubar a transmissão
- Qualidade ajustável ao vivo (720p/1080p, 15/30/45 fps)
- Pausar a transmissão sem encerrar a sessão
- Entrada identificada: o aluno informa o **nome** antes de assistir
- Lista de presença mostrando quem está **realmente com a aula à vista** (não apenas conectado)
- Levantar a mão — só o próprio aluno abaixa, como no Google Meet
- Conversa reservada entre cada aluno e o professor (alunos não veem mensagens uns dos outros)
- Reconexão automática do vídeo e do chat quando a rede oscila

## Requisitos

- macOS 13 (Ventura) ou superior
- Swift 5.9+
- Permissão de **Gravação de Tela** (o app orienta como conceder)

## Como executar

```bash
cd src
swift run AulaCast
```

Ao iniciar a transmissão, o app mostra o endereço para passar à turma.

## Gerando o aplicativo e o instalador

```bash
./scripts/build-app.sh    # monta build/AulaCast.app
./scripts/gerar-dmg.sh    # monta o .app e o embala em build/AulaCast-1.0.0.dmg
```

O `.dmg` traz o aplicativo e um atalho para a pasta Aplicativos — quem recebe só arrasta um
para o outro.

O aplicativo sai **universal** (Apple Silicon e Intel). O `swift build` sozinho gera apenas a
arquitetura da máquina que compilou, e um `.dmg` feito num Mac Apple Silicon não abria num
Intel — o que numa sala de aula acontece o tempo todo. O script compila as duas fatias e as
junta com `lipo`; se a segunda não compilar, ele avisa e segue com a arquitetura local.
Para conferir o que saiu:

```bash
lipo -archs build/AulaCast.app/Contents/MacOS/AulaCast   # x86_64 arm64
```

Para desenvolver, `swift run AulaCast` é o caminho mais liso — inclusive porque não esbarra na
permissão de Gravação de Tela (veja a seção abaixo). O `.app` é o que se instala e se entrega.

### A permissão de Gravação de Tela pede autorização a cada build

Se você recompilar e o macOS voltar a pedir a autorização, não é defeito do aplicativo. Sem
certificado, o `codesign` assina de forma ad-hoc e a identidade do app fica sendo o **hash do
binário**:

```
$ codesign -d -r- build/AulaCast.app
# designated => cdhash H"d8d04e3247cb83e91edfc6848f75f4509b3b05f4"
```

Qualquer mudança no código muda esse hash, o macOS deixa de reconhecer o app e a permissão
precisa ser concedida de novo.

> É por isso que `swift run AulaCast` nunca pede nada: ali o binário roda solto, sem bundle
> próprio, e o macOS atribui a captura ao processo responsável — o Terminal, que já tem a
> permissão. O aplicativo empacotado tem identidade própria e precisa da sua.

**Como resolver de vez, sem conta paga da Apple:** crie um certificado de assinatura de código
no seu próprio Mac.

1. Abra o **Acesso às Chaves** (Keychain Access).
2. Menu **Acesso às Chaves > Assistente de Certificado > Criar um certificado…**
3. Nome: `AulaCast Local` · Tipo de identidade: **Autoassinado raiz** · Tipo de certificado:
   **Assinatura de código**. Confirme.
4. Rode `./scripts/build-app.sh` de novo — ele detecta o certificado e passa a usá-lo.

A identidade do app deixa de ser o hash e passa a ser o certificado mais o identificador do
bundle, que não mudam entre builds. Você autoriza a Gravação de Tela **uma vez** e pronto.

Se preferir outro nome para o certificado, exporte `AULACAST_CODESIGN_ID` antes de compilar.

### O aviso do Gatekeeper

O aplicativo é assinado de forma **ad-hoc**, não com Developer ID nem notarizado — as duas
coisas exigem conta paga da Apple. Na prática, o macOS de quem receber o `.dmg` vai recusar a
primeira abertura, dizendo que o app "está danificado" ou que veio de um desenvolvedor não
identificado. Não é defeito do aplicativo: é o Gatekeeper reagindo à marca de quarentena que o
sistema põe em tudo que chega de fora.

Para liberar, uma vez só:

```bash
xattr -dr com.apple.quarantine /Applications/AulaCast.app
```

Depois disso o app abre normalmente e basta autorizar a Gravação de Tela em Ajustes do Sistema
> Privacidade e Segurança.

> Clicar com o botão direito > Abrir, o truque de sempre, **não resolve** aqui: em Macs Apple
> Silicon o sistema exige assinatura notarizada quando o arquivo está em quarentena, e não
> apenas a confirmação do usuário. Só a remoção do atributo resolve.

## Testes

O projeto tem duas suítes, ambas sem dependências externas.

```bash
# Domínio, rede, segurança e ponta a ponta (Swift)
cd src
swift run AulaCastTestRunner

# Cliente web (Node.js)
cd src/web-assets
node --test "tests/*.test.js"
```

## Estrutura

```
src/
  sources/aulacast/         # Núcleo (AulaCastCore)
    core/                   # Protocolos — captura, rede, codificação, observadores
    models/                 # Aluno conectado, mensagem, fonte de captura
    managers/               # Estado da turma e do chat
    services/               # ScreenCaptureKit, servidor HTTP/WebSocket, MJPEG, Bonjour
    viewmodels/             # MainViewModel
    views/                  # Telas SwiftUI
  sources/aulacast-app/     # Ponto de entrada do app
  tests/aulacast-tests/     # Suíte de testes
  web-assets/               # Cliente web do aluno (HTML/CSS/JS, sem framework)
docs/                       # Especificação, casos de uso, histórias de usuário, arquitetura
```

## Decisões de projeto

- **MJPEG em vez de H.264** — sem negociação nem dependência de codec no cliente; qualquer navegador exibe com uma tag `<img>`, o que sustenta o requisito de zero instalação.
- **Sem framework no cliente** — os computadores do laboratório são modestos; JavaScript puro carrega rápido e não exige build.
- **Servidor HTTP/WebSocket próprio** (`Network.framework`) — mantém o projeto sem dependências externas, alinhado ao uso offline.
- **Identificação revalidada no servidor** — a lista de presença não pode confiar apenas na checagem do navegador.

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
