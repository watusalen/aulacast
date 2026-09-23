import { escreverComLinks } from './links.js';

function horaAgora() {
  return new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
}

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

    this.fixada = document.getElementById('chatPinned');
    this.fixadaTexto = document.getElementById('chatPinnedText');
    this.fixadaMais = document.getElementById('chatPinnedMore');
    this.textoFixado = null;

    this.chatForm.addEventListener('submit', (e) => this.handleSubmit(e));
    if (this.fixadaMais) {
      this.fixadaMais.addEventListener('click', () => this.alternarFixadaInteira());
    }
    // O "Ver mais" depende da largura do painel: girar o celular ou abrir a folha muda
    // quantas linhas o texto ocupa.
    if (this.fixadaTexto && typeof ResizeObserver === 'function') {
      new ResizeObserver(() => this.atualizarVerMais()).observe(this.fixadaTexto);
    }
  }

  /**
   * Reflete na tela o botão de chat do professor.
   *
   * O servidor já descartava a mensagem com o chat desligado, mas sem nada mudar no
   * navegador: o aluno escrevia, enviava e o texto simplesmente evaporava. Aqui o campo e
   * o botão ficam inativos, então dá para ver que não adianta tentar — sem anunciar à turma
   * que o professor desligou o chat. A mão ao lado continua valendo: não é escrever.
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

    if (lista.length === 1) {
      // O nome inteiro fica na dica: a linha corta nomes compridos com reticências.
      this.mostrarEvento(`Novo arquivo: ${lista[0].name}`, '', lista[0].name);
    } else {
      this.mostrarEvento(`${lista.length} arquivos novos`);
    }
  }

  /** O professor abaixou a mão do aluno: uma linha curta, no mesmo tom das de sistema. */
  mostrarMaoAbaixada() {
    this.mostrarEvento('O professor abaixou sua mão', 'mao');
  }

  /** Linha de sistema: texto e hora, centralizados, sem nada para clicar. */
  mostrarEvento(textoDoEvento, variante = '', dica = '') {
    const linha = document.createElement('div');
    linha.className = variante ? `chat-event ${variante}` : 'chat-event';
    linha.setAttribute('role', 'status');

    const texto = document.createElement('span');
    texto.className = 'chat-event-text';
    texto.textContent = textoDoEvento;
    if (dica) texto.setAttribute('title', dica);

    const hora = document.createElement('span');
    hora.className = 'chat-event-time';
    hora.textContent = horaAgora();

    linha.appendChild(texto);
    linha.appendChild(hora);
    this.chatMessages.appendChild(linha);
    this.rolarParaOFim();
  }

  mostrarAviso(texto) {
    const aviso = document.createElement('div');
    aviso.className = 'chat-aviso';
    aviso.setAttribute('role', 'alert');
    aviso.textContent = texto;
    this.chatMessages.appendChild(aviso);
    this.rolarParaOFim();
  }

  /**
   * Verdadeiro para o eco da própria mensagem do aluno (nunca para o professor).
   * Exposto à parte porque `main.js` precisa do mesmo critério para decidir se marca
   * novidade no botão do chat: mensagem de colega avisa, o próprio eco não.
   */
  isOwnMessage(author, isProf = false) {
    return !isProf && (author === this.getStudentName());
  }

  /**
   * Mensagem no desenho do chat do Meet: sem balão, com nome (ou "Você"), hora e texto.
   * Só nas mensagens do professor os links viram clicáveis: o eco do que o próprio aluno
   * escreveu fica como ele digitou.
   */
  appendMessage(author, text, isProf = false) {
    const isOwn = this.isOwnMessage(author, isProf);
    const mensagem = document.createElement('div');
    mensagem.className = `msg${isProf ? ' msg-prof' : ''}${isOwn ? ' msg-own' : ''}`;

    const cabeca = document.createElement('div');
    cabeca.className = 'msg-cabeca';

    const autor = document.createElement('span');
    autor.className = 'msg-autor';
    // O servidor já manda "Professor" como remetente; prefixar "Prof." dava "Prof. Professor".
    autor.textContent = isOwn ? 'Você' : author;

    const hora = document.createElement('span');
    hora.className = 'msg-hora';
    hora.textContent = horaAgora();

    cabeca.appendChild(autor);
    cabeca.appendChild(hora);

    const texto = document.createElement('div');
    texto.className = 'msg-texto';
    if (isProf) {
      escreverComLinks(texto, text);
    } else {
      texto.textContent = text;
    }

    mensagem.appendChild(cabeca);
    mensagem.appendChild(texto);
    this.chatMessages.appendChild(mensagem);
    this.rolarParaOFim();
  }

  /**
   * Mensagem fixada pelo professor no topo do chat (link do portal, recado da aula).
   * `null` ou texto vazio desafixa. Devolve se passou a haver uma fixada diferente da
   * anterior, para quem chama decidir se é novidade.
   */
  fixar(textoRecebido) {
    const texto = typeof textoRecebido === 'string' && textoRecebido.trim() ? textoRecebido : null;
    const novidade = texto !== null && texto !== this.textoFixado;
    this.textoFixado = texto;
    if (!this.fixada || !this.fixadaTexto) return novidade;

    if (texto === null) {
      this.fixada.hidden = true;
      return false;
    }

    escreverComLinks(this.fixadaTexto, texto);
    this.fixada.hidden = false;
    this.definirFixadaInteira(false);
    return novidade;
  }

  alternarFixadaInteira() {
    this.definirFixadaInteira(!this.fixada.classList.contains('expandida'));
  }

  definirFixadaInteira(inteira) {
    if (!this.fixada) return;
    if (inteira) {
      this.fixada.classList.add('expandida');
    } else {
      this.fixada.classList.remove('expandida');
    }
    if (this.fixadaMais) {
      this.fixadaMais.textContent = inteira ? 'Ver menos' : 'Ver mais';
      this.fixadaMais.setAttribute('aria-expanded', String(inteira));
    }
    this.atualizarVerMais();
  }

  /** "Ver mais" só aparece quando o texto passa de 3 linhas (ou está aberto por inteiro). */
  atualizarVerMais() {
    if (!this.fixada || !this.fixadaTexto || !this.fixadaMais) return;
    if (this.fixada.hidden) return;
    const inteira = this.fixada.classList.contains('expandida');
    // Com o painel fechado o texto não tem altura e não dá para medir; a medida volta
    // pelo ResizeObserver quando o painel abrir.
    if (!inteira && !this.fixadaTexto.clientHeight) return;
    const cortado = this.fixadaTexto.scrollHeight > this.fixadaTexto.clientHeight + 1;
    this.fixadaMais.hidden = !(inteira || cortado);
  }

  rolarParaOFim() {
    this.chatMessages.scrollTop = this.chatMessages.scrollHeight;
  }
}
