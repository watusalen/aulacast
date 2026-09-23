# Feedback da turma: tela do aluno

**Como marcar:** troque `[ ]` por `[x]` no que entra. O que ficar `[ ]` fica de fora.
O critério é ser enxuto: se o pedido já é atendido por algo que existe (chat, painel de arquivos),
não se cria outra área para ele.

Legenda do esforço: **P** = poucas linhas · **M** = uma tarde · **G** = mais que isso.

> **Situação (23/09/2026):** todos os itens marcados foram implementados. O que não deu para
> testar aqui: iPhone e Android reais (1a, 1b e a tela acesa no celular); o celular foi emulado
> no Chrome. Detalhes em `docs/04-arquitetura-e-design.md`, seção 4.3.

---

## 1. Usar no celular sem quebrar a tela, e em tela cheia

> "Às vezes a transmissão fica ruim no meu computador [...] queria que ajustasse pra não quebrar os
> componentes e também poder deixar em tela cheia."

**O que já existe:** a página já se adapta a celular (em pé e deitado), e a conversa vira uma gaveta.
O botão de tela cheia existe, mas **some no iPhone**: o Safari do iPhone só põe em tela cheia
elementos `<video>`, e a transmissão é uma imagem (MJPEG).

- [x] **1a. Revisar a página num celular de verdade** (iPhone e Android, em pé e deitado) e corrigir
  o que quebrar. **M**
- [x] **1b. "Adicionar à Tela de Início" abrir sem a barra do navegador.** É o jeito de ter tela
  cheia no iPhone: a aula abre como app, só com a imagem. Android e iPad já têm o botão de tela cheia.
  **P** (precisa ser testado no iPhone, porque a página é `http://`)

## 2. Recolher o chat e os controles laterais

**Já existe:** o botão no topo abre e fecha a barra lateral (feito na rodada passada). Talvez a turma
tenha usado uma versão anterior.

- [x] **2a. Nada a fazer**, só confirmar com a turma na próxima aula.
- [ ] **2b. Deixar o botão de recolher mais visível** (ícone maior, ou dica na primeira vez). **P**

## 3. Botão "Levantar a mão"

**Situação:** foi removido a seu pedido. A turma sugere trazer de volta escondido no chat.

- [ ] **3a. Manter fora.** O aluno já pode escrever "tenho uma dúvida" no chat, e isso chega só
  para o professor. *(recomendado: enxuto)*
- [x] **3b. Voltar como ícone pequeno dentro do chat.** **M** (volta o protocolo, o contador no
  professor e os testes)

## 4. "A tela de quem está assistindo fica apagando"

**Não está claro o que é.** Há duas leituras, com correções diferentes:

- [x] **4a. O monitor ou o celular do aluno apaga (economia de energia)** porque ninguém mexe no
  mouse ou na tela. O navegador tem um jeito de impedir isso (Wake Lock), mas só em `https://`, e a
  aula é `http://`. Resta o truque de manter um vídeo mudo tocando, que é o que as bibliotecas
  "NoSleep" fazem. **M**
- [x] **4b. A imagem pisca ou fica preta por instantes** (reconexão do vídeo). Precisa de um teste
  com a rede do laboratório para achar a causa. **M/G**

**Pergunta para a turma:** é o monitor que apaga (4a) ou a imagem da aula que pisca (4b)?

## 5. Tela cheia com a tecla F

**Não existe.** Hoje só há o botão. Com F entra e sai da tela cheia, como no YouTube. Esc já sai.

- [x] **5. Tecla F para tela cheia.** **P**

## 6. Área de materiais e links da aula

> Links usados na aula, Portal do Aluno, livros, arquivos do professor.

**O que já existe:** os **arquivos** já têm o painel Arquivos, e os **links** podem ir pelo chat. O
problema é que **hoje os links no chat não são clicáveis**: aparecem como texto e o aluno precisa
copiar e colar.

- [x] **6a. Links clicáveis nas mensagens do professor** (abrem em nova aba). Resolve o pedido sem
  criar outra área. **P** *(recomendado)*
- [x] **6b. Fixar uma mensagem no topo do chat** (ex.: o link do Portal do Aluno fica sempre à vista,
  mesmo com a conversa andando). **M**
- [ ] **6c. Área separada de "Materiais e links".** Duplica o chat e o painel de arquivos. **G**
  *(não recomendado)*

## 7. Comunicados do professor sem conversa paralela entre alunos

**Já existe:** os alunos **não veem** as mensagens uns dos outros; o que um aluno escreve chega só
ao professor. E o professor pode desligar "Alunos podem escrever" no painel do chat, e aí o chat
vira só comunicados.

- [x] **7a. Nada a fazer.**
- [ ] **7b. Dizer isso na tela do aluno**, uma linha no chat: "Suas mensagens vão só para o
  professor." (A turma pediu uma coisa que já existe, então ela não sabe disso.) **P**

---

## Além do feedback (pedidos seus)

- [x] **8. Tela do aluno em Material 3**, no mesmo desenho da tela do professor: as mesmas cores,
  fontes (Google Sans Flex e Material Symbols servidas pelo próprio app, sem internet), cantos e
  animações; imagem no palco escuro e a conversa num painel. Sem acrescentar informação na tela. **G**
- [ ] **9. Janelas fechadas na lista de fontes** (o caso do WhatsApp): tirar da lista as janelas
  cujas miniaturas não podem ser capturadas, e separar as minimizadas ou em outra mesa. **M**
