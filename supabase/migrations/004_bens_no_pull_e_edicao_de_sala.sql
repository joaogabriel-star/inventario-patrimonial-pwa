-- Inventário Patrimonial — migração 004. Rode no SQL Editor DEPOIS da 001, 002 e 003. É idempotente.
--
-- ORDEM DE DEPLOY: pode rodar antes ou depois de publicar o app v0.6.1. O app novo, se o servidor ainda não conhecer
-- a tabela 'bens' em puxar_pagina, simplesmente não baixa os bens dos outros (e usa o resto normalmente).
--
-- O que muda:
--   1) puxar_pagina passa a aceitar p_tabela = 'bens': cada celular baixa os bens (com etiquetas) de TODOS os usuários,
--      em páginas, na ordem do id. Só o nome e a sigla de quem registrou; nada de usuario_id nem de CPF/matrícula.
--   2) atualizar_sala: qualquer usuário ativo edita os dados de uma sala já no servidor (nome, coordenação, UORG, andar,
--      localidade, responsável). CPF e matrícula só entram se quem chama for admin. Toda edição vai para a auditoria com o
--      estado ANTERIOR da sala (sem CPF/matrícula).
--   3) ler_responsavel_pessoal: só o admin lê CPF/matrícula (para preencher o formulário de edição).
-- Esta migração só REDEFINE puxar_pagina (a mesma da 003 + o ramo 'bens'); não altera puxar_mudancas nem eh_ativo/eh_admin.

-- ---------------------------------------------------------------------------------------------------------
-- 1) puxar_pagina com 'bens'
-- ---------------------------------------------------------------------------------------------------------
create or replace function public.puxar_pagina(
  p_tabela text,
  p_desde timestamptz default null,
  p_apos uuid default null,
  p_limite integer default 2000
) returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_desde timestamptz := coalesce(p_desde - interval '2 minutes', '-infinity'::timestamptz);
  v_lim integer := least(greatest(coalesce(p_limite, 2000), 1), 5000);
  v_itens jsonb := '[]'::jsonb;
  v_mais boolean := false;
  v_ultimo uuid;
