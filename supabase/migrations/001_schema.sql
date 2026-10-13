-- Inventário Patrimonial — esquema do banco (Fase 2a)
-- Rode inteiro no SQL Editor do Supabase (ou via CLI). É idempotente na maior parte; se precisar refazer do zero,
-- apague as tabelas antes (cuidado: só faça isso antes do inventário real).
--
-- Princípios:
--  * Ninguém tem DELETE (nem política, nem permissão). Anular é mudar a situação.
--  * Número patrimonial NÃO é único: duplicidade é sinalizada, nunca bloqueia.
--  * O celular gera os UUIDs; reenviar o mesmo registro não duplica (on conflict do nothing).
--  * CPF e matrícula do responsável ficam em tabela separada, só admin lê.

-- =====================================================================================================
-- Funções de normalização (iguais em espírito às do app)
-- =====================================================================================================
create or replace function public.norm_texto(t text) returns text
language sql immutable as $$
  select btrim(regexp_replace(lower(translate(coalesce(t, ''),
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')), '[^a-z0-9]+', ' ', 'g'))
$$;

-- nome de sala: sem as palavras "sala"/"sl" ("Sala 101" = "sala 101" = "101")
create or replace function public.norm_sala(t text) returns text
language sql immutable as $$
  select btrim(regexp_replace(regexp_replace(public.norm_texto(t), '\m(sala|sl)\M', ' ', 'g'), '\s+', ' ', 'g'))
$$;

-- número da etiqueta para comparar: sem espaços, hífens e pontos; zeros à esquerda preservados
create or replace function public.norm_numero(t text) returns text
language sql immutable as $$
  select upper(regexp_replace(coalesce(t, ''), '[\s\-\.]', '', 'g'))
$$;

-- só um aviso, nunca rejeita
create or replace function public.alerta_formato(n text, s text) returns text
language sql immutable as $$
  select case
    when n is null or btrim(n) = '' then 'número vazio'
    when btrim(n) !~ '^[0-9]+$' then 'contém caracteres que não são dígitos'
    when s = 'curto' and btrim(n) !~ '^0[0-9]{4}$' then 'série curto espera 5 caracteres começando com 0'
    when s = 'longo' and btrim(n) !~ '^[0-9]{7,8}$' then 'série longo espera 7 ou 8 dígitos'
    else null
  end
$$;

create or replace function public.tg_atualizado_em() returns trigger
language plpgsql as $$
begin
  new.atualizado_em := now();
  return new;
end
$$;

-- =====================================================================================================
-- Tabelas
-- =====================================================================================================
create table if not exists public.usuarios (
  id uuid primary key references auth.users (id),
  nome text not null,
  sigla text not null check (sigla ~ '^[A-Z0-9]{2,4}$'),
  papel text not null default 'coletor' check (papel in ('coletor', 'admin')),
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index if not exists usuarios_sigla_uq on public.usuarios (sigla);

create table if not exists public.localidades (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  nome_norm text not null,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index if not exists localidades_norm_uq on public.localidades (nome_norm);

create table if not exists public.tipos_bem (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  nome_norm text not null,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index if not exists tipos_bem_norm_uq on public.tipos_bem (nome_norm);

-- o bem guarda o NOME do tipo (texto), sem chave estrangeira: nunca é rejeitado por causa da lista
create table if not exists public.descricoes_bem (
  id uuid primary key default gen_random_uuid(),
  tipo_nome text not null,
  tipo_norm text not null,
  texto text not null,
  texto_norm text not null,
  item_material text not null default '',
  ativo boolean not null default true,
  origem text not null default 'app' check (origem in ('siads', 'app')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index if not exists descricoes_bem_uq on public.descricoes_bem (tipo_norm, texto_norm, item_material);

create table if not exists public.salas (
  id uuid primary key,                                  -- gerado no celular
  nome text not null,
  nome_norm text not null,
  coordenacao text not null default '',
  coordenacao_norm text not null default '',
  uorg text not null default '',
  andar text not null default '',
  localidade text not null default '',
  responsavel_nome text not null default '',
  responsavel_siorg text not null default '',
  responsavel_uorg text not null default '',
  legado jsonb,                                         -- níveis org. antigos (não aparecem no app)
  status text not null default 'ativa' check (status in ('ativa', 'possivel_duplicata', 'mesclada')),
  mesclada_em_id uuid references public.salas (id),
  origem text not null default 'campo' check (origem in ('campo', 'importacao')),
  criado_por uuid not null references public.usuarios (id),
  criado_em_dispositivo timestamptz,
  dispositivo_id text,
  recebido_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists salas_nome_norm_ix on public.salas (nome_norm);
create index if not exists salas_atualizado_ix on public.salas (atualizado_em);

-- CPF e matrícula: tabela à parte, só admin lê; os celulares nunca baixam
create table if not exists public.salas_responsavel_pessoal (
  sala_id uuid primary key references public.salas (id),
  cpf text not null default '',
  matricula text not null default '',
  usuario_id uuid not null references public.usuarios (id),
  recebido_em timestamptz not null default now()
);

create table if not exists public.bens (
  id uuid primary key,                                  -- gerado no celular
  sala_id uuid not null references public.salas (id),
  tipo_bem text not null default '',
  tipo_bem_outro text not null default '',
  descricao text not null default '',
  item_material text not null default '',
  descricao_origem text not null default '',
  marca text not null default '',
  fornecedor text not null default '',
  observacao text not null default '',
  etiquetado_em_campo boolean not null default false,
  codigo_provisorio text,                               -- SEM-<sigla>-nnnn (não é único; as repetições aparecem em v_duplicidades_provisorio, migração 003)
  situacao text not null default 'ativo' check (situacao in ('ativo', 'anulado')),
  motivo_anulacao text,
  anulado_por uuid references public.usuarios (id),
  anulado_em timestamptz,
  restaurado_por uuid references public.usuarios (id),
  restaurado_em timestamptz,
  usuario_id uuid not null references public.usuarios (id),
  registrado_em timestamptz,                            -- hora do celular
  recebido_em timestamptz not null default now(),       -- hora do servidor
  dispositivo_id text,
  atualizado_em timestamptz not null default now()
);
create index if not exists bens_sala_ix on public.bens (sala_id);
create index if not exists bens_usuario_ix on public.bens (usuario_id);
create index if not exists bens_atualizado_ix on public.bens (atualizado_em);
create index if not exists bens_prov_ix on public.bens (codigo_provisorio) where codigo_provisorio is not null;

create table if not exists public.etiquetas (
  id uuid primary key,                                  -- gerado no celular
  bem_id uuid not null references public.bens (id),
  numero text not null,
  numero_normalizado text not null,
  serie text not null default 'outra' check (serie in ('curto', 'longo', 'outra')),
  origem text not null default 'manual',
  simbologia text not null default '',
  alerta_formato text,
  usuario_id uuid not null references public.usuarios (id),
  registrado_em timestamptz,
  recebido_em timestamptz not null default now(),
  dispositivo_id text
);
create index if not exists etiquetas_bem_ix on public.etiquetas (bem_id);
create index if not exists etiquetas_num_ix on public.etiquetas (numero_normalizado, serie);
create index if not exists etiquetas_recebido_ix on public.etiquetas (recebido_em);

create table if not exists public.resolucoes_duplicidade (
  id uuid primary key default gen_random_uuid(),
  numero_normalizado text not null,
  serie text,
  bem_valido_id uuid references public.bens (id),
  decisao text not null,
  observacao text,
  resolvido_por uuid not null references public.usuarios (id),
  em timestamptz not null default now()
);

create table if not exists public.auditoria (
  id uuid primary key default gen_random_uuid(),
  em timestamptz not null default now(),
  usuario_id uuid references public.usuarios (id),
  acao text not null,
  entidade text,
  entidade_id text,
  detalhe jsonb,
  dispositivo_id text
);
create index if not exists auditoria_em_ix on public.auditoria (em desc);

drop trigger if exists tg_usuarios_upd on public.usuarios;
create trigger tg_usuarios_upd before update on public.usuarios for each row execute function public.tg_atualizado_em();
drop trigger if exists tg_localidades_upd on public.localidades;
create trigger tg_localidades_upd before update on public.localidades for each row execute function public.tg_atualizado_em();
drop trigger if exists tg_tipos_upd on public.tipos_bem;
create trigger tg_tipos_upd before update on public.tipos_bem for each row execute function public.tg_atualizado_em();
drop trigger if exists tg_desc_upd on public.descricoes_bem;
create trigger tg_desc_upd before update on public.descricoes_bem for each row execute function public.tg_atualizado_em();
drop trigger if exists tg_salas_upd on public.salas;
create trigger tg_salas_upd before update on public.salas for each row execute function public.tg_atualizado_em();
drop trigger if exists tg_bens_upd on public.bens;
create trigger tg_bens_upd before update on public.bens for each row execute function public.tg_atualizado_em();

-- =====================================================================================================
-- Funções de permissão (security definer: não dependem do RLS de usuarios, sem recursão)
-- =====================================================================================================
create or replace function public.eh_ativo() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.usuarios u where u.id = auth.uid() and u.ativo)
$$;

create or replace function public.eh_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.usuarios u where u.id = auth.uid() and u.ativo and u.papel = 'admin')
$$;

-- =====================================================================================================
-- Permissões: sem DELETE para ninguém; anon não acessa nada
-- =====================================================================================================
revoke all on all tables in schema public from anon;
revoke all on all tables in schema public from authenticated;
revoke all on all functions in schema public from anon;

grant select, insert, update on
  public.usuarios, public.localidades, public.tipos_bem, public.descricoes_bem, public.salas,
  public.salas_responsavel_pessoal, public.bens, public.etiquetas, public.resolucoes_duplicidade
to authenticated;
grant select, insert on public.auditoria to authenticated;

-- =====================================================================================================
-- RLS
-- =====================================================================================================
alter table public.usuarios enable row level security;
alter table public.localidades enable row level security;
alter table public.tipos_bem enable row level security;
alter table public.descricoes_bem enable row level security;
alter table public.salas enable row level security;
alter table public.salas_responsavel_pessoal enable row level security;
alter table public.bens enable row level security;
alter table public.etiquetas enable row level security;
alter table public.resolucoes_duplicidade enable row level security;
alter table public.auditoria enable row level security;

-- usuarios: todo usuário ativo lê (nomes/siglas); o próprio usuário sempre lê a própria linha (mesmo desativado).
-- Criação só pela função criar_perfil; alteração (papel, ativo, nome, sigla) só admin.
drop policy if exists usuarios_select on public.usuarios;
create policy usuarios_select on public.usuarios for select to authenticated
  using (id = auth.uid() or public.eh_ativo());
drop policy if exists usuarios_update on public.usuarios;
create policy usuarios_update on public.usuarios for update to authenticated
  using (public.eh_admin()) with check (public.eh_admin());

-- listas: todos os ativos leem; só admin altera
drop policy if exists localidades_select on public.localidades;
create policy localidades_select on public.localidades for select to authenticated using (public.eh_ativo());
drop policy if exists localidades_insert on public.localidades;
create policy localidades_insert on public.localidades for insert to authenticated with check (public.eh_admin());
drop policy if exists localidades_update on public.localidades;
create policy localidades_update on public.localidades for update to authenticated using (public.eh_admin()) with check (public.eh_admin());

drop policy if exists tipos_select on public.tipos_bem;
create policy tipos_select on public.tipos_bem for select to authenticated using (public.eh_ativo());
drop policy if exists tipos_insert on public.tipos_bem;
create policy tipos_insert on public.tipos_bem for insert to authenticated with check (public.eh_admin());
drop policy if exists tipos_update on public.tipos_bem;
create policy tipos_update on public.tipos_bem for update to authenticated using (public.eh_admin()) with check (public.eh_admin());

drop policy if exists desc_select on public.descricoes_bem;
create policy desc_select on public.descricoes_bem for select to authenticated using (public.eh_ativo());
drop policy if exists desc_insert on public.descricoes_bem;
create policy desc_insert on public.descricoes_bem for insert to authenticated with check (public.eh_admin());
drop policy if exists desc_update on public.descricoes_bem;
create policy desc_update on public.descricoes_bem for update to authenticated using (public.eh_admin()) with check (public.eh_admin());

-- salas: ativos leem e inserem (criado_por = eu); só admin altera
drop policy if exists salas_select on public.salas;
create policy salas_select on public.salas for select to authenticated using (public.eh_ativo());
drop policy if exists salas_insert on public.salas;
create policy salas_insert on public.salas for insert to authenticated
  with check (public.eh_ativo() and criado_por = auth.uid());
drop policy if exists salas_update on public.salas;
create policy salas_update on public.salas for update to authenticated using (public.eh_admin()) with check (public.eh_admin());

-- CPF/matrícula: coletor só insere (usuario_id = eu); só admin lê e altera
drop policy if exists srp_select on public.salas_responsavel_pessoal;
create policy srp_select on public.salas_responsavel_pessoal for select to authenticated using (public.eh_admin());
drop policy if exists srp_insert on public.salas_responsavel_pessoal;
create policy srp_insert on public.salas_responsavel_pessoal for insert to authenticated
  with check (public.eh_ativo() and usuario_id = auth.uid());
drop policy if exists srp_update on public.salas_responsavel_pessoal;
create policy srp_update on public.salas_responsavel_pessoal for update to authenticated using (public.eh_admin()) with check (public.eh_admin());

-- bens e etiquetas: ativos leem; inserem só com usuario_id = eu; só admin altera diretamente
-- (anulação pelo dono passa pela função sincronizar_lote)
drop policy if exists bens_select on public.bens;
create policy bens_select on public.bens for select to authenticated using (public.eh_ativo());
drop policy if exists bens_insert on public.bens;
create policy bens_insert on public.bens for insert to authenticated
  with check (public.eh_ativo() and usuario_id = auth.uid());
drop policy if exists bens_update on public.bens;
create policy bens_update on public.bens for update to authenticated using (public.eh_admin()) with check (public.eh_admin());

drop policy if exists etq_select on public.etiquetas;
create policy etq_select on public.etiquetas for select to authenticated using (public.eh_ativo());
drop policy if exists etq_insert on public.etiquetas;
create policy etq_insert on public.etiquetas for insert to authenticated
  with check (public.eh_ativo() and usuario_id = auth.uid());

-- resoluções: só admin
drop policy if exists res_select on public.resolucoes_duplicidade;
create policy res_select on public.resolucoes_duplicidade for select to authenticated using (public.eh_admin());
drop policy if exists res_insert on public.resolucoes_duplicidade;
create policy res_insert on public.resolucoes_duplicidade for insert to authenticated
  with check (public.eh_admin() and resolvido_por = auth.uid());

-- auditoria: admin lê; ativos inserem só em nome próprio
drop policy if exists aud_select on public.auditoria;
create policy aud_select on public.auditoria for select to authenticated using (public.eh_admin());
drop policy if exists aud_insert on public.auditoria;
create policy aud_insert on public.auditoria for insert to authenticated
  with check (public.eh_ativo() and usuario_id = auth.uid());

-- =====================================================================================================
-- Perfil
-- =====================================================================================================
create or replace function public.meu_perfil() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  if auth.uid() is null then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  select to_jsonb(u) into v from public.usuarios u where u.id = auth.uid();
  return v;                                              -- null se ainda não tem perfil
end
$$;

-- Primeiro login: nome + sigla (única). Quem não tem perfil não sincroniza.
-- O papel nasce como 'coletor'; admin é definido por você no SQL Editor (veja docs/CONFIGURACAO-SUPABASE.md).
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
    insert into public.usuarios (id, nome, sigla) values (v_uid, v_nome, v_sigla);
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'erro', 'sigla_em_uso');
  end;
  insert into public.auditoria (usuario_id, acao, entidade, entidade_id, detalhe)
    values (v_uid, 'perfil_criado', 'usuarios', v_uid::text, jsonb_build_object('sigla', v_sigla));
  select to_jsonb(u) into v from public.usuarios u where u.id = v_uid;
  return jsonb_build_object('ok', true, 'perfil', v);
end
$$;

-- =====================================================================================================
-- Sincronização: idempotente, nunca rejeita por formato ou duplicidade (só marca alerta)
--   p_lote = { dispositivo_id, salas:[...], bens:[...], etiquetas:[...], anulacoes:[...] }
--   Devolve os ids que AGORA existem no servidor. Itens cujo "pai" ainda não existe (ex.: bem sem sala)
--   voltam em "adiados" com o motivo e podem ser reenviados depois.
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
        -- sala criada agora: se já existe outra parecida, marca como possível duplicata (admin mescla na fase 2b)
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

  -- 4) anulações (dono do bem ou admin). Restaurar é só admin (fase 2b).
  for j in select * from jsonb_array_elements(coalesce(p_lote -> 'anulacoes', '[]'::jsonb)) loop
    begin
      v_bem := (j ->> 'bem_id')::uuid;
      v_em := coalesce(nullif(j ->> 'em', '')::timestamptz, now());
      select b.usuario_id, b.situacao, b.restaurado_em into v_dono, v_sit, v_rest from public.bens b where b.id = v_bem;
      if not found then
        v_adiados := v_adiados || jsonb_build_object('tabela', 'anulacoes', 'id', j ->> 'bem_id', 'motivo', 'bem_inexistente');
      elsif v_dono <> v_uid and not public.eh_admin() then
        v_adiados := v_adiados || jsonb_build_object('tabela', 'anulacoes', 'id', j ->> 'bem_id', 'motivo', 'sem_permissao');
      else
        -- uma anulação mais antiga que uma restauração do admin não desfaz a restauração
        if v_sit = 'ativo' and (v_rest is null or v_em > v_rest) then
          update public.bens
             set situacao = 'anulado', motivo_anulacao = coalesce(j ->> 'motivo', ''), anulado_por = v_uid, anulado_em = v_em
           where id = v_bem;
          insert into public.auditoria (usuario_id, acao, entidade, entidade_id, detalhe, dispositivo_id)
            values (v_uid, 'bem_anulado', 'bens', v_bem::text, jsonb_build_object('motivo', coalesce(j ->> 'motivo', '')), v_disp);
        end if;
        r_anu := r_anu || v_bem;
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
    'adiados', v_adiados);
end
$$;

-- =====================================================================================================
-- Pull: salas (sem CPF/matrícula), listas e um índice leve de números para o aviso de duplicidade.
-- Devolve tudo que mudou desde p_desde (com 2 min de folga: transações longas podem confirmar depois).
-- =====================================================================================================
create or replace function public.puxar_mudancas(p_desde timestamptz default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_desde timestamptz := coalesce(p_desde - interval '2 minutes', '-infinity'::timestamptz);
begin
  if auth.uid() is null or not public.eh_ativo() then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'agora', now(),
    'salas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'nome', s.nome, 'coordenacao', s.coordenacao, 'uorg', s.uorg, 'andar', s.andar,
        'localidade', s.localidade, 'responsavel_nome', s.responsavel_nome, 'responsavel_siorg', s.responsavel_siorg,
        'responsavel_uorg', s.responsavel_uorg, 'legado', s.legado, 'status', s.status,
        'mesclada_em_id', s.mesclada_em_id, 'origem', s.origem, 'recebido_em', s.recebido_em))
      from public.salas s where s.atualizado_em >= v_desde), '[]'::jsonb),
    'tipos', coalesce((
      select jsonb_agg(jsonb_build_object('id', t.id, 'nome', t.nome, 'ativo', t.ativo))
      from public.tipos_bem t where t.atualizado_em >= v_desde), '[]'::jsonb),
    'localidades', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'nome', l.nome, 'ativo', l.ativo))
      from public.localidades l where l.atualizado_em >= v_desde), '[]'::jsonb),
    'descricoes', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'tipo', d.tipo_nome, 'texto', d.texto,
                                          'item_material', d.item_material, 'ativo', d.ativo, 'origem', d.origem))
      from public.descricoes_bem d where d.atualizado_em >= v_desde), '[]'::jsonb),
    'indice', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id, 'bem_id', e.bem_id, 'numero', e.numero, 'numero_normalizado', e.numero_normalizado,
        'serie', e.serie, 'sala_id', b.sala_id, 'sala_nome', s.nome, 'tipo_bem', b.tipo_bem,
        'ativo', b.situacao = 'ativo', 'sigla', u.sigla, 'registrado_em', b.registrado_em))
      from public.etiquetas e
      join public.bens b on b.id = e.bem_id
      join public.salas s on s.id = b.sala_id
      join public.usuarios u on u.id = b.usuario_id
      where b.atualizado_em >= v_desde or e.recebido_em >= v_desde), '[]'::jsonb),
    -- maior número SEM-<minha sigla>-nnnn já no servidor (o app usa max(local, servidor) + 1)
    'sem_max', coalesce((
      select max((regexp_match(b.codigo_provisorio, '^SEM-' || u.sigla || '-([0-9]+)$'))[1]::bigint)
      from public.bens b join public.usuarios u on u.id = b.usuario_id
      where u.id = auth.uid() and b.codigo_provisorio is not null), 0)
  );
