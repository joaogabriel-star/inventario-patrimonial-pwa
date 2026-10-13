-- Inventário Patrimonial — migração 002 (endurecimento; lote 1 da auditoria)
-- Rode no SQL Editor DEPOIS da 001 e DEPOIS de publicar o app v0.6.0 (o app antigo não entende "aguardando aprovação"
-- nem a troca obrigatória de senha). É idempotente.
--
-- O que muda:
--   A-6  perfil novo nasce INATIVO; o administrador aprova (veja docs/CONFIGURACAO-SUPABASE.md)
--   A-4  ninguém escreve direto em bens/etiquetas/salas/CPF/auditoria pela API: só pelo RPC sincronizar_lote
--   M-1  anulação que o servidor ignora (bem restaurado pelo admin) deixa de ser confirmada como aplicada
--   M-12 troca de senha obrigatória no primeiro login (o servidor confere que a senha mudou de verdade)
--
-- ATENÇÃO: todos os usuários que já existem passam a precisar trocar a senha no próximo login.

-- =====================================================================================================
-- A-6 / M-12: aprovação de perfil e troca obrigatória de senha
-- =====================================================================================================
alter table public.usuarios add column if not exists aprovado_em timestamptz;
alter table public.usuarios add column if not exists deve_trocar_senha boolean not null default true;

-- quem já existia é considerado aprovado (só perfis NOVOS ficam aguardando aprovação)
update public.usuarios set aprovado_em = coalesce(aprovado_em, criado_em) where aprovado_em is null;

-- referência da senha vigente (hash do hash), para o servidor conferir que a senha realmente mudou.
-- Tabela sem nenhuma política: nem o app nem a API conseguem ler; só as funções abaixo.
create table if not exists public.usuarios_seguranca (
  usuario_id uuid primary key references public.usuarios (id),
  senha_ref text not null
);
alter table public.usuarios_seguranca enable row level security;
revoke all on public.usuarios_seguranca from anon, authenticated;

insert into public.usuarios_seguranca (usuario_id, senha_ref)
select u.id, md5(a.encrypted_password)
from public.usuarios u join auth.users a on a.id = u.id
on conflict (usuario_id) do nothing;

-- "ativo" agora também exige a senha já trocada: quem não trocou não lê nem sincroniza nada
create or replace function public.eh_ativo() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.usuarios u where u.id = auth.uid() and u.ativo and not u.deve_trocar_senha)
$$;

create or replace function public.eh_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.usuarios u
                 where u.id = auth.uid() and u.ativo and not u.deve_trocar_senha and u.papel = 'admin')
$$;

