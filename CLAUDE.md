# AulaCast: guia para publicar na Mac App Store

App macOS (Swift/SwiftUI) que transmite a tela do **anfitrião** para os **participantes**, que
assistem pelo navegador, na rede local e sem internet. Visão geral e funcionalidades: `README.md`.

**Objetivo desta sessão: publicar na Mac App Store.** O titular da conta Apple Developer é quem
assina e envia; os certificados ficam no Mac dele.

## Onde está cada coisa
- **Passo a passo da publicação e riscos:** `docs/app-store-checklist.md` (comece por ele).
- **Decisão de distribuição (sandbox):** `docs/adr/ADR-007-distribuicao-mac-app-store-sandbox.md`.
- **Scripts:** `scripts/gerar-appstore.sh` (pacote `.pkg`), `scripts/build-app.sh` (monta o `.app`,
  escreve o `Info.plist`), `scripts/gerar-dmg.sh` (instalador fora da loja).
- **Entitlements e privacidade:** `scripts/AulaCast.entitlements`, `scripts/PrivacyInfo.xcprivacy`.
- **Índice dos demais documentos:** `docs/README.md` (requisitos, casos de uso, arquitetura, ADRs).

## O que o titular da conta precisa ter
App ID com Bundle ID explícito, certificados `Apple Distribution` e `Mac Installer Distribution`
no chaveiro, perfil de provisionamento "Mac App Store Connect" e o app registrado no App Store
Connect. A lista completa está na seção 1 do checklist.

## Gerar o pacote
```bash
export AULACAST_BUNDLE_ID=<o Bundle ID do App ID>
export AULACAST_PROVISIONING_PROFILE=<caminho do .provisionprofile>
export AULACAST_APP_IDENTITY="Apple Distribution: Nome (TEAMID)"
export AULACAST_INSTALLER_IDENTITY="Mac Installer Distribution: Nome (TEAMID)"
export AULACAST_BUILD=<número que cresce a cada envio>
./scripts/gerar-appstore.sh        # saída: build/appstore/AulaCast-1.0.0.pkg
```
Depois, enviar o `.pkg` pelo app **Transporter**. O script recusa o que não pode ir para a loja
(variante de depuração, binário que não é universal, identidade ausente, manifesto de privacidade
ausente).

## Antes de enviar (não foi verificado ainda)
- **Teste do sandbox:** nunca rodou com App Sandbox ligado. Fazer o teste local do checklist
  (`AULACAST_SANDBOX_TESTE=1 ./scripts/gerar-appstore.sh /tmp/aulacast-sandbox`) e conferir cada item:
  servidor na porta 8080, `aulacast.local`, captura de tela, Wi-Fi do Mac e os arquivos.
- **Categoria:** o `Info.plist` diz Educação; o app foi pensado para qualquer pessoa. Decidir com o
  titular (Produtividade ou Utilitários) e manter `LSApplicationCategoryType` e o App Store Connect iguais.
- **Política de privacidade:** a URL pública é obrigatória e ainda não existe. O checklist diz o que
  ela deve cobrir (o app guarda nome, IP, navegador e métricas só no Mac do anfitrião).
- **Revisão da Apple:** podem questionar o servidor local e a captura de tela. As notas de revisão
  sugeridas estão no checklist.

## Regras
- **Nunca** colocar certificado, chave privada (`.p12`, `.p8`), perfil de provisionamento ou senha no
  repositório. Tudo vem de variáveis de ambiente.
- **Nunca** enviar o build de depuração (`AULACAST_DEBUG_METRICS=1`) para a loja.
- **Não** fazer push forçado, commit na `main` sem o titular pedir, nem apagar branches sem pedir.
- O **número de build** (`AULACAST_BUILD`) precisa crescer a cada envio; a versão fica em `scripts/build-app.sh`.
- Texto da interface em português do Brasil, sem ponto final nas frases curtas. O vocabulário é
  **anfitrião**, **participante**, **transmissão** e **lista de presença** (ADR-008), nunca "professor" ou "aluno".

## Testes (rodar só o necessário)
```bash
cd src && swift run AulaCastTestRunner          # modo core: 298 testes, rápido
cd src/web-assets && node --test "tests/*.test.js"   # cliente web: 237 testes (precisa Node recente, v22 ou mais)
```
O modo `--tudo` do Swift sobe portas reais e o codificador de hardware; só rodar se for preciso.

## Decisões e limites que valem lembrar
- O vídeo é H.264 (fMP4) com reserva em MJPEG, e a página volta ao H.264 sozinha (ADR-004, ADR-009).
- Métricas e lista de presença ficam no Mac do anfitrião; nada sai para a internet (ADR-006).
- Os menus do app foram enxugados: só o menu do app e "Janela" (`src/sources/aulacast-app/BarraDeMenus.swift`).
- A tela do participante pode apagar por inatividade: a Wake Lock só existe em `https://`.