end
$$;

-- só usuários logados executam as funções
revoke all on function public.meu_perfil() from public, anon;
revoke all on function public.criar_perfil(text, text) from public, anon;
revoke all on function public.sincronizar_lote(jsonb) from public, anon;
revoke all on function public.puxar_mudancas(timestamptz) from public, anon;
grant execute on function public.eh_ativo() to authenticated;
grant execute on function public.eh_admin() to authenticated;
grant execute on function public.meu_perfil() to authenticated;
grant execute on function public.criar_perfil(text, text) to authenticated;
grant execute on function public.sincronizar_lote(jsonb) to authenticated;
grant execute on function public.puxar_mudancas(timestamptz) to authenticated;

-- =====================================================================================================
-- Views (security_invoker: respeitam o RLS de quem consulta)
-- =====================================================================================================
-- Números repetidos entre bens ativos.
--   mesma_serie: mesmo número e mesma série em bens diferentes (conflito)
--   outra_serie: mesmo número em séries diferentes (aviso leve)
create or replace view public.v_duplicidades with (security_invoker = true) as
with ativos as (
  select e.numero_normalizado, e.serie, e.bem_id, b.sala_id
  from public.etiquetas e join public.bens b on b.id = e.bem_id
  where b.situacao = 'ativo'
)
select a.numero_normalizado, a.serie, 'mesma_serie'::text as tipo,
       count(distinct a.bem_id) as qtd_bens, count(distinct a.sala_id) as qtd_salas,
       array_agg(distinct a.bem_id) as bem_ids, array_agg(distinct a.sala_id) as sala_ids,
       exists (select 1 from public.resolucoes_duplicidade r
               where r.numero_normalizado = a.numero_normalizado and r.serie = a.serie) as resolvida
