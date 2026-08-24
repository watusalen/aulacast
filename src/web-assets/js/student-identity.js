/**
 * Matrícula do IFPI no formato 202XXXXTADSXXXX (X = dígito):
 * 202 + 4 dígitos + TADS + 4 dígitos = 15 caracteres.
 */
export const MATRICULA_REGEX = /^202\d{4}TADS\d{4}$/;
export const MATRICULA_TAMANHO = 15;

export function normalizarMatricula(bruta) {
  return String(bruta || '').trim().toUpperCase();
}

export function matriculaValida(bruta) {
  return MATRICULA_REGEX.test(normalizarMatricula(bruta));
}

/**
 * Explica o que está errado, em vez de só recusar — o aluno digita isso com a aula
 * já começando e precisa corrigir rápido.
 */
export function erroDaMatricula(bruta) {
  const texto = normalizarMatricula(bruta);

  if (!texto) return 'Informe sua matrícula.';
  if (texto.length !== MATRICULA_TAMANHO) {
    return `A matrícula tem ${MATRICULA_TAMANHO} caracteres; você digitou ${texto.length}.`;
  }
  if (!texto.startsWith('202')) return 'A matrícula deve começar com 202.';
  if (texto.slice(7, 11) !== 'TADS') return 'A matrícula deve ter TADS na posição 8.';
  if (!/^\d{4}$/.test(texto.slice(3, 7)) || !/^\d{4}$/.test(texto.slice(11, 15))) {
    return 'As posições marcadas com X devem ser números.';
  }
  return matriculaValida(texto) ? null : 'Matrícula fora do formato 202XXXXTADSXXXX.';
}

export function erroDoNome(bruto) {
  const texto = String(bruto || '').trim();
  if (!texto) return 'Informe seu nome.';
  if (texto.length < 2) return 'Nome muito curto.';
  return null;
}

const CHAVE_ARMAZENAMENTO = 'aulacast.identidade';

/** Guarda a identidade na sessão para que recarregar a página não peça tudo de novo. */
export function salvarIdentidade(identidade) {
  try {
    sessionStorage.setItem(CHAVE_ARMAZENAMENTO, JSON.stringify(identidade));
  } catch (_) {
    // Modo privado ou armazenamento cheio: seguir sem persistir não quebra a aula.
  }
}

export function carregarIdentidade() {
  try {
    const bruto = sessionStorage.getItem(CHAVE_ARMAZENAMENTO);
    if (!bruto) return null;
    const dados = JSON.parse(bruto);
    if (!dados || !matriculaValida(dados.matricula) || erroDoNome(dados.name)) return null;
    return { name: String(dados.name).trim(), matricula: normalizarMatricula(dados.matricula) };
  } catch (_) {
    return null;
  }
}
