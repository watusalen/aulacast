# Histórias de Usuário (User Stories) & Critérios de Aceite
## Projeto: AulaCast - Transmissão de Tela em Rede Local (IFPI)

---

### US-01: Início Rápido da Transmissão de Tela
- **Como** Professor de Computação do IFPI,
- **Eu quero** iniciar a transmissão da minha tela em 1 clique no meu Mac,
- **Para que** eu possa mostrar o código que estou escrevendo sem perder tempo configurando equipamentos ou depender do projetor da sala.

#### Critérios de Aceite (Gherkin):
```gherkin
Cenário: Iniciar transmissão com sucesso
  Dado que o aplicativo AulaCast está aberto no meu Mac
  E as permissões de Gravação de Tela do macOS estão ativadas
  Quando eu selecionar a fonte "Monitor Principal" e clicar em "Iniciar Transmissão"
  Então o status do aplicativo deve mudar para "Transmitindo" em verde
  E o endereço IP/URL da sala deve ser exibido com destaque na tela (ex: http://192.168.1.15:8080)
  E a captura de tela deve consumir menos de 15% de CPU.
```

---

### US-02: Acesso Imediato via Navegador Web (Contornando o Firewall Institucional)
- **Como** Aluno do laboratório do IFPI,
- **Eu quero** acessar a transmissão da aula digitando apenas o endereço web local fornecido pelo professor,
- **Para que** eu possa assistir à aula em qualquer computador (Linux/Windows) sem depender da internet externa e sem ser bloqueado pelo firewall da instituição (que impede o uso de Discord, Meet ou Zoom).

#### Critérios de Aceite (Gherkin):
```gherkin
Cenário: Acesso ao player web pelo aluno em rede com firewall restrito
  Dado que o professor iniciou a transmissão na rede local da sala
  E a rede de internet da instituição está instável ou com firewall bloqueando serviços de chamadas externas
  Quando eu abrir o navegador Chrome ou Firefox no Linux do laboratório
  E acessar a URL local "http://192.168.1.15:8080"
  Então a página web do AulaCast deve carregar em menos de 2 segundos via tráfego exclusivamente local
  E a transmissão de tela do professor deve ser exibida no player central sem bloqueios.
```

---

### US-03: Transmissão de Janela Específica de Aplicativo
- **Como** Professor,
- **Eu quero** selecionar para transmitir apenas a janela do Xcode (ou VS Code),
- **Para que** meus alunos vejam apenas o ambiente de desenvolvimento e minhas notificações pessoais/e-mails continuem privados.

#### Critérios de Aceite (Gherkin):
```gherkin
Cenário: Transmitir apenas uma janela específica
  Dado que eu tenho o Xcode e o Safari abertos no meu Mac
  Quando eu abrir a lista de fontes de captura no AulaCast
  E selecionar especificamente a janela "Xcode - ProjetoFinal"
  Então o streaming enviado para os alunos deve conter apenas o conteúdo dessa janela do Xcode
  E quaisquer outras janelas sobrepostas ou áreas da área de trabalho não devem ser visíveis para os alunos.
```

---

### US-04: Notificação de Dúvida ("Levantar a Mão")
- **Como** Aluno com dúvida durante a explicação,
- **Eu quero** clicar no botão "Levantar a Mão" na minha tela,
- **Para que** o professor saiba que preciso de ajuda sem eu ter que interromper a explicação falada.

#### Critérios de Aceite (Gherkin):
```gherkin
Cenário: Aluno sinaliza dúvida ao professor
  Dado que já me identifiquei e estou assistindo à aula pelo player web
  Quando eu clicar no botão "Levantar a Mão"
  Então o botão deve mudar de estado para "Mão Levantada"
  E devo ver o aviso "O professor foi avisado da sua dúvida"
  E meu nome deve aparecer destacado na lista do professor, com o ícone de mão levantada.
```

---

### US-05: Acompanhar Dúvidas da Turma
- **Como** Professor,
- **Eu quero** ver a lista dos alunos que estão com a mão levantada,
- **Para que** eu saiba quem precisa de ajuda sem interromper minha explicação.

#### Critérios de Aceite (Gherkin):
```gherkin
Cenário: Visualizar dúvidas pendentes
  Dado que os alunos "Carlos" e "Mariana" levantaram a mão
  Quando eu olhar para o app AulaCast
  Então devo ver o contador "Dúvidas: 2"
  E as linhas de "Carlos" e "Mariana" devem exibir o ícone de mão levantada
  E o contador só deve baixar quando o próprio aluno abaixar a mão.
```

