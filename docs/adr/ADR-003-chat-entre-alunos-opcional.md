# ADR-003: Chat entre alunos opcional, desligado por padrão

- **Status:** Proposto (retroativo: a decisão já está na main; falta a aprovação do usuário)
- **Relaciona:** RF-09, RF-18, UC-04, US-07, US-11

## Contexto
A mensagem do aluno ia só ao professor, para a conversa paralela não atrapalhar a aula (`docs/02`, UC-04).

## Decisão
O professor pode abrir a conversa entre alunos (`isStudentChatVisibleToClass`), **desligada por padrão**. Com ela ligada, a mensagem do aluno vai a toda a turma, sem duplicar para o autor. Os alunos conectados são avisados na hora por `CHAT_VISIBILITY`, e o valor atual vai no `CONNECTED`.

## Consequências
- O comportamento original (reservado com o professor) continua sendo o padrão.
- RF-09, UC-04 e US-07 passam a dizer "por padrão".
- O descarte de mensagens com o chat desligado continua no servidor.