from ativos a
group by a.numero_normalizado, a.serie
having count(distinct a.bem_id) > 1
union all
select a.numero_normalizado, null::text, 'outra_serie'::text,
       count(distinct a.bem_id), count(distinct a.sala_id),
       array_agg(distinct a.bem_id), array_agg(distinct a.sala_id),
       exists (select 1 from public.resolucoes_duplicidade r
               where r.numero_normalizado = a.numero_normalizado and r.serie is null) as resolvida
from ativos a
group by a.numero_normalizado
having count(distinct a.serie) > 1 and count(distinct a.bem_id) > 1;

-- Uma linha por bem, já com a sala FINAL (se a sala foi mesclada, usa a sala de destino).
-- Não traz CPF nem matrícula.
create or replace view public.v_exportacao with (security_invoker = true) as
select
  b.id as id_bem,
  (select string_agg(e.numero, ' | ' order by e.registrado_em) from public.etiquetas e where e.bem_id = b.id and e.serie = 'curto') as patrimonio_curto,
  (select string_agg(e.numero, ' | ' order by e.registrado_em) from public.etiquetas e where e.bem_id = b.id and e.serie = 'longo') as patrimonio_longo,
  (select string_agg(e.numero, ' | ' order by e.registrado_em) from public.etiquetas e where e.bem_id = b.id and e.serie = 'outra') as patrimonio_outro,
  b.codigo_provisorio, b.etiquetado_em_campo,
  b.tipo_bem, b.tipo_bem_outro, b.descricao, b.item_material, b.marca, b.fornecedor,
  sf.coordenacao, sf.uorg as uorg_sala, sf.andar, sf.localidade, sf.nome as sala,
  sf.legado as legado_niveis_org, sf.responsavel_siorg, sf.responsavel_uorg,
  b.observacao,
  (select string_agg(e.alerta_formato, ' | ') from public.etiquetas e where e.bem_id = b.id and e.alerta_formato is not null) as alerta_formato,
  b.situacao, b.motivo_anulacao,
  u.sigla as sigla_usuario, u.nome as registrado_por,
  b.registrado_em, b.recebido_em
