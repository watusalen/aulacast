# ADR-007: Distribuição pela Mac App Store (sandbox)

Status: **Proposto**

## Contexto
O AulaCast 1.0.0 foi feito sem App Sandbox e distribuído por .dmg. A Mac App Store exige o sandbox. O app escuta TCP numa porta fixa (NWListener), anuncia Bonjour e registra um registro A mDNS via dns_sd, captura a tela (ScreenCaptureKit), lê Wi-Fi (CoreWLAN) e grava arquivos. A conta Apple é do professor; o autor só tem acesso ao App Store Connect.

## Decisão
1. Ativar o App Sandbox com o conjunto mínimo de entitlements: `app-sandbox`, `network.server`, `network.client` (a validar), `files.user-selected.read-only` (`scripts/AulaCast.entitlements`).
2. Os dados passam a vir de `FileManager.urls(for: .documentDirectory)` (`PastasDoApp`): funciona com e sem sandbox. Como o contêiner é escondido, o menu ganha "Mostrar pasta de dados no Finder".
3. Reabrir o app usa `NSWorkspace`, não `Process`.
4. Empacotamento em `scripts/gerar-appstore.sh`, com segredos só por variáveis de ambiente, e modo `AULACAST_SANDBOX_TESTE=1` para testar o sandbox sem conta Apple.
5. Bundle id vem de `AULACAST_BUNDLE_ID` e deve ser igual ao App ID registrado.

## Alternativas
- Continuar só com .dmg (sem sandbox, sem Mac App Store): menos trabalho, sem a vitrine; permanece possível em paralelo.
- Pedir exceções temporárias de entitlement: exigem justificativa à Apple e atrasam; descartado para a 1.0.

## Consequências
- Métricas e chamadas ficam no contêiner; usuários da versão sem sandbox não os veem ali (sem migração).
- Registro A `aulacast.local`, CoreWLAN e ScreenCaptureKit sob sandbox **não foram verificados**: ver `docs/app-store-checklist.md` ("a validar"). Se o registro mDNS falhar, só o IP funciona (degradação já implementada).
- Política de privacidade e respostas de App Privacy dependem do professor/IFPI.

## O que queremos aprender / critério
Se o teste com `AULACAST_SANDBOX_TESTE=1` e a revisão da Apple passarem sem entitlements extras, manter. Se `aulacast.local` ou a captura falharem no sandbox, reavaliar (novo ADR, este não é apagado).
