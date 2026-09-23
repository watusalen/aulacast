/**
 * Tamanho legível em português ("1,5 MB"), na mesma conta do macOS (1 MB = 1.000.000
 * bytes): o professor e a turma veem o mesmo número para o mesmo arquivo.
 */
export function formatarTamanho(bytes) {
  const n = Number(bytes) || 0;
  if (n < 1000) return `${n} B`;
  const unidades = ['KB', 'MB', 'GB', 'TB'];
  let valor = n / 1000;
  let i = 0;
  while (valor >= 1000 && i < unidades.length - 1) {
    valor /= 1000;
    i += 1;
  }
  const casas = valor < 10 ? 1 : 0;
  const texto = valor.toFixed(casas).replace(/\.0$/, '').replace('.', ',');
  return `${texto} ${unidades[i]}`;
}

/** Um ícone do Material Symbols (só visual: o leitor de tela lê o nome do arquivo). */
function icone(nome, codigo) {
  const el = document.createElement('span');
  el.className = nome ? `icone ${nome}` : 'icone';
  el.setAttribute('aria-hidden', 'true');
  el.textContent = String.fromCodePoint(codigo);
  return el;
}

/**
 * Lista de arquivos que o professor compartilhou, no desenho de lista do Material: ícone
 * num quadrado tonal, nome e tamanho. O item inteiro é o link de download: é o único
 * jeito de baixar, e um alvo grande é mais fácil de acertar no celular.
 *
 * O nome do arquivo vem do Mac do professor e vai para a tela só como texto — nunca
 * como HTML —, então um nome esquisito não vira código na página do aluno.
 */
export class FilesList {
  constructor({ onNovidade } = {}) {
    this.list = document.getElementById('filesList');
    this.vazio = document.getElementById('filesEmpty');
    this.onNovidade = onNovidade || (() => {});
    this.idsConhecidos = null;
    /** Arquivos que chegaram durante a aula e o aluno ainda não baixou. */
    this.naoBaixados = new Set();
  }

  render(arquivos) {
    const lista = Array.isArray(arquivos) ? arquivos : [];

    // Só é novidade o que chega com a aula em andamento: a primeira lista (ao entrar
    // ou reconectar) não é novidade para ninguém.
    const ids = new Set(lista.map((a) => a.id));
    let novos = [];
    if (this.idsConhecidos) {
      novos = lista.filter((a) => !this.idsConhecidos.has(a.id));
      for (const a of novos) this.naoBaixados.add(a.id);
    }
    this.list.hidden = lista.length === 0;
    if (this.vazio) this.vazio.hidden = lista.length > 0;

    while (this.list.firstChild) this.list.removeChild(this.list.firstChild);

    for (const arquivo of lista) {
      const item = document.createElement('li');
      item.className = 'file-item';

      const link = document.createElement('a');
      link.className = 'file-link';
      link.href = `/arquivos/${encodeURIComponent(arquivo.id)}`;
      link.setAttribute('download', arquivo.name);
      link.addEventListener('click', () => this.marcarComoBaixado(arquivo.id, item));

      const quadrado = document.createElement('span');
      quadrado.className = 'file-icone';
      quadrado.appendChild(icone('', 0xE873));

      const texto = document.createElement('span');
      texto.className = 'file-texto';

      const nome = document.createElement('span');
      nome.className = 'file-name';
      nome.textContent = arquivo.name;
      nome.setAttribute('title', arquivo.name);

      const tamanho = document.createElement('span');
      tamanho.className = 'file-size';
      tamanho.textContent = formatarTamanho(arquivo.size);

      texto.appendChild(nome);
      texto.appendChild(tamanho);
      link.appendChild(quadrado);
      link.appendChild(texto);
      if (this.naoBaixados.has(arquivo.id)) {
        const etiqueta = document.createElement('span');
        etiqueta.className = 'file-new';
        etiqueta.textContent = 'Novo';
        link.appendChild(etiqueta);
      }
      link.appendChild(icone('file-baixar', 0xF090));
      item.appendChild(link);
      this.list.appendChild(item);
    }

    if (novos.length > 0) this.onNovidade(novos);
    this.idsConhecidos = ids;
    for (const id of this.naoBaixados) {
      if (!ids.has(id)) this.naoBaixados.delete(id);
    }
  }

  /** A etiqueta "Novo" sai quando o aluno baixa o arquivo: cumpriu o papel dela. */
  marcarComoBaixado(id, item) {
    this.naoBaixados.delete(id);
    const etiqueta = item.querySelector ? item.querySelector('.file-new') : null;
    if (etiqueta && etiqueta.parentNode) etiqueta.parentNode.removeChild(etiqueta);
  }
}
