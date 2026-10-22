# ADR-008: Vocabulário neutro

Status: Proposto

## Contexto
O AulaCast será usado por qualquer pessoa, inclusive fora de sala de aula. Os textos falavam em professor, aluno, turma e aula.

## Decisão
- Todo texto visível (app macOS, página do navegador, Info.plist, CSV, nomes de pasta e arquivo, manifesto, README) usa: **anfitrião** (quem transmite), **participante(s)** (quem assiste), **transmissão** (e **sessão** só para o período todo), **Lista de presença** (CSV, pasta, menu, aviso), **Vendo a transmissão** (antes "com a aula à vista") e **Escolher tela** (antes "Apresentar").
- Identificadores internos, chaves do protocolo JSON, tipos de mensagem, nomes de arquivos e classes **não mudam** (`isProf`, `alunoAberto`, `AttendanceLedger`). O arquivo de métricas mantém as chaves e os tipos de linha (esquema estável); a legenda explica que uma linha de tipo `aluno` é um participante.
- O nome do produto "AulaCast" não muda.
- Os documentos de requisitos mantêm a redação original dos atores.

## Consequências
- O CSV ganhou novos cabeçalhos (`Minutos na transmissão`, `Minutos vendo`, `Percentual vendo`) e novo nome (`lista-de-presenca-AAAA-MM-DD-HHmm.csv` em `Listas de presença/`): quem lê o CSV por nome de coluna precisa ajustar.
- Dois vocabulários convivem (docs de requisitos e código x texto visível); o glossário em `docs/README.md` faz a ponte.

## Revisão
Se o produto voltar a ter público só escolar, reavaliar.
