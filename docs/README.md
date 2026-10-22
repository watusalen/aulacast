# Documentação do AulaCast

Índice. Abra os documentos pelo ID. As histórias usam o prefixo **US** (não HU).
Itens **Proposto** ainda esperam aprovação do usuário.

## Glossário (vocabulário neutro, ADR-008)
- **Anfitrião**: quem transmite a tela (antes "professor").
- **Participante**: quem assiste pelo navegador (antes "aluno"; "turma" e "colegas" viram "participantes").
- **Transmissão**: o que o anfitrião mostra (antes "aula"). **Sessão**: o período todo, do início ao fim.
- **Lista de presença**: o CSV de quem entrou (antes "chamada"; "chamada" também pode ser chamada de vídeo).
- **Vendo** / "Vendo a transmissão": aba visível e em foco (antes "com a aula à vista").
- Nota: os documentos de requisitos, casos de uso e histórias mantêm os atores com a redação original (professor/aluno). Os nomes internos no código e as chaves do protocolo também não mudaram. Só o texto que o usuário vê mudou.

| Documento | Conteúdo |
| :--- | :--- |
| [01-especificacao-requisitos.md](01-especificacao-requisitos.md) | RF-01..RF-21 (RF-12 descartado), RNF-01..RNF-10, perguntas em aberto |
| [02-casos-de-uso.md](02-casos-de-uso.md) | UC-01..UC-11 |
| [03-historias-de-usuario.md](03-historias-de-usuario.md) | US-01..US-15 |
| [04-arquitetura-e-design.md](04-arquitetura-e-design.md) | Componentes, protocolo WebSocket, medições, limite de escala (4.1.1), estrutura de arquivos |
| [padroes.md](padroes.md) | Padrões de projeto presentes no código |
| [feedback-tela-do-aluno.md](feedback-tela-do-aluno.md) | Feedback da turma e o que foi feito |
| [relatorio-mudanca-sync-docs.md](relatorio-mudanca-sync-docs.md) | Relatório da sincronização de 14/10/2026 |

## Itens criados ou alterados na sincronização de 14/10/2026
- **RF-17** Compartilhamento de Arquivos (renumerado; era um segundo RF-16).
- **RF-18** Chat visível entre alunos e **RF-19** Ocultar apps da transmissão: Proposto, já implementados na main.
- **RNF-10** Escala da transmissão: Proposto, metas **a definir**.
- **RF-20** Tempo de cada aluno na aula, **UC-10**, **US-14**, **ADR-005**: Proposto.
- **UC-09** Ocultar apps. **US-11**, **US-12**, **US-13** (esta liga ao RNF-10).
- **RF-21** Chamada em CSV ao encerrar, **UC-11**, **US-15**, **ADR-006** Métricas permanentes: Proposto. ADR-005 ganhou os nomes usados; ADR-004 ganhou nota de substituição parcial.

## ADR (decisões de arquitetura)
Nunca se apaga um ADR: quando a decisão muda, cria-se outro e o antigo fica "Substituído por".

| ID | Decisão | Status |
| :--- | :--- | :--- |
| [ADR-001](adr/ADR-001-mjpeg-http-multipart.md) | MJPEG por HTTP multipart, quadro codificado uma vez | Proposto (retroativo) |
| [ADR-002](adr/ADR-002-aulacast-local-porta-8080.md) | `aulacast.local` na porta 8080; porta 80 revertida | Proposto (retroativo) |
| [ADR-003](adr/ADR-003-chat-entre-alunos-opcional.md) | Chat entre alunos opcional, desligado por padrão | Proposto (retroativo) |
| [ADR-004](adr/ADR-004-h264-fmp4-transmissao-principal.md) | H.264/fMP4 como transmissão principal; MJPEG como compatibilidade | Proposto |
| [ADR-005](adr/ADR-005-tempo-do-aluno-na-aula.md) | Tempo do aluno: identidade por IP/nome, pausa excluída, "à vista" = aba visível e em foco | Proposto |
| [ADR-006](adr/ADR-006-metricas-permanentes.md) | Métricas permanentes em todo build; console/broadcast só em depuração | Proposto |
| [ADR-007](adr/ADR-007-distribuicao-mac-app-store-sandbox.md) | Distribuição pela Mac App Store (sandbox); checklist em [app-store-checklist.md](app-store-checklist.md) | Proposto |
| [ADR-008](adr/ADR-008-vocabulario-neutro.md) | Vocabulário neutro: anfitrião e participante, sem termos de escola | Proposto |