begin
  if auth.uid() is null or not public.eh_ativo() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;

  if p_tabela = 'tipos' then
    with p0 as (
      select t.id, jsonb_build_object('id', t.id, 'nome', t.nome, 'ativo', t.ativo) as j
      from public.tipos_bem t
      where t.atualizado_em >= v_desde and (p_apos is null or t.id > p_apos)
      order by t.id limit v_lim + 1),
    p as (select p0.id, p0.j, row_number() over (order by p0.id) as rn from p0)
    select coalesce(jsonb_agg(j order by id) filter (where rn <= v_lim), '[]'::jsonb),
           coalesce(bool_or(rn > v_lim), false),
           (array_agg(id order by id) filter (where rn <= v_lim))[v_lim]
      into v_itens, v_mais, v_ultimo
    from p;

  elsif p_tabela = 'localidades' then
    with p0 as (
      select l.id, jsonb_build_object('id', l.id, 'nome', l.nome, 'ativo', l.ativo) as j
      from public.localidades l
      where l.atualizado_em >= v_desde and (p_apos is null or l.id > p_apos)
      order by l.id limit v_lim + 1),
    p as (select p0.id, p0.j, row_number() over (order by p0.id) as rn from p0)
    select coalesce(jsonb_agg(j order by id) filter (where rn <= v_lim), '[]'::jsonb),
           coalesce(bool_or(rn > v_lim), false),
           (array_agg(id order by id) filter (where rn <= v_lim))[v_lim]
      into v_itens, v_mais, v_ultimo
    from p;

  elsif p_tabela = 'salas' then
    with p0 as (
      select s.id, jsonb_build_object(
        'id', s.id, 'nome', s.nome, 'coordenacao', s.coordenacao, 'uorg', s.uorg, 'andar', s.andar,
        'localidade', s.localidade, 'responsavel_nome', s.responsavel_nome, 'responsavel_siorg', s.responsavel_siorg,
        'responsavel_uorg', s.responsavel_uorg, 'legado', s.legado, 'status', s.status,
        'mesclada_em_id', s.mesclada_em_id, 'origem', s.origem, 'recebido_em', s.recebido_em) as j
      from public.salas s
      where s.atualizado_em >= v_desde and (p_apos is null or s.id > p_apos)
      order by s.id limit v_lim + 1),
    p as (select p0.id, p0.j, row_number() over (order by p0.id) as rn from p0)
    select coalesce(jsonb_agg(j order by id) filter (where rn <= v_lim), '[]'::jsonb),
           coalesce(bool_or(rn > v_lim), false),
           (array_agg(id order by id) filter (where rn <= v_lim))[v_lim]
      into v_itens, v_mais, v_ultimo
    from p;

  elsif p_tabela = 'descricoes' then
    with p0 as (
      select d.id, jsonb_build_object('id', d.id, 'tipo', d.tipo_nome, 'texto', d.texto,
                                      'item_material', d.item_material, 'ativo', d.ativo, 'origem', d.origem) as j
      from public.descricoes_bem d
      where d.atualizado_em >= v_desde and (p_apos is null or d.id > p_apos)
      order by d.id limit v_lim + 1),
    p as (select p0.id, p0.j, row_number() over (order by p0.id) as rn from p0)
    select coalesce(jsonb_agg(j order by id) filter (where rn <= v_lim), '[]'::jsonb),
           coalesce(bool_or(rn > v_lim), false),
           (array_agg(id order by id) filter (where rn <= v_lim))[v_lim]
      into v_itens, v_mais, v_ultimo
    from p;

  elsif p_tabela = 'bens' then
    -- bem muda quando ele próprio muda (anulação) OU quando chega etiqueta nova (recebido_em da etiqueta)
    with p0 as (
      select b.id, jsonb_build_object(
        'id', b.id, 'sala_id', b.sala_id, 'tipo_bem', b.tipo_bem, 'tipo_bem_outro', b.tipo_bem_outro,
        'descricao', b.descricao, 'item_material', b.item_material, 'descricao_origem', b.descricao_origem,
        'marca', b.marca, 'fornecedor', b.fornecedor, 'observacao', b.observacao,
        'etiquetado_em_campo', b.etiquetado_em_campo, 'codigo_provisorio', b.codigo_provisorio,
        'situacao', b.situacao, 'motivo_anulacao', b.motivo_anulacao, 'anulado_em', b.anulado_em,
        'registrado_em', b.registrado_em, 'recebido_em', b.recebido_em,
        'usuario_nome', u.nome, 'usuario_sigla', u.sigla,
        'etiquetas', coalesce((
          select jsonb_agg(jsonb_build_object('id', e.id, 'numero', e.numero, 'serie', e.serie,
                                              'origem', e.origem, 'simbologia', e.simbologia) order by e.recebido_em, e.id)
          from public.etiquetas e where e.bem_id = b.id), '[]'::jsonb)) as j
      from public.bens b
      join public.usuarios u on u.id = b.usuario_id
      where (b.atualizado_em >= v_desde
             or exists (select 1 from public.etiquetas e2 where e2.bem_id = b.id and e2.recebido_em >= v_desde))
        and (p_apos is null or b.id > p_apos)
      order by b.id limit v_lim + 1),
    p as (select p0.id, p0.j, row_number() over (order by p0.id) as rn from p0)
    select coalesce(jsonb_agg(j order by id) filter (where rn <= v_lim), '[]'::jsonb),
           coalesce(bool_or(rn > v_lim), false),
           (array_agg(id order by id) filter (where rn <= v_lim))[v_lim]
      into v_itens, v_mais, v_ultimo
    from p;

  elsif p_tabela = 'indice' then
    with p0 as (
      select e.id, jsonb_build_object(
        'id', e.id, 'bem_id', e.bem_id, 'numero', e.numero, 'numero_normalizado', e.numero_normalizado,
        'serie', e.serie, 'sala_id', b.sala_id, 'sala_nome', s.nome, 'tipo_bem', b.tipo_bem,
        'ativo', b.situacao = 'ativo', 'sigla', u.sigla, 'registrado_em', b.registrado_em) as j
      from public.etiquetas e
      join public.bens b on b.id = e.bem_id
      join public.salas s on s.id = b.sala_id
      join public.usuarios u on u.id = b.usuario_id
      where (b.atualizado_em >= v_desde or e.recebido_em >= v_desde) and (p_apos is null or e.id > p_apos)
      order by e.id limit v_lim + 1),
    p as (select p0.id, p0.j, row_number() over (order by p0.id) as rn from p0)
    select coalesce(jsonb_agg(j order by id) filter (where rn <= v_lim), '[]'::jsonb),
           coalesce(bool_or(rn > v_lim), false),
           (array_agg(id order by id) filter (where rn <= v_lim))[v_lim]
      into v_itens, v_mais, v_ultimo
    from p;

  elsif p_tabela = 'meta' then
    -- maior número SEM-<minha sigla>-nnnn já no servidor (o app usa max(local, servidor) + 1)
    return jsonb_build_object('agora', now(), 'sem_max', coalesce((
      select max((regexp_match(b.codigo_provisorio, '^SEM-' || u.sigla || '-([0-9]+)$'))[1]::bigint)
      from public.bens b join public.usuarios u on u.id = b.usuario_id
      where u.id = auth.uid() and b.codigo_provisorio is not null), 0));

  else
    raise exception 'tabela_invalida' using errcode = '22023';
  end if;

  return jsonb_build_object('agora', now(), 'itens', v_itens, 'mais', v_mais, 'ultimo', v_ultimo);
