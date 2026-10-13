-- Inventário Patrimonial — migração 007 (fase 2b, etapa 1). Rode no SQL Editor DEPOIS da 001 e 002. É idempotente.
-- Rode cada bloco `create ... $fn$ ... $fn$;` separadamente se o editor reclamar de texto cortado.
--
-- Administração de bens e salas. SÓ o administrador executa (o servidor confere o papel).
--   mover_bens(ids, sala_destino)   move bens para outra sala (em lote)
--   mesclar_salas(origem, destino)  move TODOS os bens da origem para o destino e marca a origem como 'mesclada' (nada é apagado)
--   desfazer_movimento(id)          desfaz um dos dois acima
--   listar_movimentos(limite)       últimos movimentos, para a tela de administração
-- Todo movimento guarda o estado ANTERIOR em movimentos_admin (para desfazer) e vai para a auditoria.
-- Desfazer é conservador: só devolve o bem que AINDA está onde o movimento o deixou (se alguém o moveu de novo, não mexe).

create table if not exists public.movimentos_admin (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in ('mover_bens', 'mesclar_salas')),
  feito_em timestamptz not null default now(),
  feito_por uuid not null references public.usuarios (id),
  desfeito_em timestamptz,
  desfeito_por uuid references public.usuarios (id),
  dados jsonb not null
);
alter table public.movimentos_admin enable row level security;
revoke all on public.movimentos_admin from anon, authenticated;

create or replace function public.mover_bens(p_bem_ids uuid[], p_sala_destino uuid) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  v_uid uuid := auth.uid();
  v_status text;
  v_itens jsonb;
  v_n integer;
  v_mov uuid;
begin
  if v_uid is null or not public.eh_admin() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  if p_bem_ids is null or cardinality(p_bem_ids) = 0 then
    return jsonb_build_object('ok', false, 'erro', 'nada_para_mover');
  end if;
  if cardinality(p_bem_ids) > 2000 then
    return jsonb_build_object('ok', false, 'erro', 'muitos_bens');
  end if;
  select s.status into v_status from public.salas s where s.id = p_sala_destino;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'sala_inexistente');
  end if;
  if v_status = 'mesclada' then
    return jsonb_build_object('ok', false, 'erro', 'sala_mesclada');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('bem_id', b.id, 'sala_antes', b.sala_id)), '[]'::jsonb), count(*)
    into v_itens, v_n
  from public.bens b where b.id = any(p_bem_ids) and b.sala_id <> p_sala_destino;
  if v_n = 0 then
    return jsonb_build_object('ok', true, 'movidos', 0);
  end if;

  update public.bens set sala_id = p_sala_destino where id = any(p_bem_ids) and sala_id <> p_sala_destino;
  insert into public.movimentos_admin (tipo, feito_por, dados)
    values ('mover_bens', v_uid, jsonb_build_object('destino', p_sala_destino, 'bens', v_itens))
    returning id into v_mov;
  insert into public.auditoria (usuario_id, acao, entidade, entidade_id, detalhe)
    values (v_uid, 'bens_movidos', 'movimentos_admin', v_mov::text,
            jsonb_build_object('destino', p_sala_destino, 'quantidade', v_n));
  return jsonb_build_object('ok', true, 'movidos', v_n, 'movimento_id', v_mov);
end
$fn$;

create or replace function public.mesclar_salas(p_origem uuid, p_destino uuid) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  v_uid uuid := auth.uid();
  v_so record;
  v_sd record;
  v_bens jsonb;
  v_n integer;
  v_repont jsonb;
  v_mov uuid;
begin
  if v_uid is null or not public.eh_admin() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  if p_origem is null or p_destino is null or p_origem = p_destino then
    return jsonb_build_object('ok', false, 'erro', 'salas_invalidas');
  end if;
  select s.status into v_so from public.salas s where s.id = p_origem;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'origem_inexistente');
  end if;
  select s.status into v_sd from public.salas s where s.id = p_destino;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'destino_inexistente');
  end if;
  if v_so.status = 'mesclada' then
    return jsonb_build_object('ok', false, 'erro', 'origem_ja_mesclada');
  end if;
  if v_sd.status = 'mesclada' then
    return jsonb_build_object('ok', false, 'erro', 'destino_mesclado');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('bem_id', b.id, 'sala_antes', b.sala_id)), '[]'::jsonb), count(*)
    into v_bens, v_n
  from public.bens b where b.sala_id = p_origem;
  -- salas que já tinham sido mescladas NA origem passam a apontar para o destino
  select coalesce(jsonb_agg(s.id), '[]'::jsonb) into v_repont from public.salas s where s.mesclada_em_id = p_origem;

  update public.bens set sala_id = p_destino where sala_id = p_origem;
  update public.salas set mesclada_em_id = p_destino where mesclada_em_id = p_origem;
  update public.salas set status = 'mesclada', mesclada_em_id = p_destino where id = p_origem;

  insert into public.movimentos_admin (tipo, feito_por, dados)
    values ('mesclar_salas', v_uid, jsonb_build_object('origem', p_origem, 'destino', p_destino,
            'status_antes', v_so.status, 'bens', v_bens, 'reapontadas', v_repont))
    returning id into v_mov;
  insert into public.auditoria (usuario_id, acao, entidade, entidade_id, detalhe)
    values (v_uid, 'salas_mescladas', 'movimentos_admin', v_mov::text,
            jsonb_build_object('origem', p_origem, 'destino', p_destino, 'bens', v_n));
  return jsonb_build_object('ok', true, 'movidos', v_n, 'movimento_id', v_mov);
