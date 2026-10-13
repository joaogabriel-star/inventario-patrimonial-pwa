-- Inventário Patrimonial — migração 006. Rode no SQL Editor DEPOIS da 001 e 002. É idempotente.
--
-- Lista de CONSULTA com as unidades (coordenações) e seus responsáveis, usada para preencher o formulário de CRIAÇÃO de sala:
-- ao digitar a coordenação (a SIGLA), o app preenche UORG, responsável e SIORG. CPF e matrícula só chegam ao aparelho do
-- ADMINISTRADOR; para os demais usuários a função devolve esses dois campos vazios.
-- Nunca coloque estes dados em arquivo do projeto nem no Git: a carga é feita pelo painel (CSV).
-- Carga: Table Editor -> unidades_responsaveis -> Insert -> Import data from CSV
--   colunas: sigla, uorg, denominacao, codigo_siorg, responsavel, matricula, cpf  (CPF e matrícula como TEXTO, com zeros)
-- Apagar tudo: truncate table public.unidades_responsaveis;

create table if not exists public.unidades_responsaveis (
  sigla text primary key,
  uorg text not null default '',
  denominacao text not null default '',
  codigo_siorg text not null default '',
  responsavel text not null default '',
  matricula text not null default '',
  cpf text not null default ''
);

-- RLS ligado e sem nenhuma policy: ninguém lê direto; o app usa a função abaixo; a carga do CSV é feita pelo painel
alter table public.unidades_responsaveis enable row level security;
revoke all on public.unidades_responsaveis from anon, authenticated;

create or replace function public.listar_unidades_responsaveis() returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
declare v_admin boolean;
begin
  if auth.uid() is null or not public.eh_ativo() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  v_admin := public.eh_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'sigla', u.sigla, 'uorg', u.uorg, 'denominacao', u.denominacao, 'siorg', u.codigo_siorg, 'responsavel', u.responsavel,
      'matricula', case when v_admin then u.matricula else '' end,
      'cpf', case when v_admin then u.cpf else '' end) order by u.sigla)
    from public.unidades_responsaveis u), '[]'::jsonb);
end
$fn$;

revoke all on function public.listar_unidades_responsaveis() from public, anon;
grant execute on function public.listar_unidades_responsaveis() to authenticated;