end
$fn$;

revoke all on function public.puxar_pagina(text, timestamptz, uuid, integer) from public, anon;
grant execute on function public.puxar_pagina(text, timestamptz, uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------------------------------------
-- 2) Edição de sala: qualquer usuário ativo; CPF e matrícula só o admin
-- ---------------------------------------------------------------------------------------------------------
-- p_sala = { id, nome, coordenacao, uorg, andar, localidade, responsavel_nome, responsavel_siorg, responsavel_uorg,
--            responsavel_cpf, responsavel_matricula }
-- CPF e matrícula: só entram se quem chama é admin (para os demais são ignorados, sem erro). Vazio apaga.
create or replace function public.atualizar_sala(p_sala jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  v_uid uuid := auth.uid();
  v_id uuid := nullif(p_sala ->> 'id', '')::uuid;
  v_nome text := btrim(coalesce(p_sala ->> 'nome', ''));
  v_cpf text := btrim(coalesce(p_sala ->> 'responsavel_cpf', ''));
  v_mat text := btrim(coalesce(p_sala ->> 'responsavel_matricula', ''));
  v_ant jsonb;
begin
  if v_uid is null or not public.eh_ativo() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  if v_id is null or v_nome = '' then
    return jsonb_build_object('ok', false, 'erro', 'dados_invalidos');
  end if;
  select to_jsonb(s) - 'legado' into v_ant from public.salas s where s.id = v_id;
  if v_ant is null then
    return jsonb_build_object('ok', false, 'erro', 'sala_inexistente');
  end if;

  update public.salas set
    nome = v_nome, nome_norm = public.norm_sala(v_nome),
    coordenacao = coalesce(p_sala ->> 'coordenacao', ''), coordenacao_norm = public.norm_texto(p_sala ->> 'coordenacao'),
    uorg = coalesce(p_sala ->> 'uorg', ''), andar = coalesce(p_sala ->> 'andar', ''),
    localidade = coalesce(p_sala ->> 'localidade', ''),
    responsavel_nome = coalesce(p_sala ->> 'responsavel_nome', ''),
    responsavel_siorg = coalesce(p_sala ->> 'responsavel_siorg', ''),
    responsavel_uorg = coalesce(p_sala ->> 'responsavel_uorg', '')
  where id = v_id;

  if public.eh_admin() and (jsonb_exists(p_sala, 'responsavel_cpf') or jsonb_exists(p_sala, 'responsavel_matricula')) then
    insert into public.salas_responsavel_pessoal (sala_id, cpf, matricula, usuario_id)
      values (v_id, v_cpf, v_mat, v_uid)
      on conflict (sala_id) do update set cpf = excluded.cpf, matricula = excluded.matricula;
  end if;

  -- auditoria sem CPF/matrícula
  insert into public.auditoria (usuario_id, acao, entidade, entidade_id, detalhe)
    values (v_uid, 'sala_editada', 'salas', v_id::text,
            jsonb_build_object('antes', v_ant - 'recebido_em' - 'atualizado_em', 'nome', v_nome));
  return jsonb_build_object('ok', true);
end
$fn$;

-- ---------------------------------------------------------------------------------------------------------
-- 3) Leitura de CPF/matrícula (só admin)
-- ---------------------------------------------------------------------------------------------------------
create or replace function public.ler_responsavel_pessoal(p_sala uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
declare v jsonb;
begin
  if auth.uid() is null or not public.eh_admin() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  select jsonb_build_object('cpf', r.cpf, 'matricula', r.matricula) into v
    from public.salas_responsavel_pessoal r where r.sala_id = p_sala;
  return coalesce(v, jsonb_build_object('cpf', '', 'matricula', ''));
end
$fn$;

revoke all on function public.atualizar_sala(jsonb) from public, anon;
revoke all on function public.ler_responsavel_pessoal(uuid) from public, anon;
grant execute on function public.atualizar_sala(jsonb) to authenticated;
grant execute on function public.ler_responsavel_pessoal(uuid) to authenticated;