end
$fn$;

create or replace function public.desfazer_movimento(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  v_uid uuid := auth.uid();
  v_m record;
  v_n integer := 0;
  v_total integer;
  v_destino uuid;
  v_origem uuid;
  v_antes text;
begin
  if v_uid is null or not public.eh_admin() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  select * into v_m from public.movimentos_admin where id = p_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'movimento_inexistente');
  end if;
  if v_m.desfeito_em is not null then
    return jsonb_build_object('ok', false, 'erro', 'ja_desfeito');
  end if;
  v_destino := (v_m.dados ->> 'destino')::uuid;
  v_total := jsonb_array_length(v_m.dados -> 'bens');

  if v_m.tipo = 'mesclar_salas' then
    v_origem := (v_m.dados ->> 'origem')::uuid;
    v_antes := v_m.dados ->> 'status_antes';
    -- a origem precisa ainda estar mesclada NO destino; senão alguém mexeu depois e o desfazer é recusado
    update public.salas set status = coalesce(v_antes, 'ativa'), mesclada_em_id = null
      where id = v_origem and status = 'mesclada' and mesclada_em_id = v_destino;
    if not found then
      return jsonb_build_object('ok', false, 'erro', 'estado_mudou');
    end if;
    update public.salas set mesclada_em_id = v_origem
      where mesclada_em_id = v_destino and id in (select (x)::uuid from jsonb_array_elements_text(v_m.dados -> 'reapontadas') x);
  end if;

  -- devolve só os bens que AINDA estão na sala de destino do movimento
  with it as (
    select (x ->> 'bem_id')::uuid as bem_id, (x ->> 'sala_antes')::uuid as sala_antes
    from jsonb_array_elements(v_m.dados -> 'bens') x),
  up as (
    update public.bens b set sala_id = it.sala_antes
    from it where b.id = it.bem_id and b.sala_id = v_destino
    returning b.id)
  select count(*) into v_n from up;

  update public.movimentos_admin set desfeito_em = now(), desfeito_por = v_uid where id = p_id;
  insert into public.auditoria (usuario_id, acao, entidade, entidade_id, detalhe)
    values (v_uid, 'movimento_desfeito', 'movimentos_admin', p_id::text,
            jsonb_build_object('tipo', v_m.tipo, 'restaurados', v_n, 'pulados', v_total - v_n));
  return jsonb_build_object('ok', true, 'restaurados', v_n, 'pulados', v_total - v_n);
end
$fn$;

create or replace function public.listar_movimentos(p_limite integer default 30) returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
begin
  if auth.uid() is null or not public.eh_admin() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(x.j order by x.feito_em desc)
    from (
      select m.feito_em, jsonb_build_object(
        'id', m.id, 'tipo', m.tipo, 'feito_em', m.feito_em, 'feito_por', u.nome, 'desfeito_em', m.desfeito_em,
        'destino', sd.nome, 'origem', so.nome, 'quantidade', jsonb_array_length(m.dados -> 'bens')) as j
      from public.movimentos_admin m
      join public.usuarios u on u.id = m.feito_por
      left join public.salas sd on sd.id = (m.dados ->> 'destino')::uuid
      left join public.salas so on so.id = nullif(m.dados ->> 'origem', '')::uuid
      order by m.feito_em desc
      limit least(greatest(coalesce(p_limite, 30), 1), 100)) x), '[]'::jsonb);
end
$fn$;

revoke all on function public.mover_bens(uuid[], uuid) from public, anon;
revoke all on function public.mesclar_salas(uuid, uuid) from public, anon;
revoke all on function public.desfazer_movimento(uuid) from public, anon;
revoke all on function public.listar_movimentos(integer) from public, anon;
grant execute on function public.mover_bens(uuid[], uuid) to authenticated;
grant execute on function public.mesclar_salas(uuid, uuid) to authenticated;
grant execute on function public.desfazer_movimento(uuid) to authenticated;
grant execute on function public.listar_movimentos(integer) to authenticated;
