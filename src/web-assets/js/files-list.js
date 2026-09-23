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

/**
 * Lista de arquivos que o professor compartilhou.
 *
 * O nome do arquivo vem do Mac do professor e vai para a tela só como texto — nunca
 * como HTML —, então um nome esquisito não vira código na página do aluno.
 */
export class FilesList {
  constructor({ onNovidade } = {}) {
    this.section = document.getElementById('filesSection');
    this.list = document.getElementById('filesList');
    this.onNovidade = onNovidade || (() => {});
    this.idsConhecidos = null;
  }

  render(arquivos) {
    const lista = Array.isArray(arquivos) ? arquivos : [];
    this.section.hidden = lista.length === 0;

    while (this.list.firstChild) this.list.removeChild(this.list.firstChild);

    for (const arquivo of lista) {
      const item = document.createElement('li');
      item.className = 'file-item';

      const link = document.createElement('a');
      link.className = 'file-link';
      link.href = `/arquivos/${encodeURIComponent(arquivo.id)}`;
      link.setAttribute('download', arquivo.name);

      const nome = document.createElement('span');
      nome.className = 'file-name';
      nome.textContent = arquivo.name;

      const tamanho = document.createElement('span');
      tamanho.className = 'file-size';
      tamanho.textContent = formatarTamanho(arquivo.size);

      link.appendChild(nome);
      link.appendChild(tamanho);
      item.appendChild(link);
      this.list.appendChild(item);
    }

    // Avisa só do que é novo de verdade: a primeira lista (ao entrar na aula ou
    // reconectar) não é novidade para ninguém.
    const ids = new Set(lista.map((a) => a.id));
    if (this.idsConhecidos) {
      const novos = lista.filter((a) => !this.idsConhecidos.has(a.id));
      if (novos.length > 0) this.onNovidade(novos);
    }
    this.idsConhecidos = ids;
  }
}