from public.bens b
join public.salas s on s.id = b.sala_id
join public.salas sf on sf.id = coalesce(s.mesclada_em_id, s.id)
join public.usuarios u on u.id = b.usuario_id;

grant select on public.v_duplicidades, public.v_exportacao to authenticated;

-- =====================================================================================================
-- Listas iniciais (o admin edita na fase 2b)
-- =====================================================================================================
insert into public.tipos_bem (nome, nome_norm)
select n, public.norm_texto(n) from unnest(array[
  'MONITOR','POLTRONA','MESA','MICROCOMPUTADOR','GAVETEIRO','ARMARIO','NOTEBOOK','CADEIRA','SOFA','EQUIPAMENTO','CAMERA',
  'TELEVISOR','REFRIGERADOR','UMIDIFICADOR','PROJETOR','WORKSTATION','FORNO','TELA DE PROJECAO','AR CONDICIONADO','FILTRO',
  'SERVIDOR','MICRO-ONDAS','MAQUINA','RECEPTOR','CAIXA','CONDICIONADOR','SWITCH','BEBEDOURO','FRAGMENTADORA','SUPORTE',
  'IMPRESSORA','CAFETEIRA','QUADRO','TAPETE']) as n
on conflict (nome_norm) do nothing;

insert into public.localidades (nome, nome_norm)
select n, public.norm_texto(n) from unnest(array['Prédio Central', 'Anexo']) as n
on conflict (nome_norm) do nothing;