> **Decisão de projeto:** seguindo o modelo do Google Meet, o professor não abaixa a mão de ninguém — quem levantou é quem cancela. Isso evita que o professor "resolva" uma dúvida que o aluno ainda considera aberta.

---

### US-06: Identificação do Aluno na Entrada
- **Como** Professor,
- **Eu quero** que cada aluno informe nome e matrícula antes de assistir,
- **Para que** eu saiba exatamente quem está na aula, e não apenas quantos dispositivos se conectaram.

#### Critérios de Aceite (Gherkin):
```gherkin
Cenário: Aluno entra na aula identificado
  Dado que eu abri o endereço da sala no navegador
  Quando eu informar o nome "Ana Beatriz Sousa" e a matrícula "2021234TADS5678"
  Então a transmissão deve ser liberada para mim
  E meu nome e matrícula devem aparecer na lista do professor.

Cenário: Matrícula fora do padrão do IFPI
  Dado que eu estou na tela de entrada
  Quando eu informar a matrícula "2021234INFO5678"
  Então devo ver a mensagem "A matrícula deve ter TADS na posição 8"
  E a transmissão não deve ser liberada.

Cenário: Validação também no servidor
  Dado que um cliente adulterado envia uma matrícula inválida direto pelo WebSocket
  Então o servidor deve recusar a identificação
  E o aluno não deve aparecer na lista de presença.
```

---

### US-07: Chat Local para Perguntas Textuais
- **Como** Aluno reservado,
- **Eu quero** enviar uma pergunta em texto no chat da sala,
- **Para que** eu possa colar uma linha de código que está dando erro e pedir auxílio.

#### Critérios de Aceite (Gherkin):
```gherkin
Cenário: Envio de mensagem no chat local
  Dado que estou com a página da aula aberta
  Quando eu digitar "Professor, qual a diferença entre let e var?" e pressionar Enter
  Então a mensagem deve aparecer no meu próprio histórico
  E o professor deve recebê-la no aplicativo dele
  E nenhum colega deve ver essa mensagem.

Cenário: Resposta do professor
  Dado que o professor respondeu no chat do aplicativo
  Então todos os alunos conectados devem ver a resposta.
```

---

### US-08: Reconexão Automática em caso de Oscilação de Sinal
- **Como** Aluno em um computador com Wi-Fi oscilando,
- **Eu quero** que a página tente reconectar sozinha se o sinal cair por alguns segundos,
- **Para que** eu não precise ficar recarregando a página manualmente.

#### Critérios de Aceite (Gherkin):
```gherkin
Cenário: Reconexão transparente após queda de sinal
  Dado que a conexão Wi-Fi do aluno oscilou e perdeu pacotes WebSocket por 3 segundos
  Quando a conexão for restaurada pelo sistema operacional
  Então o cliente Web deve reconectar automaticamente ao servidor do professor em até 2 segundos
  E o vídeo deve voltar a ser reproduzido sem necessidade de dar F5 na página.

Cenário: Queda longa da rede
  Dado que a rede do laboratório ficou fora por mais de um minuto
  Quando ela voltar
  Então o cliente deve continuar tentando em intervalos maiores e reconectar sozinho
  E a turma não deve precisar recarregar a página.

Cenário: Queda apenas do fluxo de vídeo
  Dado que o vídeo trafega numa conexão separada do canal de mensagens
  Quando somente a conexão de vídeo cair, permanecendo o WebSocket ativo
  Então o cliente deve restabelecer o vídeo por conta própria
  E a imagem não deve ficar congelada indicando "Conectado".
```

---

### US-09: Saber Quem Está Realmente Assistindo
- **Como** Professor,
- **Eu quero** distinguir os alunos que estão com a aula à vista dos que apenas deixaram a página aberta,
- **Para que** a lista de presença reflita quem está de fato acompanhando.

#### Critérios de Aceite (Gherkin):
```gherkin
Cenário: Aluno sai da tela da aula
  Dado que a aluna "Ana Beatriz" está assistindo à transmissão
  Quando ela minimizar a janela, trocar de aba ou clicar em outro aplicativo
  Então a linha dela deve passar a exibir o ícone de olho cortado
  E o contador de alunos assistindo deve diminuir em 1.

Cenário: Aluno retorna à aula
  Dado que a aluna "Ana Beatriz" estava fora da tela da aula
  Quando ela voltar para a página da transmissão
  Então a linha dela deve voltar a exibir o ícone de olho aberto
  E o contador de alunos assistindo deve aumentar em 1.
```