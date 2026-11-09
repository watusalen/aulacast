# Checklist de publicação na Mac App Store (AulaCast 1.0.0)

Ver [ADR-007](adr/ADR-007-distribuicao-mac-app-store-sandbox.md). Status: **Proposto**. Nada aqui foi verificado com um build assinado de distribuição; tudo marcado **a validar com um build assinado** só se confirma assim.

## 1. O que o responsável (titular da conta Apple Developer) faz

1. **App ID** (Certificates, Identifiers & Profiles): tipo macOS App, Bundle ID explícito (ex.: `br.edu.ifpi.aulacast`). O build usa `AULACAST_BUNDLE_ID` e ele **precisa ser idêntico** ao App ID.
2. **Certificados**: `Apple Distribution` (ou `3rd Party Mac Developer Application`) e `Mac Installer Distribution` (ou `3rd Party Mac Developer Installer`), instalados com a chave privada no chaveiro do Mac que vai gerar o pacote. Quem gera o pacote precisa da chave privada: ou o professor roda o script no Mac dele, ou exporta os certificados (.p12) por canal seguro. Nunca coloque .p12 ou perfil no repositório.
3. **Perfil de provisionamento** "Mac App Store Connect" para esse App ID, baixado como `.provisionprofile` (variável `AULACAST_PROVISIONING_PROFILE`).
4. **Registro do app no App Store Connect**: nome, idioma principal (português do Brasil), Bundle ID, SKU.
5. **Conformidade de exportação**: o Info.plist já traz `ITSAppUsesNonExemptEncryption = false` (HTTP/WebSocket local sem criptografia própria). Confirmar com o professor; se a escola entender que se aplica, a resposta muda.
6. **Categoria**: hoje o Info.plist traz Educação (`public.app-category.education`). O app foi pensado para qualquer pessoa, não só para sala de aula; **decidir com o professor** se a categoria deve ser Produtividade ou Utilitários (`LSApplicationCategoryType` em `scripts/build-app.sh` e a escolha no App Store Connect precisam combinar).
7. **Classificação etária** (questionário). Há chat entre participantes opcional (ADR-003): responder conforme o questionário, a confirmar.
8. **Metadados**: descrição, palavras-chave, capturas de tela (Mac, tamanhos exigidos pela Apple), ícone, URL de suporte, versão 1.0.0.
9. **URL da política de privacidade** (obrigatória). Precisa existir uma página pública. **A confirmar com o responsável/IFPI** quem é o responsável pelo texto.
10. **Privacidade do app (App Privacy)**. Proposta de resposta, simples e verdadeira: o app guarda **localmente, no Mac do anfitrião**, nome informado pelo participante, endereço IP, navegador e qualidade da conexão (métricas e lista de presença em CSV). **Nada é enviado aos desenvolvedores nem a terceiros.** Como não há coleta pelo desenvolvedor, a resposta provável é "dados não coletados"; **a confirmar com o responsável/IFPI** (a Apple pode entender de outra forma e a escola é responsável pelos dados de participantes, LGPD).
11. **Notas para a revisão** (sugestão de texto):
    > AulaCast transmite a tela do anfitrião para os navegadores dos participantes na mesma rede local. Usa ScreenCaptureKit: na primeira transmissão o macOS pede a permissão de Gravação de Tela, e a captura só começa quando o anfitrião clica em Iniciar transmissão. Usa a rede local (servidor HTTP na porta 8080 e Bonjour `_aulacast._tcp`) e por isso declara o entitlement de servidor de rede. Nada sai para a internet. Para testar é preciso ao menos um navegador (outro computador ou celular) na mesma rede Wi-Fi acessando o endereço mostrado no app (ou `aulacast.local:8080`). Não há login.
12. **Enviar o pacote**: com o `.pkg` pronto, abrir o **Transporter**, entrar, arrastar o pacote e entregar; depois escolher o build no App Store Connect e enviar para revisão. O número de build (`AULACAST_BUILD`) precisa crescer a cada envio.

## 2. Gerando o pacote

```bash
export AULACAST_BUNDLE_ID=br.edu.ifpi.aulacast            # exemplo, usar o App ID real
export AULACAST_PROVISIONING_PROFILE=~/caminho/AulaCast.provisionprofile
export AULACAST_APP_IDENTITY="Apple Distribution: Nome (TEAMID)"
export AULACAST_INSTALLER_IDENTITY="Mac Installer Distribution: Nome (TEAMID)"
export AULACAST_BUILD=1                                    # sobe a cada envio
./scripts/gerar-appstore.sh            # saída: build/appstore/AulaCast-1.0.0.pkg
```

O script recusa `AULACAST_DEBUG_METRICS=1`, exige binário universal e nomeia a variável que faltar. Verificação impressa ao final: `codesign --verify --deep --strict`, `codesign -d --entitlements :-`, `pkgutil --check-signature`.

## 3. Teste local do sandbox (você, sem a conta Apple)

