# ADR-001: MJPEG por HTTP multipart, com o quadro codificado uma vez

- **Status:** Proposto (retroativo: a decisão já está na main; falta a aprovação do usuário)
- **Relaciona:** RF-04, RF-08, RNF-01, RNF-04, RNF-05, RNF-10

## Contexto
O aluno usa só o navegador, sem instalar nada. A rede é local e offline, e o servidor é HTTP puro, sem TLS.

## Decisão
Cada quadro da captura vira um JPEG uma única vez (`MJPEGFrameEncoder`, qualidade 0,6). Cada aluno abre `GET /stream` (`multipart/x-mixed-replace`) numa `<img>`, e um laço por aluno envia sempre o quadro mais recente (`MJPEGStreamerService`).

## Consequências
- Funciona em qualquer navegador, sem plugin, codec nem HTTPS.
- A codificação não cresce com a turma, mas o envio sim: uma cópia por aluno, O(n·S) por quadro. Com 40 alunos em Wi-Fi isso derruba o fps (estimativa em `docs/04`, seção 4.1.1; **sem medição**).
- Cada quadro é um JPEG completo, sem aproveitar o quadro anterior.
- Qualidade e fps não se adaptam à rede de cada aluno.

## Alternativas
- WebRTC: descartado (UDP, sinalização e pilha pesada).
- WebCodecs: só em contexto seguro (HTTPS), então não funciona em `http://aulacast.local`.
- **H.264 em fMP4 via MSE** (`/stream.mp4`): direção em estudo para o RNF-10. Há um protótipo na branch local `compressao-video-h264` (commit `c63592b`), fora da main. Decidir por ele pede um ADR novo, que substituiria este em parte.
