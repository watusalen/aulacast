/**
 * Links clicáveis nas mensagens do professor (e na fixada).
 *
 * A turma pediu uma área de "materiais e links" porque os links do chat vinham como
 * texto e era preciso copiar e colar. Tornar o link clicável resolve sem criar outra área.
 *
 * Só `http://`, `https://` e `www.` viram link: outros esquemas (`javascript:`, `data:`,
 * `file:`) ficam como texto, porque um link vindo do chat não pode executar nada na
 * página. E o link é montado com `createElement` + `textContent`, nunca com innerHTML:
 * o texto da mensagem nunca vira código.
 */

const PADRAO_DE_LINK = /\b(?:https?:\/\/|www\.)[^\s<>"]+/gi;

/** Pontuação que encerra a frase e não faz parte do link ("veja https://x.com."). */
const PONTUACAO_FINAL = /[.,;:!?'"»”’…]+$/;

/**
 * Tira do fim o que é da frase, não do link. Um `)` final só sai se estiver sobrando:
 * "(veja https://x.com)" perde o parêntese, mas "https://pt.wikipedia.org/wiki/Java_(linguagem)"
 * continua inteiro.
 */
function aparar(candidato) {
  let url = candidato;
  for (;;) {
    const antes = url;
    url = url.replace(PONTUACAO_FINAL, '');
    for (const [abre, fecha] of [['(', ')'], ['[', ']'], ['{', '}']]) {
      if (url.endsWith(fecha) && contar(url, fecha) > contar(url, abre)) {
        url = url.slice(0, -1);
      }
    }
    if (url === antes) return url;
  }
}

function contar(texto, caractere) {
  return texto.split(caractere).length - 1;
}

/**
 * Divide o texto em pedaços de texto puro e de link, na ordem.
 * `{ tipo: 'texto', texto }` ou `{ tipo: 'link', texto, href }`.
 */
export function partirEmLinks(texto) {
  const entrada = String(texto ?? '');
  const pedacos = [];
  let posicao = 0;

  for (const achado of entrada.matchAll(PADRAO_DE_LINK)) {
    const url = aparar(achado[0]);
    // Só o prefixo ("https://", "www.") não é link de nada.
    if (/^(?:https?:\/\/|www\.)$/i.test(url)) continue;

    const inicio = achado.index;
    if (inicio > posicao) pedacos.push({ tipo: 'texto', texto: entrada.slice(posicao, inicio) });
    const href = /^www\./i.test(url) ? `http://${url}` : url;
    pedacos.push({ tipo: 'link', texto: url, href });
    posicao = inicio + url.length;
  }

  if (posicao < entrada.length) pedacos.push({ tipo: 'texto', texto: entrada.slice(posicao) });
  return pedacos;
}

/** Escreve o texto no elemento, com os links como <a> que abrem em outra aba. */
export function escreverComLinks(elemento, texto, doc = document) {
  while (elemento.firstChild) elemento.removeChild(elemento.firstChild);
  for (const pedaco of partirEmLinks(texto)) {
    if (pedaco.tipo === 'texto') {
      elemento.appendChild(doc.createTextNode(pedaco.texto));
      continue;
    }
    const link = doc.createElement('a');
    link.href = pedaco.href;
    link.textContent = pedaco.texto;
    // Nova aba, para o aluno não sair da aula; `noopener` impede a página aberta de
    // mexer nesta, e `noreferrer` não conta a ela o endereço da aula.
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    elemento.appendChild(link);
  }
}
