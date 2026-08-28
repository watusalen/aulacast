import { erroDoNome, normalizarNome, salvarIdentidade, carregarIdentidade } from './student-identity.js';

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
    this.concluir(salva);
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

    this.concluir({ name: nome });
  }

  concluir(identidade) {
    salvarIdentidade(identidade);
    this.submitBtn.disabled = true;
    this.submitBtn.textContent = 'Entrando…';
    this.gate.hidden = true;
    this.onIdentified(identidade);
  }

  /** O servidor recusou (cliente adulterado ou nome vazio): traz a portaria de volta. */
  reabrirComErro(mensagem) {
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
