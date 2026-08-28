#!/bin/bash
#
# Gera o AulaCast.dmg — a imagem de disco que se entrega a outro professor.
#
# O .dmg é só uma embalagem: monta o AulaCast.app com o build-app.sh e o coloca numa imagem
# junto de um atalho para /Applications, que é o gesto que todo mundo já conhece (arrastar o
# ícone para a pasta). Nada aqui muda o aplicativo em si.
#
# ATENÇÃO À ASSINATURA: o aplicativo é assinado de forma ad-hoc, não com Developer ID nem
# notarizado (as duas coisas exigem conta paga da Apple). Isso não impede o uso, mas muda o
# que o outro professor vê ao abrir — e o roteiro para contornar está impresso ao final da
# execução e documentado no README.
#
# Uso:  ./scripts/gerar-dmg.sh [pasta-de-saida]
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAIDA="${1:-$RAIZ/build}"
APP="$SAIDA/AulaCast.app"

echo "==> Montando o aplicativo"
"$RAIZ/scripts/build-app.sh" "$SAIDA" >/dev/null

if [ ! -d "$APP" ]; then
  echo "erro: $APP não foi gerado" >&2
  exit 1
fi

# A versão vem do Info.plist recém-escrito, e não de uma cópia aqui: dois lugares guardando
# o mesmo número acabam discordando, e aí o nome do arquivo mente sobre o que há dentro.
VERSAO="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$SAIDA/AulaCast-$VERSAO.dmg"

echo "==> Preparando o conteúdo da imagem"
# Pasta temporária com exatamente o que deve aparecer ao abrir o .dmg. Montar a imagem a
# partir da pasta de build inteira levaria junto o .icns e builds antigos.
PALCO="$(mktemp -d)"
trap 'rm -rf "$PALCO"' EXIT

# `ditto` preserva a estrutura do bundle e os atributos estendidos; um `cp -R` pode
# corromper a assinatura do aplicativo pelo caminho.
ditto "$APP" "$PALCO/AulaCast.app"
ln -s /Applications "$PALCO/Applications"

echo "==> Gerando a imagem de disco"
rm -f "$DMG"
hdiutil create \
  -volname "AulaCast" \
  -srcfolder "$PALCO" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

TAMANHO="$(du -h "$DMG" | cut -f1 | tr -d ' ')"

echo
echo "Pronto: $DMG  ($TAMANHO)"
echo
echo "Como entregar a outro professor:"
echo "  1. Mande o .dmg (pendrive, AirDrop, rede da escola)."
echo "  2. Ele abre o .dmg e arrasta o AulaCast para a pasta Aplicativos."
echo
echo "IMPORTANTE — o app não é notarizado pela Apple. Ao abrir pela primeira vez,"
echo "o macOS vai recusar dizendo que o aplicativo 'está danificado' ou que vem de"
echo "um desenvolvedor não identificado. Isso é o Gatekeeper, não é defeito do app."
echo "Para liberar, o professor roda uma vez no Terminal:"
echo
echo "    xattr -dr com.apple.quarantine /Applications/AulaCast.app"
echo
echo "Depois disso ele abre normalmente, e é só autorizar a Gravação de Tela em"
echo "Ajustes do Sistema > Privacidade e Segurança."
