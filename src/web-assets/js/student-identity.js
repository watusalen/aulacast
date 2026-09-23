/** Mesmo teto do servidor (WebSocketHandlerService.maxNameLength). */
export const TAMANHO_MAXIMO_NOME = 40;

/**
 * Conta caracteres como o servidor conta (Swift conta letras visíveis, não unidades
 * UTF-16). Com `length` um nome de um emoji só, ou um "é" decomposto, passava aqui e
 * era recusado lá.
 */
export function contarCaracteres(texto) {
  if (typeof Intl !== 'undefined' && Intl.Segmenter) {
    return [...new Intl.Segmenter('pt-BR', { granularity: 'grapheme' }).segment(texto)].length;
  }
  return [...texto].length;
}

export function erroDoNome(bruto) {
  const texto = String(bruto || '').trim();
  if (!texto) return 'Informe seu nome.';
  const tamanho = contarCaracteres(texto);
  if (tamanho < 2) return 'Nome muito curto.';
  if (tamanho > TAMANHO_MAXIMO_NOME) return `Use no máximo ${TAMANHO_MAXIMO_NOME} caracteres.`;
  return null;
}

export function normalizarNome(bruto) {
  return String(bruto || '').trim().replace(/\s+/g, ' ');
}

const CHAVE_ARMAZENAMENTO = 'aulacast.identidade';

/** Guarda a identidade na sessão para que recarregar a página não peça tudo de novo. */
export function salvarIdentidade(identidade) {
  try {
    sessionStorage.setItem(CHAVE_ARMAZENAMENTO, JSON.stringify({ name: identidade.name }));
  } catch (_) {
    // Modo privado ou armazenamento cheio: seguir sem persistir não quebra a aula.
  }
}

/** Esquece a identidade salva (o servidor recusou o nome). */
export function esquecerIdentidade() {
  try {
    sessionStorage.removeItem(CHAVE_ARMAZENAMENTO);
  } catch (_) {
    // Sem armazenamento não há o que esquecer.
  }
}

export function carregarIdentidade() {
  try {
    const bruto = sessionStorage.getItem(CHAVE_ARMAZENAMENTO);
    if (!bruto) return null;
    const dados = JSON.parse(bruto);
    if (!dados || erroDoNome(dados.name)) return null;
    return { name: normalizarNome(dados.name) };
  } catch (_) {
    return null;
  }
}
