# Padrões de projeto no AulaCast

Só o que existe no código (conferido em 14/10/2026). Nenhum experimento em andamento.

| Padrão | Onde | Para quê | Alternativa simples | Status |
| :--- | :--- | :--- | :--- | :--- |
| Inversão de dependência por protocolo (SOLID: D e I) | `core/`: `ScreenCaptureProtocol`, `VideoEncoderProtocol`, `NetworkServerProtocol`, `FrameReceiverProtocol` | Testar o domínio com dublês (`TestDoubles.swift`) sem captura nem rede reais | Classes concretas | Em uso |
| Observer (protocolos de eventos) | `core/EventObserverProtocols.swift` (chat, mão levantada, clientes, presença, ciclo de captura) | A rede avisa o `MainViewModel` sem acoplar a ele | Closures soltas | Em uso |
| Null Object | `SemAnuncioService` (`BonjourAdvertiserService.swift`) | Servidor sem anúncio Bonjour (dublês de teste) sem `if` de nulo | `Optional` | Em uso |
| MVVM | `MainViewModel` (`ObservableObject`) e `views/` | Estado da tela separado do núcleo | Estado direto nas views | Em uso |

## Observação
`SystemActivityProtocol` e `ScreenRecordingPermissionProtocol` estão em `services/`, não em `core/`. O código não foi alterado; fica como ponto a decidir.
