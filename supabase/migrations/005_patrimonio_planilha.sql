-- Inventário Patrimonial — migração 005. Rode no SQL Editor DEPOIS da 001 e 002 (a 003 e a 004 não são pré-requisito). É idempotente.
--
-- Lista de CONSULTA com os números de patrimônio que já constam na planilha de levantamento (tipo, marca, coordenação e
-- local). NÃO é um cadastro de bens: não cria bem, não cria duplicidade e não depende de sala. O app baixa a lista e, ao
-- ler ou digitar um número que consta nela, preenche o tipo e a marca e avisa "consta na planilha".
-- Para carregar os dados: Table Editor -> patrimonio_planilha -> Insert -> Import data from CSV
-- (colunas: numero, tipo, marca, coordenacao, andar, localidade). Para apagar tudo depois: truncate table public.patrimonio_planilha;

create table if not exists public.patrimonio_planilha (
  numero text primary key,
  tipo text not null default '',
  marca text not null default '',
  coordenacao text not null default '',
  andar text not null default '',
  localidade text not null default '',
  criado_em timestamptz not null default now()
);

-- RLS ligado e sem nenhuma policy: o app só lê pela função abaixo; a carga do CSV é feita pelo painel (papel postgres)
alter table public.patrimonio_planilha enable row level security;
revoke all on public.patrimonio_planilha from anon, authenticated;

create or replace function public.listar_patrimonio_planilha() returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
begin
  if auth.uid() is null or not public.eh_ativo() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('numero', p.numero, 'tipo', p.tipo, 'marca', p.marca,
                                        'coordenacao', p.coordenacao, 'andar', p.andar, 'localidade', p.localidade)
                     order by p.numero)
    from public.patrimonio_planilha p), '[]'::jsonb);
end
$fn$;

revoke all on function public.listar_patrimonio_planilha() from public, anon;
grant execute on function public.listar_patrimonio_planilha() to authenticated;
