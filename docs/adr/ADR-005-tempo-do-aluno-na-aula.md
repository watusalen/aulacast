# ADR-005: Tempo do aluno na aula (identidade, pausa e "à vista")

- **Status:** Proposto
- **Relaciona:** RF-20, UC-10, US-14

## Contexto
O professor quer ver quanto tempo cada aluno ficou na aula e com ela à vista. Uma pessoa pode reconectar, abrir duas abas ou digitar outro nome, e o servidor só enxerga conexões.

## Decisão
- **Identidade:** o mesmo IP é sempre a mesma pessoa (mesmo com outro nome ou conexões simultâneas). Sem IP igual, o nome normalizado (sem caixa, acentos e espaços repetidos) junta com quem não tem conexão aberta; se essa pessoa está conectada de outro IP, são homônimos e ficam separados. O nome exibido é o identificado por último.
- **Relógio:** conta só com a transmissão no ar e sem pausa (inclusive a pausa automática quando a janela some). Começa em Iniciar, congela na pausa, para ao parar ou quando a captura cai. Iniciar de novo zera os números e mantém quem está conectado.
- **"À vista"** = aba visível e em foco (`visibilitychange`/foco do navegador). **Não é rastreio do olhar**: o aluno pode estar com a aba aberta e olhando para outro lugar.
- Implementação: `AttendanceLedger`, sem histórico por evento (memória O(1) por pessoa).

## Consequências
- Cada número tem uma regra única e testável com relógio falso.
- Homônimos em IPs diferentes ao mesmo tempo nunca se misturam; IP compartilhado (NAT) pode juntar pessoas diferentes.
