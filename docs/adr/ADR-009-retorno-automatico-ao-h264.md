# ADR-009: Volta automática ao H.264 depois de cair para MJPEG

- **Status:** Proposto (implementado na branch `integracao-teste`, **ainda não testado em rede real**)
- **Relaciona:** ADR-004 (substitui a cláusula "não volta ao H.264 naquela carga"), RNF-10

## Contexto
O ADR-004 fazia a página cair para MJPEG quando o H.264 não era suportado ou a conexão de `/stream.mp4` caía mais de 5 vezes seguidas, e **ficar** em MJPEG até recarregar. O MJPEG gasta bem mais banda, então um participante com uma queda passageira ficava preso na rota pior pelo resto da transmissão. Decisão do usuário: a página precisa voltar sozinha ao H.264.

## Decisão
- Depois do fallback, a página tenta o H.264 de novo sozinha, com espera crescente: **30 s, 1 min, 2 min e depois a cada 5 min** (`RetornoAoH264`, `js/h264-return.js`).
- Cada espera é **sorteada entre 1x e 2x a base** (por página): se vários participantes caírem juntos, eles não voltam todos no mesmo segundo e não derrubam a rede de novo; a volta é gradual.
- Cada tentativa é uma **prova curta** (`VideoStreamPlayer.tentarDeNovo()`): falha na primeira queda de conexão (sem as 5 reconexões) ou se não começar a tocar em **15 s**. Falhou, volta ao MJPEG e marca a próxima espera.
- Se o vídeo tocar **estável por 5 s**, o H.264 reassume: o MJPEG é desligado (`UIController.desativarMJPEG()`), a espera zera e a métrica `rota` registra MJPEG → H.264.
- **Sem MediaSource** no navegador, não há tentativa nenhuma (não adianta).
- **Só tenta com a transmissão no ar e a aba visível.** Pausada, o servidor só manda o init segment e o vídeo nunca tocaria; encerrada, não há o que ver; aba oculta não reproduz vídeo mudo. Nesses casos o relógio fica marcado e **a espera não sobe** (não gasta prova).
- **Teto de 10 provas** sem sucesso (~1 hora): falha permanente (codec recusado, autoplay bloqueado) não pode abrir uma segunda conexão e pedir quadro-chave para sempre. Zera quando o H.264 volta.
- Prova que falha não religa o MJPEG (ele nunca saiu do ar) nem repete o evento `rota`. Parar no meio de uma prova devolve o player ao estado de fallback.

## Consequências
- Durante a prova (até ~20 s por tentativa) as **duas conexões coexistem**. O custo é limitado e raro; o ADR-004 evitava isso por inteiro.
- Rede ruim e persistente gera uma prova a cada 5 min por participante: tráfego pequeno, mas ele existe.
- **Limite conhecido:** "estável por 5 s" é só "tocou e a conexão não caiu". Não exige `currentTime` avançando, porque tela parada (slide) é normal e não avança. Numa rede fraca o servidor pode descartar a fila do cliente lento sem fechar a conexão, e o participante ficaria num H.264 travado, sem o MJPEG de reserva. Não tratado.
- **Não verificado:** comportamento em Chrome, Safari e iOS reais, e se 5 s de estabilidade bastam para uma rede oscilante (pode ficar alternando). Os valores (30 s, 5 min, 15 s, 5 s) são palpites a calibrar com as métricas.

## Alternativas
- Voltar assim que a rede "parecer boa" por medição: exige medir banda no navegador, que ele não informa direito.
- Manter o MJPEG até recarregar: o comportamento anterior, descartado pelo usuário.
