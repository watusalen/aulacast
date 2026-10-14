# ADR-002: `aulacast.local` na porta fixa 8080; redirecionamento da porta 80 revertido

- **Status:** Proposto (retroativo: a decisão já está na main; falta a aprovação do usuário)
- **Relaciona:** RF-03, RF-05, RNF-05, RNF-09, UC-01, UC-02

## Contexto
Digitar um IP que muda a cada rede é ruim para a turma.

## Decisão
O app registra o nome `aulacast.local` por mDNS (`MDNSHostnameService`), e o painel mostra `aulacast.local:8080` com a sessão aberta. O IP:8080 segue como alternativa. A porta é fixa em 8080, também no anúncio Bonjour (`BonjourAdvertiserService`, no próprio listener).

## Consequências
- O aluno digita um nome estável. Em redes que bloqueiam mDNS, usa o IP, que o professor copia com "Copiar link" (UC-02, EX-00); o painel não o mostra durante a sessão.
- **Conflito de nome tratado sozinho:** o sistema não renomeia um registro único, ele avisa `NameConflict`. O `MDNSHostnameService` tenta `aulacast-2.local`, `-3` e assim por diante (até 20), só divulga o nome confirmado e o retira ao perdê-lo; sem nome, o painel mostra o IP. Verificado com três registros na mesma máquina; falta testar com dois Macs reais (pergunta 5 em `docs/01`, seção 4).
- O `:8080` continua visível.

## Alternativas
- Redirecionar a porta 80 para a 8080 para esconder o `:8080`: foi implementado e **revertido** (commit `0d38433`; comentário em `MainViewModel.swift:21-24`). O motivo detalhado está nesse commit e não foi reexaminado aqui.