```bash
AULACAST_SANDBOX_TESTE=1 ./scripts/gerar-appstore.sh /tmp/aulacast-sandbox
open /tmp/aulacast-sandbox/AulaCast.app
```

O app sai assinado ad-hoc **com** os entitlements, e o sandbox vale. Marque cada item:

- [ ] O app abre e mostra a janela (sem crash na inicialização).
- [ ] Um celular/outro computador na mesma Wi-Fi acessa `http://<IP>:8080` e vê a tela (servidor de entrada).
- [ ] `http://aulacast.local:8080` funciona no outro dispositivo (registro mDNS via dns_sd). Se falhar, só o IP funciona: o app deve seguir sem travar.
- [ ] O pedido de Gravação de Tela aparece, a permissão é concedida, "Encerrar e Reabrir" reabre o app, e a captura funciona.
- [ ] Chat entre participantes (se ligado) funciona.
- [ ] Compartilhar arquivos (botão e arrastar) e o participante baixa.
- [ ] Ao encerrar, a tela mostra a transmissão parada na hora; depois aparece o aviso "Lista dos participantes salva" (3 s, o mouse em cima o segura) e **clicar nele** seleciona o arquivo no Finder.
- [ ] A métrica `sessao-*.jsonl` é gravada.
- [ ] Menu Arquivo > "Mostrar pasta de dados no Finder" (Shift+Cmd+D) abre `~/Library/Containers/<id>/Data/Documents/AulaCast`.
- [ ] Wi-Fi do Mac (RSSI) aparece nas métricas, ou some sem erro (ver a validar).
- [ ] Trocar de aplicativo/abrir apps não quebra (notificações do NSWorkspace).

Se algo falhar, veja o motivo: `log stream --predicate 'subsystem == "com.apple.sandbox.reporting"'` ou o app Console (mensagens "deny").

## 4. Riscos conhecidos e itens "a validar com um build assinado"

| Item | Situação |
|---|---|
| `network.server` para NWListener | Chave documentada pela Apple como a de conexões de entrada. Revisores já questionaram o uso sem funcionalidade evidente: a nota de revisão explica. Confirmado como necessário, a validar no teste. |
| `network.client` | Mantido por precaução (Bonjour/dns_sd). **A validar**; remover se o teste passar sem ela. |
| `DNSServiceRegisterRecord` (A record `aulacast.local`) sob sandbox | Não encontrei fonte oficial. **A validar.** Se falhar, o app já notifica `nil` e só o IP funciona. |
| Bonjour `_aulacast._tcp` + NSLocalNetworkUsageDescription | Chaves mantidas no Info.plist. Comportamento sob sandbox **a validar**. |
| ScreenCaptureKit | Sem entitlement de sandbox no `com.apple.security`: a permissão é do TCC (Gravação de Tela). Um fórum da Apple (DTS) diz que `com.apple.security.screen-capture` **não é aceito** no upload; por isso não consta. `com.apple.developer.persistent-content-capture` exige solicitação à Apple e não é usado. **A validar** que `SCShareableContent`/`SCStream` funcionam no sandbox. |
| CoreWLAN (RSSI, ruído, `interfaceName`) | Um tópico antigo do fórum diz que o Wi-Fi scan não funciona no sandbox; DTS diz que não há entitlement específico. Os dados de RSSI podem vir `nil`/zerados, o que o código já trata. **A validar.** Chave de localização (`personal-information.location`) **não** incluída: sem confirmação. |
| `getifaddrs`, `sysctl hw.model` | Leitura permitida no sandbox pelo uso comum; **a validar**. `hw.model` falhando devolve "desconhecido". |
| Arquivos (NSOpenPanel / arrastar) | `files.user-selected.read-only` cobre. O acesso vale enquanto o app roda; **a validar** com arquivos de pastas diferentes. |
| Dados do anfitrião ficam no contêiner | Métricas e listas de presença passam a ficar em `Library/Containers/<id>/Data/Documents/AulaCast`. Quem já usa a versão sem sandbox não vê os arquivos antigos; não há migração. Atalho no menu. |
| Relançar o app (permissão de tela) | Trocado de `Process`+`/usr/bin/open` para `NSWorkspace.openApplication`. **A validar** que reabre. |
| Revisão da Apple | Risco de pedirem justificativa do servidor local e da captura de tela. Mitigação: notas de revisão acima. |
| Manifesto de privacidade (`PrivacyInfo.xcprivacy`) | Incluído no app por `build-app.sh` (sem rastreamento, nada coletado, só `UserDefaults` com o motivo `CA92.1`); `gerar-appstore.sh` recusa o pacote sem ele. **A validar:** que o upload não aponte outra API da lista "required reason" (a busca no código achou só `UserDefaults`). |
| Política de privacidade e App Privacy | Texto e responsável **a confirmar com o responsável/IFPI**. |
| Pasta de dados com nome de participante (LGPD) | Decisão do IFPI, fora do código. |
