#!/bin/bash
#
# Monta o AulaCast.app a partir do executável do Swift Package Manager.
#
# Por que empacotar em vez de usar `swift run`:
#   - A permissão de Gravação de Tela do macOS é concedida ao aplicativo. Um binário solto
#     em .build/ tem caminho instável, e a permissão se perde a cada recompilação.
#   - Só um aplicativo empacotado tem Info.plist, e é lá que ficam as autorizações de rede
#     local e Bonjour exigidas pelo macOS recente.
#   - Com um identificador de bundle definido, o app deixa de listar a própria janela entre
#     as fontes de captura.
#
# Uso:  ./scripts/build-app.sh [pasta-de-saida]
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAIDA="${1:-$RAIZ/build}"
APP="$SAIDA/AulaCast.app"

IDENTIFICADOR="com.aulacast"
VERSAO="1.0.0"
MACOS_MINIMO="13.0"

echo "==> Compilando em modo release"
cd "$RAIZ/src"
swift build -c release
BINARIO="$(swift build -c release --show-bin-path)/AulaCast"

if [ ! -x "$BINARIO" ]; then
  echo "erro: executável não encontrado em $BINARIO" >&2
  exit 1
fi

# Segunda arquitetura, para o aplicativo rodar também em Mac Intel.
#
# `swift build` sozinho gera só a arquitetura da máquina que compilou. Um .dmg feito num
# Mac Apple Silicon simplesmente não abria num Intel — e é justamente numa sala de aula que
# se encontram máquinas dos dois tipos. O `--arch` duplo do SwiftPM exige o Xcode completo
# (xcbuild); compilar cada fatia com `--triple` e juntar com `lipo` funciona só com as
# Ferramentas de Linha de Comando, que é o que a maioria tem instalado.
#
# Se a segunda fatia não compilar, o aplicativo sai com a arquitetura local e o aviso fica
# impresso: melhor entregar algo que roda aqui do que falhar a geração inteira.
ARQUITETURA_LOCAL="$(uname -m)"
if [ "$ARQUITETURA_LOCAL" = "arm64" ]; then
  TRIPLA_OUTRA="x86_64-apple-macosx$MACOS_MINIMO"
else
  TRIPLA_OUTRA="arm64-apple-macosx$MACOS_MINIMO"
fi

echo "==> Compilando a outra arquitetura ($TRIPLA_OUTRA)"
# Pasta de build separada: alternar de tripla dentro do mesmo .build faz o SwiftPM
# reaproveitar a base de build da arquitetura anterior e falhar com
# "command ... not registered".
CRUZADO="$RAIZ/src/.build-cruzado"
UNIVERSAL=""
if swift build -c release --triple "$TRIPLA_OUTRA" --scratch-path "$CRUZADO" >/dev/null 2>&1; then
  OUTRO_BINARIO="$(swift build -c release --triple "$TRIPLA_OUTRA" --scratch-path "$CRUZADO" --show-bin-path)/AulaCast"
  if [ -x "$OUTRO_BINARIO" ]; then
    UNIVERSAL="$SAIDA/AulaCast-universal"
    mkdir -p "$SAIDA"
    lipo -create "$BINARIO" "$OUTRO_BINARIO" -output "$UNIVERSAL"
  fi
fi

echo "==> Montando a estrutura do aplicativo"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ -n "$UNIVERSAL" ] && [ -x "$UNIVERSAL" ]; then
  cp "$UNIVERSAL" "$APP/Contents/MacOS/AulaCast"
  rm -f "$UNIVERSAL"
  echo "    binário universal: $(lipo -archs "$APP/Contents/MacOS/AulaCast")"
else
  cp "$BINARIO" "$APP/Contents/MacOS/AulaCast"
  echo "    AVISO: só $ARQUITETURA_LOCAL — este aplicativo não abrirá em Macs da outra arquitetura."
fi

# O cliente web precisa viajar junto: o WebAssetsPathResolver procura em
# Bundle.main.resourceURL quando o app roda instalado.
# Os testes do cliente ficam de fora — não têm utilidade para quem só usa o aplicativo.
mkdir -p "$APP/Contents/Resources/web-assets"
(cd "$RAIZ/src/web-assets" && \
  find . -type f -not -path "./tests/*" -not -name ".DS_Store" \
    -exec ditto "{}" "$APP/Contents/Resources/web-assets/{}" \;)

echo "==> Gerando o ícone"
ICONE="$SAIDA/AppIcon.icns"
swift "$RAIZ/scripts/gerar-icone.swift" "$ICONE" >/dev/null
cp "$ICONE" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Escrevendo o Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>AulaCast</string>
    <key>CFBundleDisplayName</key>     <string>AulaCast</string>
    <key>CFBundleExecutable</key>      <string>AulaCast</string>
    <key>CFBundleIdentifier</key>      <string>$IDENTIFICADOR</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSAO</string>
    <key>CFBundleVersion</key>         <string>$VERSAO</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>$MACOS_MINIMO</string>
    <key>NSHighResolutionCapable</key> <true/>

    <!-- Exigido pelo macOS recente para servir na rede local da sala. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>O AulaCast transmite a tela do professor para os computadores dos alunos na rede local da sala. Nada sai para a internet.</string>

    <!-- Necessário para anunciar a sala por Bonjour, sem exigir que a turma saiba o IP. -->
    <key>NSBonjourServices</key>
    <array>
        <string>_aulacast._tcp</string>
    </array>
</dict>
</plist>
PLIST

echo "==> Assinando"
# A assinatura decide se a permissão de Gravação de Tela sobrevive a uma recompilação.
#
# Sem certificado, a assinatura é ad-hoc e o macOS identifica o aplicativo pelo hash exato
# do binário (`designated => cdhash H"..."`). Qualquer mudança no código gera um hash novo,
# o sistema deixa de reconhecer o app e a autorização precisa ser dada outra vez — é o que
# faz o pedido de permissão reaparecer a cada build.
#
# Com um certificado de assinatura de código no chaveiro (mesmo criado por você, sem conta
# da Apple), a identidade passa a ser o certificado e o identificador do bundle, que não
# mudam entre builds. Aí a permissão é concedida uma vez e continua valendo.
# O README explica como criar o certificado.
IDENTIDADE="${AULACAST_CODESIGN_ID:-AulaCast Local}"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTIDADE"; then
  codesign --force --deep --sign "$IDENTIDADE" "$APP" >/dev/null 2>&1
  echo "    assinado com \"$IDENTIDADE\" (a permissão sobrevive a recompilações)"
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1
  echo "    assinatura ad-hoc — o macOS vai pedir a permissão de Gravação de Tela"
  echo "    de novo a cada recompilação. Veja o README para resolver de vez."
fi

echo
echo "Pronto: $APP"
echo
echo "Para instalar:   cp -R \"$APP\" /Applications/"
echo "Na primeira execução, autorize em Ajustes do Sistema >"
echo "Privacidade e Segurança > Gravação de Tela."
