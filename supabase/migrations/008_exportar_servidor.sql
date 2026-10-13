-- Inventário Patrimonial — migração 008 (fase 2b, etapa 2: exportação pelo servidor). Rode no SQL Editor DEPOIS da 001 e 002.
-- É idempotente. Se o editor cortar o texto, rode só o bloco `create ... $fn$ ... $fn$;` e depois o `revoke/grant`.
--
-- exportar_bens_pagina(apos, limite, pessoais): devolve os bens DIRETO DO BANCO, em páginas (por id), para o administrador gerar o
-- CSV sem depender de o aparelho estar sincronizado. SÓ administrador (o servidor confere). Cada item já traz a sala, a
-- coordenação, o responsável (siorg/uorg) e as etiquetas. Com pessoais = true acrescenta nome, matrícula e CPF do responsável
-- (lidos de salas_responsavel_pessoal, que só o admin lê). A primeira página de cada exportação grava uma linha na auditoria
-- ('exportacao_servidor', com o valor de pessoais).

create or replace function public.exportar_bens_pagina(
  p_apos uuid default null,
  p_limite integer default 1000,
  p_pessoais boolean default false
) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  v_uid uuid := auth.uid();
  v_lim integer := least(greatest(coalesce(p_limite, 1000), 1), 2000);
  v_itens jsonb := '[]'::jsonb;
  v_mais boolean := false;
  v_ultimo uuid;
begin
  if v_uid is null or not public.eh_admin() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;

  with p0 as (
    select b.id,
      jsonb_build_object(
        'id', b.id, 'codigo_provisorio', b.codigo_provisorio, 'etiquetado_em_campo', b.etiquetado_em_campo,
        'tipo_bem', b.tipo_bem, 'tipo_bem_outro', b.tipo_bem_outro, 'descricao', b.descricao,
        'item_material', b.item_material, 'marca', b.marca, 'fornecedor', b.fornecedor, 'observacao', b.observacao,
        'situacao', b.situacao, 'registrado_em', b.registrado_em, 'recebido_em', b.recebido_em,
        'atualizado_em', b.atualizado_em, 'registrado_por', u.nome, 'sigla', u.sigla,
        'coordenacao', s.coordenacao, 'sala', s.nome, 'uorg_sala', s.uorg, 'andar', s.andar,
        'localidade', s.localidade, 'legado', s.legado,
        'responsavel_siorg', s.responsavel_siorg, 'responsavel_uorg', s.responsavel_uorg,
        'etiquetas', coalesce((
          select jsonb_agg(jsonb_build_object('numero', e.numero, 'serie', e.serie, 'origem', e.origem)
                           order by e.recebido_em, e.id)
          from public.etiquetas e where e.bem_id = b.id), '[]'::jsonb))
      || case when p_pessoais
           then jsonb_build_object('responsavel_nome', s.responsavel_nome,
                                   'responsavel_matricula', coalesce(rp.matricula, ''),
                                   'responsavel_cpf', coalesce(rp.cpf, ''))
           else '{}'::jsonb end as j
    from public.bens b
    join public.usuarios u on u.id = b.usuario_id
    join public.salas s on s.id = b.sala_id
    left join public.salas_responsavel_pessoal rp on rp.sala_id = s.id
    where p_apos is null or b.id > p_apos
    order by b.id limit v_lim + 1),
  p as (select p0.id, p0.j, row_number() over (order by p0.id) as rn from p0)
  select coalesce(jsonb_agg(j order by id) filter (where rn <= v_lim), '[]'::jsonb),
         coalesce(bool_or(rn > v_lim), false),
         (array_agg(id order by id) filter (where rn <= v_lim))[v_lim]
    into v_itens, v_mais, v_ultimo
  from p;

  if p_apos is null then
    insert into public.auditoria (usuario_id, acao, entidade, detalhe)
      values (v_uid, 'exportacao_servidor', 'bens', jsonb_build_object('dados_pessoais', coalesce(p_pessoais, false)));
  end if;
  return jsonb_build_object('itens', v_itens, 'mais', v_mais, 'ultimo', v_ultimo);
end
$fn$;

revoke all on function public.exportar_bens_pagina(uuid, integer, boolean) from public, anon;
grant execute on function public.exportar_bens_pagina(uuid, integer, boolean) to authenticated;
