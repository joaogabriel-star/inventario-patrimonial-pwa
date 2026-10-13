-- Inventário Patrimonial — migração 003 (lote 2 da auditoria). Rode no SQL Editor DEPOIS da 001 e da 002. É idempotente.
--
-- ORDEM DE DEPLOY: pode rodar antes ou depois de publicar o app. O app novo, se não achar a função `puxar_pagina`, usa a
-- antiga `puxar_mudancas` (que esta migração NÃO altera, para o app 0.5.1 continuar funcionando até todos atualizarem).
--
-- O que muda:
--   M-6  nova função puxar_pagina: o pull vem em páginas (por tabela, na ordem do id), em vez de um único jsonb gigante
--   M-7  nova view v_duplicidades_provisorio: códigos SEM-xx-nnnn repetidos entre bens ativos

-- =====================================================================================================
-- M-6: pull paginado
--   p_tabela : 'tipos' | 'localidades' | 'salas' | 'descricoes' | 'indice' | 'meta'
--   p_desde  : cursor do último pull completo (null = tudo); usa 2 min de folga, como a função antiga
--   p_apos   : id do último item da página anterior (null = primeira página)
--   p_limite : itens por página (1 a 5000; padrão 2000)
--   Devolve { agora, itens, mais, ultimo }  ou, para 'meta', { agora, sem_max }.
--   Não traz CPF nem matrícula (mesmos campos do pull antigo).
-- =====================================================================================================
create or replace function public.puxar_pagina(
  p_tabela text,
  p_desde timestamptz default null,
  p_apos uuid default null,
  p_limite integer default 2000
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
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
$$;

revoke all on function public.puxar_pagina(text, timestamptz, uuid, integer) from public, anon;
grant execute on function public.puxar_pagina(text, timestamptz, uuid, integer) to authenticated;

-- =====================================================================================================
-- M-7: códigos provisórios repetidos
--   O contador SEM-<sigla>-nnnn é local: apagar os dados do navegador, usar dois aparelhos ou abrir duas abas pode
--   gerar o mesmo código para bens diferentes. O app nunca bloqueia; esta view lista os repetidos para o administrador
--   (na fase 2b vira tela). Considera só bens ativos.
-- =====================================================================================================
create or replace view public.v_duplicidades_provisorio with (security_invoker = true) as
select b.codigo_provisorio,
       count(*) as qtd_bens,
       count(distinct b.usuario_id) as qtd_usuarios,
       count(distinct b.sala_id) as qtd_salas,
       array_agg(b.id order by b.registrado_em, b.id) as bem_ids,
       array_agg(distinct b.sala_id) as sala_ids,
       min(b.registrado_em) as primeiro_registro_em
from public.bens b
where b.situacao = 'ativo' and b.codigo_provisorio is not null
group by b.codigo_provisorio
having count(*) > 1;

revoke all on public.v_duplicidades_provisorio from anon;
grant select on public.v_duplicidades_provisorio to authenticated;
