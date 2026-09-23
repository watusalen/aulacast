import { erroDoNome, normalizarNome, salvarIdentidade, carregarIdentidade, esquecerIdentidade } from './student-identity.js';

/**
 * Tela de entrada: o aluno diz o nome antes de ver a aula, para o professor saber quem
 * está assistindo. A validação também roda no servidor — aqui é para dar retorno imediato,
 * não é barreira.
 */
export class EntryGate {
  constructor({ onIdentified }) {
    this.onIdentified = onIdentified;

    this.gate = document.getElementById('entryGate');
    this.form = document.getElementById('entryForm');
    this.nameInput = document.getElementById('entryName');
    this.errorBox = document.getElementById('entryError');
    this.submitBtn = document.getElementById('entrySubmit');

    this.form.addEventListener('submit', (e) => this.handleSubmit(e));
    this.nameInput.addEventListener('input', () => this.limparErro());
  }

  /** Se o aluno já se identificou nesta sessão, não pede de novo ao recarregar. */
  tentarEntrarComIdentidadeSalva() {
    const salva = carregarIdentidade();
    if (!salva) return false;
    // Entrou sozinho, sem toque: quem chama sabe que não há gesto do usuário agora (o
    // que importa para manter a tela acesa, que o navegador só libera num gesto).
    this.concluir(salva, { porGesto: false });
    return true;
  }

  handleSubmit(evento) {
    evento.preventDefault();

    const nome = normalizarNome(this.nameInput.value);

    const problemaNome = erroDoNome(nome);
    if (problemaNome) {
      this.mostrarErro(problemaNome, this.nameInput);
      return;
    }

    // Dentro do envio do formulário: é um gesto do usuário.
    this.concluir({ name: nome }, { porGesto: true });
  }

  concluir(identidade, { porGesto = false } = {}) {
    salvarIdentidade(identidade);
    this.submitBtn.disabled = true;
    this.submitBtn.textContent = 'Entrando…';
    this.gate.hidden = true;
    this.onIdentified(identidade, { porGesto });
  }

  /** O servidor recusou (cliente adulterado ou nome vazio): traz a portaria de volta. */
  reabrirComErro(mensagem) {
    // Sem isto o nome recusado continuava salvo: cada recarga entrava sozinha com ele
    // e era barrada de novo, sem o aluno conseguir corrigir.
    esquecerIdentidade();
    this.gate.hidden = false;
    this.submitBtn.disabled = false;
    this.submitBtn.textContent = 'Entrar na aula';
    this.mostrarErro(mensagem || 'Não foi possível confirmar sua entrada.', this.nameInput);
  }

  mostrarErro(mensagem, campo) {
    this.errorBox.textContent = mensagem;
    this.errorBox.hidden = false;
    if (campo) {
      campo.classList.add('invalid');
      campo.focus();
    }
  }

  limparErro() {
    this.errorBox.hidden = true;
    this.nameInput.classList.remove('invalid');
  }
}
