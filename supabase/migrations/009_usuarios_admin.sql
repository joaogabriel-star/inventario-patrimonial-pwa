-- Inventário Patrimonial — migração 009 (fase 2b, etapa 3). Rode no SQL Editor DEPOIS da 001 e 002. É idempotente.
-- Rode cada bloco `create ... $fn$ ... $fn$;` separadamente se o editor reclamar de texto cortado.
--
-- Administração de usuários, SÓ para o administrador (o servidor confere o papel):
--   listar_usuarios()                  todos os perfis, com e-mail e situação (os que aguardam aprovação vêm primeiro)
--   alterar_usuario(id, acao)          acao: 'ativar' (aprovar ou reativar), 'desativar', 'tornar_admin', 'tornar_coletor',
--                                      'exigir_troca_senha'
-- Regras de segurança (no servidor, não só na tela):
--   * o administrador não desativa nem rebaixa a si mesmo, nem exige a troca da própria senha (não se tranca para fora);
--   * sempre sobra pelo menos um administrador ativo (a conferência trava os administradores para duas pessoas
--     não se rebaixarem ao mesmo tempo);
--   * só um usuário ATIVO vira administrador;
--   * nada é apagado; toda alteração vai para a auditoria com o estado anterior.
-- Redefinir a senha em si continua sendo no painel do Supabase (Authentication → Users); 'exigir_troca_senha' obriga a
-- pessoa a trocar a senha provisória no próximo login.

create or replace function public.listar_usuarios() returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
begin
  if auth.uid() is null or not public.eh_admin() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(x.j order by x.pendente desc, x.nome)
    from (
      select u.nome, (not u.ativo and u.aprovado_em is null) as pendente, jsonb_build_object(
        'id', u.id, 'nome', u.nome, 'sigla', u.sigla, 'papel', u.papel, 'ativo', u.ativo,
        'aprovado_em', u.aprovado_em, 'deve_trocar_senha', u.deve_trocar_senha, 'criado_em', u.criado_em,
        'email', a.email::text) as j
      from public.usuarios u
      left join auth.users a on a.id = u.id) x), '[]'::jsonb);
end
$fn$;

create or replace function public.alterar_usuario(p_id uuid, p_acao text) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  v_uid uuid := auth.uid();
  v_u record;
  v_outros integer;
begin
  if v_uid is null or not public.eh_admin() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  if p_acao is null or p_acao not in ('ativar', 'desativar', 'tornar_admin', 'tornar_coletor', 'exigir_troca_senha') then
    return jsonb_build_object('ok', false, 'erro', 'acao_invalida');
  end if;
  -- trava os administradores: duas pessoas não se rebaixam ao mesmo tempo e deixam o sistema sem administrador
  perform 1 from public.usuarios where papel = 'admin' for update;
  -- relê a permissão depois do lock: quem acabou de ser rebaixado por outro administrador não age mais
  if not public.eh_admin() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  select * into v_u from public.usuarios where id = p_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'usuario_inexistente');
  end if;
  if p_id = v_uid and p_acao in ('desativar', 'tornar_coletor', 'exigir_troca_senha') then
    return jsonb_build_object('ok', false, 'erro', 'nao_em_si_mesmo');
  end if;
  if v_u.papel = 'admin' and v_u.ativo and p_acao in ('desativar', 'tornar_coletor') then
    select count(*) into v_outros from public.usuarios where papel = 'admin' and ativo and id <> p_id;
    if v_outros = 0 then
      return jsonb_build_object('ok', false, 'erro', 'ultimo_admin');
    end if;
  end if;

  if p_acao = 'ativar' then
    update public.usuarios set ativo = true, aprovado_em = coalesce(aprovado_em, now()), atualizado_em = now() where id = p_id;
  elsif p_acao = 'desativar' then
    update public.usuarios set ativo = false, atualizado_em = now() where id = p_id;
  elsif p_acao = 'tornar_admin' then
    if not v_u.ativo then
      return jsonb_build_object('ok', false, 'erro', 'usuario_inativo');
    end if;
    update public.usuarios set papel = 'admin', atualizado_em = now() where id = p_id;
  elsif p_acao = 'tornar_coletor' then
    update public.usuarios set papel = 'coletor', atualizado_em = now() where id = p_id;
  else
    update public.usuarios set deve_trocar_senha = true, atualizado_em = now() where id = p_id;
    insert into public.usuarios_seguranca (usuario_id, senha_ref)
      select p_id, md5(a.encrypted_password) from auth.users a where a.id = p_id
      on conflict (usuario_id) do update set senha_ref = excluded.senha_ref;
  end if;

  insert into public.auditoria (usuario_id, acao, entidade, entidade_id, detalhe)
    values (v_uid, 'usuario_alterado', 'usuarios', p_id::text,
            jsonb_build_object('acao', p_acao, 'sigla', v_u.sigla,
                               'antes', jsonb_build_object('papel', v_u.papel, 'ativo', v_u.ativo, 'deve_trocar_senha', v_u.deve_trocar_senha)));
  return jsonb_build_object('ok', true);
end
$fn$;

revoke all on function public.listar_usuarios() from public, anon;
revoke all on function public.alterar_usuario(uuid, text) from public, anon;
grant execute on function public.listar_usuarios() to authenticated;
grant execute on function public.alterar_usuario(uuid, text) to authenticated;
