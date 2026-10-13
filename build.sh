#!/bin/sh
# Build do Vercel (chamado por "sh build.sh" no vercel.json). O buildCommand do Vercel aceita no maximo 256 caracteres.
# 1) confere as variaveis e recusa chave secreta; 2) carimba o SHA do commit em BUILD (sw.js); 3) gera o config.js.
# Nao imprime a chave. Precisa de LF no fim das linhas (veja .gitattributes).
set -u
erro() { echo "ERRO: $1"; exit 1; }

[ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_PUBLISHABLE_KEY:-}" ] || erro 'defina SUPABASE_URL e SUPABASE_PUBLISHABLE_KEY nas variaveis de ambiente do Vercel'
case "$SUPABASE_URL" in https://*) ;; *) erro 'SUPABASE_URL deve comecar com https://' ;; esac
case "$SUPABASE_PUBLISHABLE_KEY" in sb_secret_*) erro 'SUPABASE_PUBLISHABLE_KEY contem uma chave SECRETA (sb_secret_). Use a chave publishable' ;; esac
if echo "$SUPABASE_PUBLISHABLE_KEY" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | grep -q service_role; then
  erro 'a chave parece ser service_role (secreta)'
fi

B="${VERCEL_GIT_COMMIT_SHA:-$(date +%s)}"
sed -i "s/^const BUILD = 'dev';/const BUILD = '$B';/" sw.js
grep -q "^const BUILD = '$B';" sw.js || erro 'nao consegui carimbar o BUILD no sw.js'

printf 'window.APP_CONFIG={SUPABASE_URL:"%s",SUPABASE_PUBLISHABLE_KEY:"%s"};\n' "$SUPABASE_URL" "$SUPABASE_PUBLISHABLE_KEY" > config.js
echo "Build OK (BUILD=$B)"
