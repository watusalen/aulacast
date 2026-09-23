import { formatarTamanho } from './files-list.js';

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
   * Cartão no chat avisando dos arquivos que o professor acabou de compartilhar.
   *
   * Antes era uma frase em itálico com os nomes separados por vírgula: numa lista com
   * nome comprido a quebra caía no meio dos nomes ("Lista de Exercícios / 3.pdf") e não
   * dava para ver onde um arquivo terminava e o outro começava. Agora é um arquivo por
   * linha, já como link de download, e o nome longo termina em reticências.
   */
  mostrarArquivosNovos(arquivos) {
    const lista = Array.isArray(arquivos) ? arquivos : [];
    if (lista.length === 0) return;

    const cartao = document.createElement('div');
    cartao.className = 'chat-notice';

    // Título curto e hora à parte, alinhada à direita: juntos numa frase só, a hora
    // caía sozinha na linha de baixo quando o painel é estreito.
    const titulo = document.createElement('div');
    titulo.className = 'chat-notice-title';
    const texto = document.createElement('span');
    texto.className = 'chat-notice-text';
    texto.textContent = lista.length === 1 ? 'Novo arquivo' : `Novos arquivos (${lista.length})`;
    const hora = document.createElement('span');
    hora.className = 'chat-notice-time';
    hora.textContent = new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
    titulo.appendChild(texto);
    titulo.appendChild(hora);
    cartao.appendChild(titulo);

    const itens = document.createElement('ul');
    itens.className = 'chat-notice-files';
    for (const arquivo of lista) {
      const item = document.createElement('li');
      const link = document.createElement('a');
      link.className = 'chat-notice-file';
      link.href = `/arquivos/${encodeURIComponent(arquivo.id)}`;
      link.setAttribute('download', arquivo.name);
      // O nome inteiro aparece ao passar o mouse, já que na linha ele pode ser cortado.
      link.setAttribute('title', arquivo.name);

      const nome = document.createElement('span');
      nome.className = 'chat-notice-name';
      nome.textContent = arquivo.name;

      const tamanho = document.createElement('span');
      tamanho.className = 'chat-notice-size';
      tamanho.textContent = formatarTamanho(arquivo.size);

      link.appendChild(nome);
      link.appendChild(tamanho);
      item.appendChild(link);
      itens.appendChild(item);
    }
    cartao.appendChild(itens);

    this.chatMessages.appendChild(cartao);
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
