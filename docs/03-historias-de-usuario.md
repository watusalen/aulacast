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
  Dado que estou assistindo à aula pelo player web
  Quando eu clicar no botão "Levantar a Mão"
  E digitar meu nome "Carlos - Computador 04"
  Então o botão deve mudar de estado para "Mão Levantada (Clique para cancelar)"
  E o professor deve receber uma notificação visual e um indicador sonoro suave no Mac.
```

---

### US-05: Gestão de Dúvidas pelo Professor
- **Como** Professor,
- **Eu quero** ver um painel com a lista de alunos que levantaram a mão,
- **Para que** eu possa atendê-los em ordem e marcar como resolvido conforme for tirando as dúvidas.

#### Critérios de Aceite (Gherkin):
```gherkin
Cenário: Atender dúvida de aluno
  Dado que os alunos "Carlos" e "Mariana" levantaram a mão
  Quando eu olhar para a barra de menus do macOS ou para o app AulaCast
  Então devo ver o contador "(2) Dúvidas"
  E ao clicar no botão de "OK" ao lado do nome de "Carlos"
  O contador deve decrementar para "(1) Dúvida"
  E o estado da tela do aluno Carlos deve voltar ao normal.
```

---

### US-06: Compartilhamento Rápido de Códigos e Arquivos
- **Como** Professor de Programação,
- **Eu quero** arrastar um arquivo `.swift` ou `.pdf` para o aplicativo,
- **Para que** todos os alunos na sala recebam o arquivo instantaneamente sem eu precisar usar pendrive ou e-mail.

#### Critérios de Aceite (Gherkin):
```gherkin
Cenário: Enviar arquivo para a turma
  Dado que a transmissão está ativa
  Quando eu arrastar o arquivo "ExemploLoop.swift" para a área de arquivos do AulaCast no Mac
  Então o arquivo deve ser disponibilizado na rede local imediatamente
  E uma notificação "Novo arquivo compartilhado: ExemploLoop.swift" deve aparecer na tela de todos os alunos
  E o botão de download deve permitir baixar o arquivo intacto.
```

---

### US-07: Chat Local para Perguntas Textuais
- **Como** Aluno reservado,
- **Eu quero** enviar uma pergunta em texto no chat da sala,
- **Para que** eu possa colar uma linha de código que está dando erro e pedir auxílio.

#### Critérios de Aceite (Gherkin):
```gherkin
Cenário: Envio de mensagem no chat local
  Dado que a aba de chat está aberta na página web do aluno
  Quando eu digitar "Professor, qual a diferença entre let e var?" e pressionar Enter
  Então a mensagem deve aparecer no histórico do chat com o meu nome e horário
  E todos os demais alunos e o professor devem ver essa mensagem em tempo real.
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
```