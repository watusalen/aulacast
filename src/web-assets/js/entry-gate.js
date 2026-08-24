import { erroDaMatricula, erroDoNome, normalizarMatricula, salvarIdentidade, carregarIdentidade } from './student-identity.js';

/**
 * Tela de entrada: o aluno só passa para a aula depois de informar nome e matrícula.
 * A validação também roda no servidor — aqui é para dar retorno imediato, não é barreira.
 */
export class EntryGate {
  constructor({ onIdentified }) {
    this.onIdentified = onIdentified;

    this.gate = document.getElementById('entryGate');
    this.form = document.getElementById('entryForm');
    this.nameInput = document.getElementById('entryName');
    this.matriculaInput = document.getElementById('entryMatricula');
    this.errorBox = document.getElementById('entryError');
    this.submitBtn = document.getElementById('entrySubmit');

    this.form.addEventListener('submit', (e) => this.handleSubmit(e));

    // Matrícula é sempre maiúscula; deixar o navegador mostrar minúscula confunde
    // na hora de conferir com a carteirinha.
    this.matriculaInput.addEventListener('input', () => {
      const pos = this.matriculaInput.selectionStart;
      this.matriculaInput.value = this.matriculaInput.value.toUpperCase();
      this.matriculaInput.setSelectionRange(pos, pos);
      this.limparErro();
    });
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

    const nome = this.nameInput.value.trim();
    const matricula = normalizarMatricula(this.matriculaInput.value);

    const problemaNome = erroDoNome(nome);
    if (problemaNome) {
      this.mostrarErro(problemaNome, this.nameInput);
      return;
    }

    const problemaMatricula = erroDaMatricula(matricula);
    if (problemaMatricula) {
      this.mostrarErro(problemaMatricula, this.matriculaInput);
      return;
    }

    this.concluir({ name: nome, matricula });
  }

  concluir(identidade) {
    salvarIdentidade(identidade);
    this.submitBtn.disabled = true;
    this.submitBtn.textContent = 'Entrando…';
    this.gate.hidden = true;
    this.onIdentified(identidade);
  }

  /** O servidor recusou (cliente adulterado ou fora de formato): traz a portaria de volta. */
  reabrirComErro(mensagem) {
    this.gate.hidden = false;
    this.submitBtn.disabled = false;
    this.submitBtn.textContent = 'Entrar na aula';
    this.mostrarErro(mensagem || 'Não foi possível confirmar sua matrícula.', this.matriculaInput);
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
    this.matriculaInput.classList.remove('invalid');
  }
}
