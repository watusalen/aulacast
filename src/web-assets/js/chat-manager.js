export class ChatManager {
  /** O nome vem da identificação feita na entrada, não de um campo separado no chat. */
  constructor(onSendMessage, getStudentName) {
    this.onSendMessage = onSendMessage;
    this.getStudentName = getStudentName;
    this.chatForm = document.getElementById('chatForm');
    this.chatMessageInput = document.getElementById('chatMessageInput');
    this.chatMessages = document.getElementById('chatMessages');

    this.chatSendBtn = document.getElementById('chatSendBtn');
    this.chatEnabled = true;

    this.chatForm.addEventListener('submit', (e) => this.handleSubmit(e));
  }

  /**
   * Reflete na tela o botão de chat do professor.
   *
   * O servidor já descartava a mensagem com o chat desligado, mas sem nada mudar no
   * navegador: o aluno escrevia, enviava e o texto simplesmente evaporava. Aqui o campo e
   * o botão ficam inativos, então dá para ver que não adianta tentar — sem anunciar à turma
   * que o professor desligou o chat.
   */
  setEnabled(enabled) {
    this.chatEnabled = enabled;

    this.chatMessageInput.disabled = !enabled;
    this.chatSendBtn.disabled = !enabled;

    // Um campo inativo com texto parado dentro parece travado, não desligado.
    if (!enabled) {
      this.chatMessageInput.value = '';
      this.chatMessageInput.blur();
    }
  }

  handleSubmit(e) {
    e.preventDefault();

    // Campo desabilitado já barra o envio pela interface, mas o submit ainda pode ser
    // disparado por script — e o cliente não deve mandar o que já sabe recusado.
    if (!this.chatEnabled) return;

    const message = this.chatMessageInput.value.trim();
    if (!message) return;

    // O nome do remetente é o da identificação, guardado pelo servidor.
    const enviada = this.onSendMessage({
      type: 'CHAT_SEND',
      payload: { text: message }
    });

    // Sem conexão a mensagem não sai. Antes o campo era limpo do mesmo jeito e a
    // pergunta do aluno sumia sem aviso; agora o texto fica para ele reenviar.
    if (enviada === false) {
      this.mostrarAviso('Sem conexão: a mensagem não foi enviada. Tente de novo quando reconectar.');
      return;
    }

    this.chatMessageInput.value = '';
  }

  /**
   * Linha de sistema no chat avisando que chegou arquivo: só informa, não baixa.
   *
   * O download fica num lugar só, a lista de Arquivos (onde o arquivo novo ganha a
   * etiqueta "Novo"). Um cartão com links aqui criava um segundo caminho para a mesma
   * coisa. Como mensagem de sistema, segue o padrão dos chats: uma linha, centralizada,
   * em tom neutro, diferente das mensagens de verdade.
   */
  mostrarArquivosNovos(arquivos) {
    const lista = Array.isArray(arquivos) ? arquivos : [];
    if (lista.length === 0) return;

    const linha = document.createElement('div');
    linha.className = 'chat-event';
    linha.setAttribute('role', 'status');

    const texto = document.createElement('span');
    texto.className = 'chat-event-text';
    texto.textContent = lista.length === 1
      ? `Novo arquivo: ${lista[0].name}`
      : `${lista.length} arquivos novos`;
    if (lista.length === 1) texto.setAttribute('title', lista[0].name);

    const hora = document.createElement('span');
    hora.className = 'chat-event-time';
    hora.textContent = new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });

    linha.appendChild(texto);
    linha.appendChild(hora);
    this.chatMessages.appendChild(linha);
    this.chatMessages.scrollTop = this.chatMessages.scrollHeight;
  }

  mostrarAviso(texto) {
    const aviso = document.createElement('div');
    aviso.className = 'chat-bubble system';
    aviso.textContent = texto;
    this.chatMessages.appendChild(aviso);
    this.chatMessages.scrollTop = this.chatMessages.scrollHeight;
  }

  appendMessage(author, text, isProf = false) {
    const isOwn = !isProf && (author === this.getStudentName());
    const bubble = document.createElement('div');
    bubble.className = `chat-bubble ${isProf ? 'prof' : ''} ${isOwn ? 'own' : ''}`.trim();

    const time = new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });

    const authorElem = document.createElement('div');
    authorElem.className = 'chat-author';
    // O servidor já manda "Professor" como remetente; prefixar "Prof." dava "Prof. Professor".
    authorElem.textContent = `${author} · ${time}`;

    const textElem = document.createElement('div');
    textElem.className = 'chat-text';
    textElem.textContent = text;

    bubble.appendChild(authorElem);
    bubble.appendChild(textElem);
    this.chatMessages.appendChild(bubble);

    this.chatMessages.scrollTop = this.chatMessages.scrollHeight;
  }
}
