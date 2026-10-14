# Documentação do AulaCast

Índice. Abra os documentos pelo ID. As histórias usam o prefixo **US** (não HU).
Itens **Proposto** ainda esperam aprovação do usuário.

| Documento | Conteúdo |
| :--- | :--- |
| [01-especificacao-requisitos.md](01-especificacao-requisitos.md) | RF-01..RF-19 (RF-12 descartado), RNF-01..RNF-10, perguntas em aberto |
| [02-casos-de-uso.md](02-casos-de-uso.md) | UC-01..UC-09 |
| [03-historias-de-usuario.md](03-historias-de-usuario.md) | US-01..US-13 |
| [04-arquitetura-e-design.md](04-arquitetura-e-design.md) | Componentes, protocolo WebSocket, medições, limite de escala (4.1.1), estrutura de arquivos |
| [padroes.md](padroes.md) | Padrões de projeto presentes no código |
| [feedback-tela-do-aluno.md](feedback-tela-do-aluno.md) | Feedback da turma e o que foi feito |
| [relatorio-mudanca-sync-docs.md](relatorio-mudanca-sync-docs.md) | Relatório da sincronização de 14/10/2026 |

## Itens criados ou alterados na sincronização de 14/10/2026
- **RF-17** Compartilhamento de Arquivos (renumerado; era um segundo RF-16).
- **RF-18** Chat visível entre alunos e **RF-19** Ocultar apps da transmissão: Proposto, já implementados na main.
- **RNF-10** Escala da transmissão: Proposto, metas **a definir**.
- **UC-09** Ocultar apps. **US-11**, **US-12**, **US-13** (esta liga ao RNF-10).

## ADR (decisões de arquitetura)
Nunca se apaga um ADR: quando a decisão muda, cria-se outro e o antigo fica "Substituído por".

| ID | Decisão | Status |
| :--- | :--- | :--- |
| [ADR-001](adr/ADR-001-mjpeg-http-multipart.md) | MJPEG por HTTP multipart, quadro codificado uma vez | Proposto (retroativo) |
| [ADR-002](adr/ADR-002-aulacast-local-porta-8080.md) | `aulacast.local` na porta 8080; porta 80 revertida | Proposto (retroativo) |
| [ADR-003](adr/ADR-003-chat-entre-alunos-opcional.md) | Chat entre alunos opcional, desligado por padrão | Proposto (retroativo) |
