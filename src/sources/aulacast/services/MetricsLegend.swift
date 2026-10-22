import Foundation

/// A 1ª linha do arquivo de métricas: o que torna o arquivo autoexplicativo para uma IA.
extension MetricsFileLogger {
    static func legenda() -> [String: Any] {
        let comuns = "tipo (nome da linha), tSeg (segundos desde o início da sessão), t (data e hora ISO 8601)"
        return [
            "esquema": versaoDoEsquema,
            "descricao": "Sessão do AulaCast (transmissão de tela na rede local). Arquivo JSONL: cada linha é um objeto JSON. Vocabulário: anfitrião é quem transmite; participante é quem assiste. Os nomes dos campos e dos tipos de linha não mudam: uma linha de tipo 'aluno' é um participante. "
                + "Toda linha tem \(comuns). Valores null significam 'sem medição' (nunca zero inventado).",
            "aviso": "Algumas IAs recusam arquivos grandes (até 64 MB por sessão). Para uma transmissão longa, envie só um trecho "
                + "(a legenda, o inicio e as linhas de um intervalo de tSeg).",
            "privacidade": "Não há texto de chat nem título de janela. Por decisão do anfitrião, o IP e o navegador de cada participante são gravados.",
            "campos": [
                "inicio": [
                    "app": "versão do app (dev em build de depuração)", "debug": "true se for build de depuração",
                    "macOS": "versão do macOS", "modeloMac": "modelo do Mac (hw.model)", "nucleos": "núcleos de CPU",
                    "porta": "porta de conexão do AulaCast", "ip": "IP principal do Mac", "interfaces": "lista de {nome, ip} das interfaces ativas",
                    "resolucao": "resolução escolhida (720p/1080p)", "fps": "quadros por segundo pedidos à captura",
                    "taxaAlvoMbps": "taxa-alvo do encoder H.264 em Mbps", "fonte": "tipo da fonte: monitor ou janela (sem títulos)",
                    "appsOcultos": "quantidade de apps ocultos do monitor (só o número)",
                    "limites": "limites de conexão (conexões MP4 por IP e total, fila em bytes e ms)"
                ],
                "amostra": [
                    "alunos": "participantes com vídeo aberto no intervalo", "aVista": "participantes com a aba visível",
                    "h264": "conexões H.264", "mjpeg": "conexões MJPEG", "telaFps": "quadros/s novos da tela do anfitrião",
                    "mediaFps": "fps médio entregue por participante (o AulaCast mediu)", "minFps": "menor fps entregue a um participante",
                    "mbpsTotal": "Mbit/s enviados aos participantes (entregues ao buffer do sistema)",
                    "perdaEstimadaPct": "(1 - mediaFps/telaFps)*100, 0 a 100; null com a tela parada",
                    "estourosDeFila": "acumulado: vezes que a fila de um participante lento foi descartada",
                    "pedidosDeQuadroChave": "acumulado: quadros-chave pedidos ao encoder", "bytesTotais": "acumulado: bytes de vídeo enviados",
                    "cpuPct": "CPU do app, % de um núcleo (100 = um núcleo cheio)", "memMB": "memória do app em MB (phys_footprint)",
                    "pausada": "true se a transmissão está pausada",
                    "wifi": "Wi-Fi do Mac do anfitrião: {rssi dBm, ruido dBm, taxaTxMbps, canal}; null se não for Wi-Fi ou sem permissão"
                ],
                "aluno": [
                    "nome": "nome do participante", "rota": "H.264 ou MJPEG", "fps": "fps que o navegador mediu", "mbps": "Mbit/s que o navegador mediu",
                    "dropped": "quadros descartados no intervalo", "droppedTotal": "quadros descartados desde a entrada",
                    "lagMs": "atraso do vídeo em ms", "rttMs": "ida e volta do WebSocket em ms", "bufferS": "segundos de vídeo em buffer",
                    "playbackRate": "velocidade de reprodução (1 = normal; acima de 1 = alcançando o ao vivo)",
                    "visivel": "aba visível e em foco", "reportadoHa": "segundos desde a última medição do navegador",
                    "srvFps": "fps que o AulaCast entregou a ele (pelo IP da conexão de vídeo)", "srvMbps": "Mbit/s que o AulaCast enviou a ele",
                    "srvQuadros": "quadros enviados a ele no intervalo", "srvEstouros": "estouros de fila dele no intervalo",
                    "srvCompartilhado": "true se outro participante tem o mesmo IP (os srv* valem para o IP, não só para ele)"
                ],
                "entrada": ["nome": "participante", "ip": "IP", "userAgent": "navegador", "plataforma": "sistema", "telaLarg": "px", "telaAlt": "px",
                            "dpr": "densidade de pixels", "idioma": "idioma", "conexaoTipo": "tipo de rede (Chrome/Android)",
                            "conexaoDownlinkMbps": "banda estimada", "conexaoRttMs": "RTT estimado"],
                "saida": ["nome": "participante", "motivo": "fechou a aba | sem sinal por 30 s | erro", "duracaoS": "segundos conectado"],
                "eventos": [
                    "visibilidade": "nome, visivel", "rota": "nome e dados do navegador (de, para, motivo)",
                    "ws_reconexao / video_reconexao / quota / seek": "nome e dados do navegador",
                    "pausa / retomada": "origem: anfitrião (valor gravado: professor) | janela",
                    "config": "resolução, fps ou fonte mudaram: resolucaoDe/Para, fpsDe/Para, fonteDe/Para (só os que mudaram), taxaAlvoBpsAplicada, encoderAtualizado",
                    "captura": "a captura caiu (motivo)", "mdns": "estado: confirmado | perdido | conflito, nome",
                    "rede": "o IP do Mac mudou (de, para)", "fila": "um participante lento perdeu a fila (ip)",
                    "quadroChave": "pedido de quadro-chave (origem)", "chat": "ligado e alunosVeemUnsAosOutros (participantes veem as mensagens uns dos outros) (sem texto)",
                    "apps": "quantidade de apps ocultos mudou", "truncado": "o arquivo atingiu o limite e parou de crescer"
                ],
                "fim": [
                    "duracaoS": "duração da sessão", "picoAlunos": "máximo de participantes ao mesmo tempo",
                    "porConfiguracao": "um item por blocoConfig: resolucao, fpsAlvo, duracaoS, alunosMedio, mbpsMedioTotal, mbpsMedioPorAluno, fpsMedio, fpsMinimoMedio, lagMsMedio, perdaMediaPct, cpuMedioPct, memMBMedio, estourosDeFila, pedidosDeQuadroChave (deltas no bloco)",
                    "alunos": "por participante: nome, naAulaS, aVistaS, aVistaPct, saidas, maiorTrechoS, fpsMedio, fpsMinimo, mbpsMedio, quadrosDescartados"
                ]
            ],
            "graficos": [
                "1. Linha: telaFps, mediaFps e minFps ao longo de tSeg (amostra).",
                "2. Linha: perdaEstimadaPct e estourosDeFila ao longo de tSeg.",
                "3. Linhas por participante: fps (linha 'aluno') ao longo de tSeg, uma série por nome.",
                "4. Linha dupla: cpuPct e memMB (amostra) com marcas dos eventos pausa/retomada e config.",
                "5. Linha: wifi.rssi, wifi.ruido e wifi.taxaTxMbps (amostra, ignorando null).",
                "6. Mapa de calor: participante x tSeg com lagMs ou srvFps.",
                "7. Linha do tempo (Gantt): entrada e saida de cada participante, com o motivo da saída, e visibilidade.",
                "8. Barras por participante do fim: aVistaPct, fpsMedio e quadrosDescartados.",
                "9. Comparar configurações: Mbps por participante, fps mínimo, lagMs, perdaEstimadaPct e cpuPct agrupados por resolucao/fpsAlvo "
                    + "(barras com a média por bloco; use blocoConfig). Resumo pronto em fim.porConfiguracao. A comparação só é justa se o "
                    + "número de participantes for parecido entre os blocos (ou normalize por mbpsMedioPorAluno)."
            ],
            "configuracao": "Toda linha amostra e aluno (participante) traz a configuração vigente: resolucao, fpsAlvo, taxaAlvoBps (alvo do H.264), "
                + "fonte (monitor|janela) e blocoConfig (1, 2, ... incrementa a cada mudança de resolução, fps ou fonte). "
                + "Agrupe por blocoConfig para comparar, por exemplo, 720p com 1080p, sem juntar eventos. taxaAlvoBps e fpsEncoder são o que o encoder H.264 REALMENTE usa (pode demorar a acompanhar uma "
                + "mudança de fps); resolucao e fpsAlvo são o que o anfitrião escolheu. Depois de uma mudança de qualidade os primeiros "
                + "segundos do novo bloco podem ser transitórios (reinício do encoder, quadro-chave): ao comparar, descarte os primeiros "
                + "5 s de cada blocoConfig. O evento config (um por mudança) traz resolucaoDe/resolucaoPara, fpsDe/fpsPara, fonteDe/fontePara "
                + "só dos campos que mudaram, mais taxaAlvoBpsAplicada e encoderAtualizado.",
            "promptSugerido": "Você é analista de desempenho de redes. Anexei o arquivo de uma transmissão do AulaCast (JSONL; a 1ª linha, "
                + "tipo legenda, explica todos os campos). Leia a legenda, depois: (1) resuma a sessão (duração, pico de participantes, "
                + "resolução e fps, Mac e rede); (2) gere em Python (pandas e matplotlib) os 8 gráficos sugeridos na legenda, "
                + "separando os tipos de linha pelo campo tipo; (3) aponte os períodos em que o vídeo piorou (fps baixo, perda, "
                + "estouros de fila, lag alto) e diga se a causa parece ser Wi-Fi do anfitrião, CPU do Mac, ou o Wi-Fi de um participante "
                + "específico (compare srv* com os campos medidos pelo navegador e use srvCompartilhado com cuidado); "
                + "(4) liste quem saiu da transmissão e por quê; (5) dê recomendações práticas. Não invente valores: null é ausência de medição."
        ]
    }
}
