-- Inventário Patrimonial — migração 010 (v0.8.0). Rode no SQL Editor DEPOIS da 001, 002 e 007. É idempotente.
-- Rode cada bloco `create ... $fn$ ... $fn$;` separadamente se o editor reclamar de texto cortado.
--
-- NOTA DE NOMES: "siads" (siads_bens, numero_siads, listar_siads_antigas, origem 'siads') é o nome HISTÓRICO do esquema e equivale
-- ao "catálogo legado". Os nomes foram mantidos para não alterar o esquema; na interface e nos documentos o termo é "catálogo legado".
--
-- 1) siads_bens: os bens do catálogo legado (lista de CONSULTA, não são bens do levantamento). Carregue pelo painel (Table Editor ->
--    Insert -> Import data from CSV; veja docs/CONFIGURACAO-SUPABASE.md). Só número do catálogo, plaqueta antiga, item, descrição e
--    Item Material: SEM valor, data ou conta. RLS ligado e sem policies: o app só lê pela função abaixo.
-- 2) listar_siads_antigas(): para qualquer usuário ativo, SÓ os bens com plaqueta antiga (são os únicos que a leitura acha).
-- 3) mover_bem(bem, sala): qualquer usuário ativo move UM bem de sala. Fica em movimentos_admin (o administrador vê e desfaz em
--    "Movimentos recentes") e na auditoria.
-- O número do catálogo de um bem não é gravado pelo celular: ele sai da plaqueta antiga lida (etiquetas x siads_bens).

create table if not exists public.siads_bens (
  numero_siads text primary key,
  plaqueta_antiga text,                               -- 5 dígitos (zeros à esquerda completados); vazio = sem plaqueta antiga
  item text not null default '',
  descricao text not null default '',
  item_material text not null default '',
  antiga_repetida boolean not null default false,     -- a mesma plaqueta antiga em mais de um bem do catálogo: o app só avisa
  criado_em timestamptz not null default now()
);
create index if not exists siads_bens_antiga_ix on public.siads_bens (plaqueta_antiga);
alter table public.siads_bens enable row level security;
revoke all on public.siads_bens from anon, authenticated;

create or replace function public.listar_siads_antigas() returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
begin
  if auth.uid() is null or not public.eh_ativo() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('a', s.plaqueta_antiga, 's', s.numero_siads, 'i', s.item, 'd', s.descricao,
                                        'm', s.item_material, 'r', s.antiga_repetida) order by s.plaqueta_antiga)
    from public.siads_bens s
    where s.plaqueta_antiga is not null and s.plaqueta_antiga <> ''), '[]'::jsonb);
end
$fn$;

create or replace function public.mover_bem(p_bem uuid, p_sala uuid) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  v_uid uuid := auth.uid();
  v_status text;
  v_antes uuid;
  v_mov uuid;
begin
  if v_uid is null or not public.eh_ativo() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  select s.status into v_status from public.salas s where s.id = p_sala;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'sala_inexistente');
  end if;
  if v_status = 'mesclada' then
    return jsonb_build_object('ok', false, 'erro', 'sala_mesclada');
  end if;
  select b.sala_id into v_antes from public.bens b where b.id = p_bem for update;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'bem_inexistente');
  end if;
  if v_antes = p_sala then
    return jsonb_build_object('ok', true, 'movidos', 0);
  end if;

  update public.bens set sala_id = p_sala where id = p_bem;
  insert into public.movimentos_admin (tipo, feito_por, dados)
    values ('mover_bens', v_uid, jsonb_build_object('destino', p_sala,
            'bens', jsonb_build_array(jsonb_build_object('bem_id', p_bem, 'sala_antes', v_antes)), 'pelo_app', true))
    returning id into v_mov;
  insert into public.auditoria (usuario_id, acao, entidade, entidade_id, detalhe)
    values (v_uid, 'bem_movido', 'bens', p_bem::text,
            jsonb_build_object('de', v_antes, 'para', p_sala, 'movimento', v_mov, 'admin', public.eh_admin()));
  return jsonb_build_object('ok', true, 'movidos', 1, 'movimento_id', v_mov);
end
$fn$;

revoke all on function public.listar_siads_antigas() from public, anon;
revoke all on function public.mover_bem(uuid, uuid) from public, anon;
grant execute on function public.listar_siads_antigas() to authenticated;
grant execute on function public.mover_bem(uuid, uuid) to authenticated;