-- Primeiro login: nome + sigla (única). O perfil nasce INATIVO e sem aprovação.
create or replace function public.criar_perfil(p_nome text, p_sigla text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_nome text := btrim(coalesce(p_nome, ''));
  v_sigla text := upper(btrim(coalesce(p_sigla, '')));
  v jsonb;
begin
  if v_uid is null then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  if v_nome = '' then
    return jsonb_build_object('ok', false, 'erro', 'nome_vazio');
  end if;
  if v_sigla !~ '^[A-Z0-9]{2,4}$' then
    return jsonb_build_object('ok', false, 'erro', 'sigla_invalida');
  end if;
  if exists (select 1 from public.usuarios where id = v_uid) then
    return jsonb_build_object('ok', false, 'erro', 'perfil_existente');
  end if;
  begin
    insert into public.usuarios (id, nome, sigla, ativo, aprovado_em, deve_trocar_senha)
      values (v_uid, v_nome, v_sigla, false, null, true);
  exception when unique_violation then
    if exists (select 1 from public.usuarios where id = v_uid) then
      return jsonb_build_object('ok', false, 'erro', 'perfil_existente');
    end if;
    return jsonb_build_object('ok', false, 'erro', 'sigla_em_uso');
  end;
  insert into public.usuarios_seguranca (usuario_id, senha_ref)
    select v_uid, md5(a.encrypted_password) from auth.users a where a.id = v_uid
    on conflict (usuario_id) do update set senha_ref = excluded.senha_ref;
  insert into public.auditoria (usuario_id, acao, entidade, entidade_id, detalhe)
    values (v_uid, 'perfil_criado', 'usuarios', v_uid::text, jsonb_build_object('sigla', v_sigla, 'ativo', false));
  select to_jsonb(u) into v from public.usuarios u where u.id = v_uid;
  return jsonb_build_object('ok', true, 'perfil', v);
end
$$;

-- Chamada pelo app depois de trocar a senha. O servidor confere que a senha MUDOU (compara com a referência).
create or replace function public.senha_trocada() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_ref text;
  v_atual text;
  v jsonb;
begin
  if v_uid is null then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  if not exists (select 1 from public.usuarios where id = v_uid and ativo) then
    return jsonb_build_object('ok', false, 'erro', 'sem_perfil_ativo');
  end if;
  select s.senha_ref into v_ref from public.usuarios_seguranca s where s.usuario_id = v_uid;
  select md5(a.encrypted_password) into v_atual from auth.users a where a.id = v_uid;
  if v_ref is not null and v_atual = v_ref then
    return jsonb_build_object('ok', false, 'erro', 'senha_igual');
  end if;
  update public.usuarios set deve_trocar_senha = false where id = v_uid;
  insert into public.usuarios_seguranca (usuario_id, senha_ref) values (v_uid, v_atual)
    on conflict (usuario_id) do update set senha_ref = excluded.senha_ref;
  insert into public.auditoria (usuario_id, acao, entidade, entidade_id)
    values (v_uid, 'senha_trocada', 'usuarios', v_uid::text);
  select to_jsonb(u) into v from public.usuarios u where u.id = v_uid;
  return jsonb_build_object('ok', true, 'perfil', v);
end
$$;

-- Para o administrador, no SQL Editor (não é exposta à API): obriga alguém a trocar a senha de novo,
-- por exemplo depois de você redefinir a senha dessa pessoa no painel.  select public.exigir_troca_senha('XX');
create or replace function public.exigir_troca_senha(p_sigla text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  select id into v_id from public.usuarios where sigla = upper(p_sigla);
  if v_id is null then raise exception 'sigla não encontrada: %', p_sigla; end if;
  update public.usuarios set deve_trocar_senha = true where id = v_id;
  insert into public.usuarios_seguranca (usuario_id, senha_ref)
    select v_id, md5(a.encrypted_password) from auth.users a where a.id = v_id
    on conflict (usuario_id) do update set senha_ref = excluded.senha_ref;
end
$$;

revoke all on function public.senha_trocada() from public, anon;
grant execute on function public.senha_trocada() to authenticated;
revoke all on function public.exigir_troca_senha(text) from public, anon, authenticated;
revoke all on function public.criar_perfil(text, text) from public, anon;
grant execute on function public.criar_perfil(text, text) to authenticated;

-- =====================================================================================================
-- A-4: nenhuma escrita direta do coletor pela API. Tudo passa pelo RPC (security definer), que valida o dono,
--      define recebido_em e calcula numero_normalizado/alerta_formato.
-- =====================================================================================================
revoke insert on
  public.usuarios, public.salas, public.salas_responsavel_pessoal, public.bens, public.etiquetas, public.auditoria
from authenticated;
-- (localidades, tipos_bem, descricoes_bem e resolucoes_duplicidade continuam aceitando INSERT só de admin, por política)

-- =====================================================================================================
-- M-1: anulação que o servidor ignora não é mais confirmada como aplicada
-- =====================================================================================================
create or replace function public.sincronizar_lote(p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_disp text := nullif(p_lote ->> 'dispositivo_id', '');
  j jsonb;
  v_id uuid;
  v_bem uuid;
  v_sala uuid;
  v_n integer;
  v_dono uuid;
  v_sit text;
  v_rest timestamptz;
  v_em timestamptz;
  v_nome text;
  v_and text;
  v_loc text;
  v_serie text;
  v_num text;
  v_cpf text;
  v_mat text;
  r_salas uuid[] := '{}';
  r_bens uuid[] := '{}';
  r_etq uuid[] := '{}';
  r_anu uuid[] := '{}';
  v_adiados jsonb := '[]'::jsonb;
  v_ignoradas jsonb := '[]'::jsonb;
begin
  if v_uid is null or not public.eh_ativo() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;

  -- 1) salas
  for j in select * from jsonb_array_elements(coalesce(p_lote -> 'salas', '[]'::jsonb)) loop
    begin
      v_id := (j ->> 'id')::uuid;
      v_nome := coalesce(j ->> 'nome', '');
      v_and := coalesce(j ->> 'andar', '');
      v_loc := coalesce(j ->> 'localidade', '');
      insert into public.salas (
        id, nome, nome_norm, coordenacao, coordenacao_norm, uorg, andar, localidade,
        responsavel_nome, responsavel_siorg, responsavel_uorg, legado, origem,
        criado_por, criado_em_dispositivo, dispositivo_id)
      values (
        v_id, v_nome, public.norm_sala(v_nome), coalesce(j ->> 'coordenacao', ''), public.norm_texto(j ->> 'coordenacao'),
        coalesce(j ->> 'uorg', ''), v_and, v_loc,
        coalesce(j ->> 'responsavel_nome', ''), coalesce(j ->> 'responsavel_siorg', ''), coalesce(j ->> 'responsavel_uorg', ''),
        case when jsonb_typeof(j -> 'legado') = 'object' then j -> 'legado' else null end,
        case when j ->> 'origem' = 'importacao' then 'importacao' else 'campo' end,
        v_uid, nullif(j ->> 'criado_em', '')::timestamptz, v_disp)
      on conflict (id) do nothing;
      get diagnostics v_n = row_count;
      if v_n = 1 then
        if exists (
          select 1 from public.salas o
          where o.id <> v_id and o.status <> 'mesclada'
            and o.nome_norm = public.norm_sala(v_nome)
            and public.norm_texto(o.andar) = public.norm_texto(v_and)
            and public.norm_texto(o.localidade) = public.norm_texto(v_loc)
        ) then
          update public.salas set status = 'possivel_duplicata' where id = v_id;
        end if;
        v_cpf := btrim(coalesce(j ->> 'responsavel_cpf', ''));
        v_mat := btrim(coalesce(j ->> 'responsavel_matricula', ''));
        if v_cpf <> '' or v_mat <> '' then
          insert into public.salas_responsavel_pessoal (sala_id, cpf, matricula, usuario_id)
            values (v_id, v_cpf, v_mat, v_uid) on conflict (sala_id) do nothing;
        end if;
      end if;
      r_salas := r_salas || v_id;
    exception when others then
      v_adiados := v_adiados || jsonb_build_object('tabela', 'salas', 'id', j ->> 'id', 'motivo', sqlerrm);
    end;
  end loop;

  -- 2) bens
  for j in select * from jsonb_array_elements(coalesce(p_lote -> 'bens', '[]'::jsonb)) loop
    begin
      v_id := (j ->> 'id')::uuid;
      v_sala := (j ->> 'sala_id')::uuid;
      if not exists (select 1 from public.salas where id = v_sala) then
        v_adiados := v_adiados || jsonb_build_object('tabela', 'bens', 'id', j ->> 'id', 'motivo', 'sala_inexistente');
      else
        insert into public.bens (
          id, sala_id, tipo_bem, tipo_bem_outro, descricao, item_material, descricao_origem, marca, fornecedor,
          observacao, etiquetado_em_campo, codigo_provisorio, usuario_id, registrado_em, dispositivo_id)
        values (
          v_id, v_sala, coalesce(j ->> 'tipo_bem', ''), coalesce(j ->> 'tipo_bem_outro', ''),
          coalesce(j ->> 'descricao', ''), coalesce(j ->> 'item_material', ''), coalesce(j ->> 'descricao_origem', ''),
          coalesce(j ->> 'marca', ''), coalesce(j ->> 'fornecedor', ''), coalesce(j ->> 'observacao', ''),
          coalesce((j ->> 'etiquetado_em_campo')::boolean, false), nullif(j ->> 'codigo_provisorio', ''),
          v_uid, nullif(j ->> 'registrado_em', '')::timestamptz, v_disp)
        on conflict (id) do nothing;
        r_bens := r_bens || v_id;
      end if;
    exception when others then
      v_adiados := v_adiados || jsonb_build_object('tabela', 'bens', 'id', j ->> 'id', 'motivo', sqlerrm);
    end;
  end loop;

  -- 3) etiquetas (formato e duplicidade viram alerta, nunca rejeição)
  for j in select * from jsonb_array_elements(coalesce(p_lote -> 'etiquetas', '[]'::jsonb)) loop
    begin
      v_id := (j ->> 'id')::uuid;
      v_bem := (j ->> 'bem_id')::uuid;
      select b.usuario_id into v_dono from public.bens b where b.id = v_bem;
      if not found then
        v_adiados := v_adiados || jsonb_build_object('tabela', 'etiquetas', 'id', j ->> 'id', 'motivo', 'bem_inexistente');
      elsif v_dono <> v_uid and not public.eh_admin() then
        v_adiados := v_adiados || jsonb_build_object('tabela', 'etiquetas', 'id', j ->> 'id', 'motivo', 'bem_de_outro_usuario');
      else
        v_num := btrim(coalesce(j ->> 'numero', ''));
        v_serie := case when j ->> 'serie' in ('curto', 'longo', 'outra') then j ->> 'serie' else 'outra' end;
        insert into public.etiquetas (
          id, bem_id, numero, numero_normalizado, serie, origem, simbologia, alerta_formato,
          usuario_id, registrado_em, dispositivo_id)
        values (
          v_id, v_bem, v_num, public.norm_numero(v_num), v_serie, coalesce(j ->> 'origem', 'manual'),
          coalesce(j ->> 'simbologia', ''), public.alerta_formato(v_num, v_serie),
          v_uid, nullif(j ->> 'registrado_em', '')::timestamptz, v_disp)
        on conflict (id) do nothing;
        r_etq := r_etq || v_id;
      end if;
    exception when others then
      v_adiados := v_adiados || jsonb_build_object('tabela', 'etiquetas', 'id', j ->> 'id', 'motivo', sqlerrm);
    end;
  end loop;

  -- 4) anulações (dono do bem ou admin)
  --    aplicada ou já anulada  -> confirmada (anulacoes)
  --    mais antiga que uma restauração do admin -> NÃO aplicada e NÃO confirmada: vai em anulacoes_ignoradas,
  --    com a data da restauração, para o app voltar o bem a "ativo" (o servidor é a verdade)
  for j in select * from jsonb_array_elements(coalesce(p_lote -> 'anulacoes', '[]'::jsonb)) loop
    begin
      v_bem := (j ->> 'bem_id')::uuid;
      v_em := coalesce(nullif(j ->> 'em', '')::timestamptz, now());
      select b.usuario_id, b.situacao, b.restaurado_em into v_dono, v_sit, v_rest from public.bens b where b.id = v_bem;
      if not found then
        v_adiados := v_adiados || jsonb_build_object('tabela', 'anulacoes', 'id', j ->> 'bem_id', 'motivo', 'bem_inexistente');
      elsif v_dono <> v_uid and not public.eh_admin() then
        v_adiados := v_adiados || jsonb_build_object('tabela', 'anulacoes', 'id', j ->> 'bem_id', 'motivo', 'sem_permissao');
      elsif v_sit = 'anulado' then
        r_anu := r_anu || v_bem;
      elsif v_rest is null or v_em > v_rest then
        update public.bens
           set situacao = 'anulado', motivo_anulacao = coalesce(j ->> 'motivo', ''), anulado_por = v_uid, anulado_em = v_em
         where id = v_bem;
        insert into public.auditoria (usuario_id, acao, entidade, entidade_id, detalhe, dispositivo_id)
          values (v_uid, 'bem_anulado', 'bens', v_bem::text, jsonb_build_object('motivo', coalesce(j ->> 'motivo', '')), v_disp);
        r_anu := r_anu || v_bem;
      else
        v_ignoradas := v_ignoradas || jsonb_build_object('bem_id', v_bem, 'restaurado_em', v_rest);
      end if;
    exception when others then
      v_adiados := v_adiados || jsonb_build_object('tabela', 'anulacoes', 'id', j ->> 'bem_id', 'motivo', sqlerrm);
    end;
  end loop;

  if cardinality(r_salas) + cardinality(r_bens) + cardinality(r_etq) + cardinality(r_anu) > 0 then
    insert into public.auditoria (usuario_id, acao, detalhe, dispositivo_id)
      values (v_uid, 'lote_sincronizado',
              jsonb_build_object('salas', cardinality(r_salas), 'bens', cardinality(r_bens),
                                 'etiquetas', cardinality(r_etq), 'anulacoes', cardinality(r_anu)), v_disp);
  end if;

  return jsonb_build_object(
    'recebido_em', now(),
    'salas', to_jsonb(r_salas), 'bens', to_jsonb(r_bens), 'etiquetas', to_jsonb(r_etq), 'anulacoes', to_jsonb(r_anu),
    'anulacoes_ignoradas', v_ignoradas,
    'adiados', v_adiados);
end
$$;

revoke all on function public.sincronizar_lote(jsonb) from public, anon;
grant execute on function public.sincronizar_lote(jsonb) to authenticated;
