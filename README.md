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
- Qualidade ajustável ao vivo (720p/1080p, 15/30 fps)
- Pausar a transmissão sem encerrar a sessão
- Entrada identificada: o aluno informa **nome e matrícula do IFPI** antes de assistir
- Lista de presença mostrando quem está **realmente com a aula à vista** (não apenas conectado)
- Levantar a mão — só o próprio aluno abaixa, como no Google Meet
- Chat local entre a turma e o professor
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
    models/                 # Aluno conectado, mensagem, fonte de captura, matrícula
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
- **Validação da matrícula também no servidor** — o registro de presença não pode confiar apenas na checagem do navegador.

## Licença

Projeto acadêmico desenvolvido no IFPI — Campus Piripiri.
