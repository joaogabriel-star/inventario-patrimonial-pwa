#!/usr/bin/env bash
# Backup do banco do Supabase (schema "public"), criptografado com age. Roda à mão (ou num agendador PRIVADO seu).
# Este repositório NÃO traz workflow de backup: em repositório público, os artefatos do GitHub Actions também são públicos.
# Veja docs/BACKUP.md.
#
# Variáveis (nenhuma é gravada em arquivo; passe-as pelo ambiente, nunca por commit):
#   SUPABASE_DB_URL        obrigatória. String de conexão do **Session Pooler** do Supabase (com a senha do banco).
#   BACKUP_AGE_RECIPIENT   obrigatória. Chave PÚBLICA age (começa com "age1"). A privada fica só com você.
#   BACKUP_SAIDA           pasta de saída (padrão: backup-saida)
#   PG_BIN                 pasta dos binários do PostgreSQL com "/" no fim (ex.: /usr/lib/postgresql/17/bin/); vazio = PATH
#
# Fica FORA do backup (só o conteúdo; a estrutura das tabelas entra): CPF e matrícula (salas_responsavel_pessoal),
# a planilha de unidades/responsáveis (unidades_responsaveis) e as referências de senha (usuarios_seguranca).
# O schema "auth" (e-mails e hashes de senha) não entra.
set -euo pipefail

: "${SUPABASE_DB_URL:?defina SUPABASE_DB_URL (string do Session Pooler do Supabase)}"
: "${BACKUP_AGE_RECIPIENT:?defina BACKUP_AGE_RECIPIENT (chave PÚBLICA age, começa com age1)}"
case "$BACKUP_AGE_RECIPIENT" in
  age1*) ;;
  AGE-SECRET-KEY-*) echo "ERRO: isso é uma chave PRIVADA. Use só a pública (age1...)." >&2; exit 2 ;;
  *) echo "ERRO: BACKUP_AGE_RECIPIENT deve ser uma chave pública age (age1...)." >&2; exit 2 ;;
esac
# testa a chave antes do dump (uma chave "age1..." malformada só falharia depois, deixando contagens sem .age)
command -v age >/dev/null || { echo "ERRO: o programa 'age' não está instalado." >&2; exit 2; }
printf 'x' | age -r "$BACKUP_AGE_RECIPIENT" >/dev/null 2>&1 || { echo "ERRO: BACKUP_AGE_RECIPIENT não é uma chave pública age válida." >&2; exit 2; }

PGBIN="${PG_BIN:-}"
SAIDA="${BACKUP_SAIDA:-backup-saida}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BASE="inventario-$STAMP"

umask 077
mkdir -p "$SAIDA"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT           # o arquivo sem criptografia só existe aqui, e some ao terminar
DUMP="$TMP/$BASE.dump"

echo "pg_dump: $("${PGBIN}pg_dump" --version)"
"${PGBIN}pg_dump" --dbname="$SUPABASE_DB_URL" --format=custom --compress=6 --no-owner --no-privileges \
  --schema=public \
  --exclude-table-data=public.salas_responsavel_pessoal \
  --exclude-table-data=public.unidades_responsaveis \
  --exclude-table-data=public.usuarios_seguranca \
  --file="$DUMP"

# o dump precisa ser legível e conter as tabelas do inventário
TAMANHO="$(wc -c < "$DUMP")"
[ "$TAMANHO" -gt 2048 ] || { echo "ERRO: dump pequeno demais ($TAMANHO bytes)." >&2; exit 3; }
LISTA="$("${PGBIN}pg_restore" --list "$DUMP")"
for t in bens etiquetas salas usuarios auditoria; do
  grep -Eq "TABLE DATA public $t( |$)" <<<"$LISTA" || { echo "ERRO: o dump não tem os dados de public.$t." >&2; exit 3; }
done
if grep -Eq "TABLE DATA public (salas_responsavel_pessoal|unidades_responsaveis|usuarios_seguranca)( |$)" <<<"$LISTA"; then
  echo "ERRO: o dump trouxe dados que deveriam ficar de fora (CPF/matrícula/referência de senha)." >&2; exit 3
fi

# contagens (só números; servem para conferir uma restauração e perceber um banco que encolheu)
CONT="$SAIDA/$BASE.contagens.txt"
{
  echo "backup: $BASE (UTC)"
  echo "pg_dump: $("${PGBIN}pg_dump" --version)"
  "${PGBIN}psql" "$SUPABASE_DB_URL" -X -At -F ' ' -c "
    select 'bens', count(*) from public.bens
    union all select 'etiquetas', count(*) from public.etiquetas
    union all select 'salas', count(*) from public.salas
    union all select 'usuarios', count(*) from public.usuarios
    union all select 'auditoria', count(*) from public.auditoria"
  echo "tamanho_do_dump_bytes $TAMANHO"
  echo "fora do backup (só o conteúdo): salas_responsavel_pessoal, unidades_responsaveis, usuarios_seguranca"
} > "$CONT"

age -r "$BACKUP_AGE_RECIPIENT" -o "$SAIDA/$BASE.dump.age" "$DUMP"
( cd "$SAIDA" && sha256sum "$BASE.dump.age" > "$BASE.dump.age.sha256" )

echo "OK: $SAIDA/$BASE.dump.age ($(wc -c < "$SAIDA/$BASE.dump.age") bytes, criptografado)"
cat "$CONT"
