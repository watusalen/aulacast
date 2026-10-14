# Relatório de mudança: sincronização dos docs com a main (14/10/2026)

**Por quê:** `docs/` parou em 23/09 e 9 commits de funcionalidade (aulacast.local, chat entre alunos, ocultar apps etc.) não chegaram lá. Decisão do usuário: o código está certo e os docs passam a refletir o código.
**Base:** `main` @ `bd42b17`. Branch de trabalho: `worktree-docs-sync` (sem commit).

## O que mudou e onde
| Onde | O quê | IDs |
| :--- | :--- | :--- |
| `docs/01` | Endereço `aulacast.local:8080`; RF-08 é `<img>` MJPEG; RF-09 "por padrão"; RF-16 duplicado resolvido (arquivos = RF-17); RF-18 e RF-19 novos; RNF-03 com a medição e a unidade em aberto; RNF-05, RNF-07 (Material 3), RNF-09 (mDNS/UDP 5353); **RNF-10** novo; seção "Perguntas em Aberto" | RF-05/08/09/16/17/18/19, RNF-03/05/07/09/10 |
| `docs/02` | Endereço e "Copiar link" (UC-01, UC-02 EX-00); UC-04 com FA-01; **UC-09** novo; UC-08 cita RF-17 | UC-01/02/04/08/09 |
| `docs/03` | Endereço (US-01, US-02); US-07 "com a opção desligada"; **US-11, US-12, US-13** novas; US-10 cita RF-17 | US-01/02/07/10/11/12/13 |
| `docs/04` | Nomes reais de componentes (§2); `CHAT_VISIBILITY` e campos do `CONNECTED` (§3.1, §3.12); JPEG 0,6 e `queueDepth` 5; seção **4.1.1 Limite de escala conhecido**; árvore de arquivos; 12 arquivos de teste web | RNF-10, RF-18, RF-19 |
| `README.md` (raiz) | `aulacast.local:8080`, `scripts/`, nota sobre MJPEG e RNF-10 | RF-05 |
| `docs/feedback-tela-do-aluno.md` | Item 7b marcado como feito | |
| Novos | `docs/README.md` (índice), `docs/adr/ADR-001..003`, `docs/padroes.md`, este relatório | ADR-001..003 |
| `src/tests/aulacast-tests/TestRunnerMain.swift` | Só dois **comentários** com ID de UC corrigido (linhas ~34 e ~144) | UC-04, UC-06, RF-07 |

## Revisão
- **`critic`:** reprovou a primeira versão. Corrigi os achados, entre eles: a promessa de renomeação do nome mDNS (não verificada no código), o IP "no painel" (o painel mostra só `aulacast.local` durante a sessão), os três ADRs que nasceram "Aceito" (agora **Proposto**), a conta de banda (agora pior caso, com ~2–5 fps e o Wi-Fi como suposição), a unidade da meta de CPU e a contradição sobre `.contentProcessed`.
- **`qa`:** os 13 desvios da auditoria constam como resolvidos; links do índice resolvem.
- Não houve segunda rodada do `critic` depois das correções.

## Verificado
- JS: `node --test "tests/*.test.js"`: 141 passaram, 0 falharam.
- Swift: `swift run AulaCastTestRunner`: 295 passaram, 0 falharam na execução isolada.

## Não verificado
- Conflito de nome mDNS com dois Macs na mesma rede (pergunta 5 em `docs/01`).
- Tamanho real do quadro JPEG, fps entregue por aluno e banda real do Wi-Fi da sala: todos os números de banda são **estimativa**.
- Resolução de `.local` no Wi-Fi da sala e nos clientes Linux/Windows do laboratório.

## Fragilidade da suíte Swift
Os testes usam **portas fixas** (faixa 81xx). Duas execuções ao mesmo tempo colidem ("Address already in use") e produzem falhas espúrias. Aconteceu com execuções sobrepostas durante a revisão. Fora do escopo desta mudança.

## Pendências para o usuário aprovar (todos **Proposto**)
RF-17 (renumeração), RF-18, RF-19, RNF-10, UC-09, US-11/12/13, ADR-001/002/003. Perguntas em aberto: unidade e valor da meta de CPU (RNF-03); FPS mínimo, banda por aluno e latência (RNF-10); prioridade de RF-18 e RF-19; persistência dos apps ocultos; comportamento do conflito de nome mDNS.
