# ADR-004: H.264 em fMP4 como transmissão principal; MJPEG como compatibilidade

- **Status:** Proposto (implementado na branch `integracao-teste`, **ainda não medido em sala**)
- **Relaciona:** RNF-10, US-13, ADR-001 (substitui em parte)

## Contexto
O MJPEG manda um JPEG completo por quadro e uma cópia por aluno (ADR-001): com 40 alunos no Wi-Fi a banda não fecha. Meta do usuário (RNF-10): o máximo de quadros, a menor latência e a menor banda por aluno, só no navegador. Broadcast/multicast fica fora (o navegador não recebe UDP).

## Decisão
- Codificar em H.264 por hardware (VideoToolbox, Baseline, baixa latência) e empacotar em fMP4 servido por HTTP puro em `GET /stream.mp4`; o aluno usa `MediaSource` (`ManagedMediaSource` no iPhone).
- Taxa de bits com teto: `clamp(largura × altura × fps × 0,04, 1,2–4 Mbps)` (~2,5 Mbps em 1080p30), quadro-chave a cada 2 s no máximo. **Valores a calibrar com a medição.**
- O MJPEG continua como alternativa: se o H.264 não for suportado ou cair repetidamente, a página cai para ele e **não volta** ao H.264 naquela carga. Os dois não correm juntos.
- Em pausa nenhum codificador recebe quadro, e a retomada força um quadro-chave (evita "fantasma" da tela mostrada na pausa).
- `[Métricas]` no log soma as duas rotas (`H.264 n / MJPEG m`).

## Consequências
- Menos banda por aluno para tela com pouco movimento (a confirmar), ao custo de mais complexidade (empacotador, player MSE, fila por cliente).
- Aluno lento perde a fila e ressincroniza no próximo quadro-chave (pedidos agrupados a no máximo 1 por segundo).
- **Não verificado:** Chrome/Safari/iOS reais, a rede da sala, o bitrate efetivo do encoder em hardware, a legibilidade do texto na taxa escolhida. Uma falha única do teste do encoder real apareceu em 1 de 5 execuções; o rate control não foi descartado como causa.
- Entrar durante uma pausa mostra "Aguardando" até a retomada.

## Alternativas
- Blocos alterados em JPEG/PNG num `<canvas>` (estilo VNC): HTTP puro e texto nítido, não implementado.
- WebRTC e WebCodecs: descartados (UDP/sinalização; WebCodecs exige HTTPS).
- Só puxar quadros (long-poll): melhora cadência e atraso, mas não reduz bytes.
