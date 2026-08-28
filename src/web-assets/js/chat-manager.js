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

    this.onSendMessage({
      type: 'CHAT_SEND',
      payload: { sender: this.getStudentName(), text: message }
    });

    this.chatMessageInput.value = '';
  }

  appendMessage(author, text, isProf = false) {
    const isOwn = !isProf && (author === this.getStudentName());
    const bubble = document.createElement('div');
    bubble.className = `chat-bubble ${isProf ? 'prof' : ''} ${isOwn ? 'own' : ''}`.trim();

    const time = new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });

    const authorElem = document.createElement('div');
    authorElem.className = 'chat-author';
    authorElem.textContent = isProf ? `Prof. ${author} · ${time}` : `${author} · ${time}`;

    const textElem = document.createElement('div');
    textElem.className = 'chat-text';
    textElem.textContent = text;

    bubble.appendChild(authorElem);
    bubble.appendChild(textElem);
    this.chatMessages.appendChild(bubble);

    this.chatMessages.scrollTop = this.chatMessages.scrollHeight;
  }
}
