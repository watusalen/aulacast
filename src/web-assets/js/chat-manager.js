export class ChatManager {
  /** O nome vem da identificação feita na entrada, não de um campo separado no chat. */
  constructor(onSendMessage, getStudentName) {
    this.onSendMessage = onSendMessage;
    this.getStudentName = getStudentName;
    this.chatForm = document.getElementById('chatForm');
    this.chatMessageInput = document.getElementById('chatMessageInput');
    this.chatMessages = document.getElementById('chatMessages');

    this.chatForm.addEventListener('submit', (e) => this.handleSubmit(e));
  }

  handleSubmit(e) {
    e.preventDefault();
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
