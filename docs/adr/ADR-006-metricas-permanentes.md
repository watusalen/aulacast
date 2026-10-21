# ADR-006: Métricas permanentes

- **Status:** Proposto
- **Substitui (parcialmente):** a cláusula "só em build de depuração" das métricas no ADR-004
- **Relaciona:** ADR-004, RF-20, RF-21

## Contexto
O arquivo da sessão e as medições por aluno foram criados só para depuração. O usuário decidiu que a coleta e o arquivo ficam no projeto para sempre e existem em todo build; só a exibição no console do navegador do aluno é temporária.

## Decisão
- **Permanente, em todo build:** tratamento de `METRICS`/`ENV`/`EVENT`, `StudentMetricsBook`, arquivo da sessão (`~/Documents/AulaCast/Metricas/`, constante `PastasDoApp.metricas`), linha `[Métricas]` no terminal. O `CONNECTED` sempre traz `metricas: "true"` e o navegador reporta em silêncio a cada 2 s (sem saída no console).
- **Só depuração** (`DEBUG` ou `-DMETRICAS_DEBUG`, `MetricasDebug.consoleAtivo`): `METRICS_TABLE`, `DEBUG_INFO` e tudo que o navegador imprime (painel Debug, textos, tabelas), anunciado por `debugConsole: "true"` no `CONNECTED`.
- A flag é injetável por instância (`WebSocketHandlerService.consoleDeMetricas`) para testar os dois modos.
- Pastas do app centralizadas em `PastasDoApp` (métricas e chamadas); arquivos antigos de `~/AulaCast-metricas` não são migrados.

## Consequências
- O arquivo grava nome, IP e navegador dos alunos em todo build (decisão do usuário; sem aviso na tela de entrada, por decisão dele).
- O custo é o servidor processar `METRICS` sempre (já limitado: teto de linhas, de eventos por segundo e de 64 MB por arquivo).
