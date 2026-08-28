export function erroDoNome(bruto) {
  const texto = String(bruto || '').trim();
  if (!texto) return 'Informe seu nome.';
  if (texto.length < 2) return 'Nome muito curto.';
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
