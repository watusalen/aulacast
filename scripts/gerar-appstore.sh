#!/bin/bash
#
# Gera o AulaCast para a Mac App Store (App Sandbox) ou um app de teste do sandbox.
#
# Uso:
#   AULACAST_SANDBOX_TESTE=1 ./scripts/gerar-appstore.sh [pasta-de-saida]
#       App assinado ad-hoc COM os entitlements (o sandbox vale também localmente). Não precisa
#       de conta Apple. Serve para você testar o comportamento sandbox no seu Mac.
#
#   AULACAST_BUNDLE_ID=... AULACAST_PROVISIONING_PROFILE=... AULACAST_APP_IDENTITY=... \
#   AULACAST_INSTALLER_IDENTITY=... ./scripts/gerar-appstore.sh [pasta-de-saida]
#       Gera AulaCast.app assinado e AulaCast-<versão>.pkg para o titular da conta enviar.
#
# Nenhum segredo fica no repositório: tudo vem de variáveis de ambiente.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAIDA="${1:-$RAIZ/build/appstore}"
SAIDA="$(mkdir -p "$SAIDA" && cd "$SAIDA" && pwd)"
ENTITLEMENTS="$RAIZ/scripts/AulaCast.entitlements"
APP="$SAIDA/AulaCast.app"

falta() { echo "erro: $1" >&2; exit 1; }

# Build de depuração nunca vai para a loja.
[ "${AULACAST_DEBUG_METRICS:-}" = "1" ] && falta "AULACAST_DEBUG_METRICS=1 está ligado: build de depuração não pode ir para a App Store. Desligue a variável."
[ -f "$ENTITLEMENTS" ] || falta "arquivo não encontrado: $ENTITLEMENTS"
plutil -lint "$ENTITLEMENTS" >/dev/null || falta "entitlements inválido: $ENTITLEMENTS"

if [ "${AULACAST_SANDBOX_TESTE:-}" = "1" ]; then
  echo "==> Modo teste do sandbox (ad-hoc, com entitlements)"
  AULACAST_SANDBOX_TESTE=1 "$RAIZ/scripts/build-app.sh" "$SAIDA"
  echo
  echo "==> Entitlements embutidos:"
  codesign -d --entitlements :- "$APP" 2>/dev/null
  echo
  echo "Abra com:  open \"$APP\""
  echo "Os dados ficam em ~/Library/Containers/${AULACAST_BUNDLE_ID:-com.aulacast}/Data/Documents/AulaCast"
  echo "(ou use o menu Arquivo > Mostrar pasta de dados no Finder)."
  exit 0
fi

# Modo loja: confere tudo ANTES de compilar (a compilação demora).
[ -n "${AULACAST_BUNDLE_ID:-}" ] || falta "defina AULACAST_BUNDLE_ID com o identificador do App ID registrado pelo titular da conta (ex.: br.edu.ifpi.aulacast)."
[ -n "${AULACAST_PROVISIONING_PROFILE:-}" ] || falta "defina AULACAST_PROVISIONING_PROFILE com o caminho do perfil .provisionprofile (Mac App Store)."
[ -f "$AULACAST_PROVISIONING_PROFILE" ] || falta "perfil não encontrado: $AULACAST_PROVISIONING_PROFILE"
[ -n "${AULACAST_APP_IDENTITY:-}" ] || falta "defina AULACAST_APP_IDENTITY com a identidade 'Apple Distribution: Nome (TEAMID)' ou '3rd Party Mac Developer Application: ...'."
[ -n "${AULACAST_INSTALLER_IDENTITY:-}" ] || falta "defina AULACAST_INSTALLER_IDENTITY com a identidade 'Mac Installer Distribution: Nome (TEAMID)' (ou '3rd Party Mac Developer Installer: ...')."
security find-identity -v -p codesigning | grep -qF "$AULACAST_APP_IDENTITY" \
  || falta "identidade de aplicativo '$AULACAST_APP_IDENTITY' não está no chaveiro (security find-identity -v -p codesigning)."
security find-identity -v | grep -qF "$AULACAST_INSTALLER_IDENTITY" \
  || falta "identidade de instalador '$AULACAST_INSTALLER_IDENTITY' não está no chaveiro (security find-identity -v)."

echo "==> Montando o app (universal, release, sem flags de depuração)"
AULACAST_APPSTORE=1 "$RAIZ/scripts/build-app.sh" "$SAIDA"

# Sem binário universal o upload é aceito, mas o app não abriria em Macs da outra arquitetura.
ARQS="$(lipo -archs "$APP/Contents/MacOS/AulaCast")"
case "$ARQS" in *arm64*x86_64*|*x86_64*arm64*) ;; *) falta "binário não é universal (só: $ARQS). A segunda arquitetura não compilou." ;; esac

echo "==> Embutindo o perfil de provisionamento"
cp "$AULACAST_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"

echo "==> Assinando com '$AULACAST_APP_IDENTITY'"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$AULACAST_APP_IDENTITY" "$APP"

VERSAO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
PKG="$SAIDA/AulaCast-$VERSAO.pkg"
echo "==> Gerando o instalador $PKG"
rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$AULACAST_INSTALLER_IDENTITY" "$PKG"

cat <<EOF

Pronto:
  app:  $APP
  pkg:  $PKG

Verificar:
  codesign --verify --deep --strict --verbose=2 "$APP"
  codesign -d --entitlements :- "$APP"
  pkgutil --check-signature "$PKG"

Enviar (titular da conta ou membro com papel de App Manager):
  Abra o app Transporter (Mac App Store), entre com o Apple ID, arraste "$PKG" e clique em Entregar.
  Depois, no App Store Connect, escolha o build e envie para revisão.
EOF
