-- Testes de permissão (RLS) — rode no SQL Editor do Supabase, DEPOIS das migrações 001, 002 e 003.
-- (T1 a T6 valem desde a 002; T7 e T8 exigem a 003.)
--
-- O SQL Editor roda como "postgres" (ignora o RLS). Os blocos abaixo trocam para o papel "anon" ou
-- "authenticated" com `set local role` e simulam o login definindo o `sub` do JWT.
--
-- Antes de começar:
--   * crie 2 coletores em Authentication > Users e faça cada um entrar uma vez no app (cria o perfil);
--   * troque <UUID_COLETOR_A> e <UUID_COLETOR_B> pelos ids deles (coluna "UID" em Authentication > Users)
--     EM TODOS OS BLOCOS (use "localizar e substituir").
--
-- Cada teste imprime PASSOU ou FALHOU em "Messages". Tudo roda em transações que terminam em ROLLBACK:
-- nada fica gravado (inclusive a preparação dos usuários abaixo).

-- ---------- T1: anônimo (sem login) não lê nem executa nada ----------
begin;
set local role anon;
do $$
declare n int;
begin
  begin
    select count(*) into n from public.bens;
    raise notice 'T1a FALHOU: anon conseguiu ler bens';
  exception when insufficient_privilege then
    raise notice 'T1a PASSOU: anon não lê bens';
  end;
  begin
    perform public.sincronizar_lote('{}'::jsonb);
    raise notice 'T1b FALHOU: anon executou sincronizar_lote';
  exception when insufficient_privilege then
    raise notice 'T1b PASSOU: anon não executa sincronizar_lote';
  end;
  begin
    perform public.puxar_mudancas(null);
    raise notice 'T1c FALHOU: anon executou puxar_mudancas';
  exception when insufficient_privilege then
    raise notice 'T1c PASSOU: anon não executa puxar_mudancas';
  end;
  begin
    perform public.criar_perfil('X', 'XX');
    raise notice 'T1d FALHOU: anon executou criar_perfil';
  exception when insufficient_privilege then
    raise notice 'T1d PASSOU: anon não executa criar_perfil';
  end;
end
$$;
rollback;

-- ---------- T2: logado SEM perfil não lê nem sincroniza ----------
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000dead","role":"authenticated"}', true);
do $$
declare n int;
begin
  select count(*) into n from public.bens;
  if n = 0 then raise notice 'T2a PASSOU: sem perfil não enxerga bens'; else raise notice 'T2a FALHOU: viu % bens', n; end if;
  begin
    perform public.sincronizar_lote('{}'::jsonb);
    raise notice 'T2b FALHOU: sem perfil conseguiu sincronizar';
  exception when others then
    if sqlerrm = 'sem_permissao' then raise notice 'T2b PASSOU: sem perfil não sincroniza';
    else raise notice 'T2b FALHOU: erro inesperado: %', sqlerrm; end if;
  end;
end
$$;
rollback;

-- ---------- T3: coletor ativo: sincroniza, é idempotente, não apaga, não vê CPF ----------
begin;
-- preparação (como postgres, desfeita no rollback): perfis ativos e com a senha já trocada
update public.usuarios set ativo = true, deve_trocar_senha = false where id in ('<UUID_COLETOR_A>', '<UUID_COLETOR_B>');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"<UUID_COLETOR_A>","role":"authenticated"}', true);
do $$
declare
  r1 jsonb; r2 jsonb; n int;
  v_sala uuid := gen_random_uuid();
  v_bem uuid := gen_random_uuid();
  v_etq uuid := gen_random_uuid();
  lote jsonb;
begin
  -- CPF sintético de teste (não pertence a ninguém)
  lote := jsonb_build_object(
    'dispositivo_id', 'teste-rls',
    'salas', jsonb_build_array(jsonb_build_object('id', v_sala, 'nome', 'Sala TESTE', 'coordenacao', 'COORD-DEMO',
              'responsavel_cpf', '52998224725', 'responsavel_matricula', '0042')),
    'bens', jsonb_build_array(jsonb_build_object('id', v_bem, 'sala_id', v_sala, 'tipo_bem', 'MESA')),
    'etiquetas', jsonb_build_array(jsonb_build_object('id', v_etq, 'bem_id', v_bem, 'numero', '123', 'serie', 'curto')));
  r1 := public.sincronizar_lote(lote);
  r2 := public.sincronizar_lote(lote);                         -- reenvio idêntico
  select count(*) into n from public.bens where id = v_bem;
  if n = 1 then raise notice 'T3a PASSOU: reenvio não duplica'; else raise notice 'T3a FALHOU: % bens', n; end if;
  if r2 -> 'bens' = r1 -> 'bens' then raise notice 'T3b PASSOU: reenvio devolve os mesmos ids'; else raise notice 'T3b FALHOU'; end if;
  select count(*) into n from public.etiquetas where id = v_etq and alerta_formato is not null;
  if n = 1 then raise notice 'T3c PASSOU: formato fora do padrão só gera alerta (não rejeita)'; else raise notice 'T3c FALHOU'; end if;
  select count(*) into n from public.salas_responsavel_pessoal;
  if n = 0 then raise notice 'T3d PASSOU: coletor não lê CPF/matrícula'; else raise notice 'T3d FALHOU: viu % linhas', n; end if;
  begin
    delete from public.bens where id = v_bem;
    raise notice 'T3e FALHOU: coletor conseguiu DELETE';
  exception when insufficient_privilege then
    raise notice 'T3e PASSOU: DELETE negado';
  end;
  begin
    update public.bens set marca = 'X' where id = v_bem;
    get diagnostics n = row_count;
    if n = 0 then raise notice 'T3f PASSOU: coletor não altera bens direto (0 linhas)'; else raise notice 'T3f FALHOU: alterou % linhas', n; end if;
  exception when insufficient_privilege then
    raise notice 'T3f PASSOU: UPDATE direto negado';
  end;
  begin
    update public.usuarios set papel = 'admin' where id = '<UUID_COLETOR_A>';
    get diagnostics n = row_count;
    if n = 0 then raise notice 'T3g PASSOU: coletor não vira admin (0 linhas)'; else raise notice 'T3g FALHOU: mudou o próprio papel'; end if;
  exception when insufficient_privilege then
    raise notice 'T3g PASSOU: UPDATE em usuarios negado';
  end;
end
$$;
rollback;

-- ---------- T4: mesmo número em dois bens/usuários: aceita os dois e sinaliza ----------
begin;
update public.usuarios set ativo = true, deve_trocar_senha = false where id in ('<UUID_COLETOR_A>', '<UUID_COLETOR_B>');
do $$
declare
  v_a uuid := '<UUID_COLETOR_A>'; v_b uuid := '<UUID_COLETOR_B>';
  v_sala uuid := gen_random_uuid(); b1 uuid := gen_random_uuid(); b2 uuid := gen_random_uuid();
  n int;
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform public.sincronizar_lote(jsonb_build_object('salas', jsonb_build_array(jsonb_build_object('id', v_sala, 'nome', 'S-T4')),
    'bens', jsonb_build_array(jsonb_build_object('id', b1, 'sala_id', v_sala, 'tipo_bem', 'MESA')),
    'etiquetas', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'bem_id', b1, 'numero', '01888', 'serie', 'curto'))));
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform public.sincronizar_lote(jsonb_build_object(
    'bens', jsonb_build_array(jsonb_build_object('id', b2, 'sala_id', v_sala, 'tipo_bem', 'CADEIRA')),
    'etiquetas', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'bem_id', b2, 'numero', '01888', 'serie', 'curto'))));
  select count(*) into n from public.v_duplicidades where numero_normalizado = '01888' and tipo = 'mesma_serie' and qtd_bens = 2;
  if n = 1 then raise notice 'T4 PASSOU: os dois bens foram aceitos e v_duplicidades sinaliza'; else raise notice 'T4 FALHOU (n=%)', n; end if;
end
$$;
rollback;

-- ---------- T5 (A-4): escrita DIRETA pela API é negada; só o RPC escreve ----------
-- Inclui o caso da auditoria: coletor A tentando anexar etiqueta a bem do coletor B.
begin;
update public.usuarios set ativo = true, deve_trocar_senha = false where id in ('<UUID_COLETOR_A>', '<UUID_COLETOR_B>');
do $$
declare
  v_a uuid := '<UUID_COLETOR_A>'; v_b uuid := '<UUID_COLETOR_B>';
  v_sala uuid := gen_random_uuid(); bem_b uuid := gen_random_uuid();
begin
  -- B cria um bem pelo RPC
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform public.sincronizar_lote(jsonb_build_object('salas', jsonb_build_array(jsonb_build_object('id', v_sala, 'nome', 'S-T5')),
    'bens', jsonb_build_array(jsonb_build_object('id', bem_b, 'sala_id', v_sala, 'tipo_bem', 'MESA'))));
  -- A tenta escrever direto
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  begin
    insert into public.etiquetas (id, bem_id, numero, numero_normalizado, usuario_id)
      values (gen_random_uuid(), bem_b, '999', 'X', v_a);
    raise notice 'T5a FALHOU: A inseriu etiqueta direto em bem de B';
  exception when insufficient_privilege then
    raise notice 'T5a PASSOU: INSERT direto em etiquetas negado';
  end;
  begin
    insert into public.bens (id, sala_id, usuario_id) values (gen_random_uuid(), v_sala, v_a);
    raise notice 'T5b FALHOU: INSERT direto em bens aceito';
  exception when insufficient_privilege then
    raise notice 'T5b PASSOU: INSERT direto em bens negado';
  end;
  begin
    insert into public.salas (id, nome, nome_norm, criado_por) values (gen_random_uuid(), 'X', 'x', v_a);
    raise notice 'T5c FALHOU: INSERT direto em salas aceito';
  exception when insufficient_privilege then
    raise notice 'T5c PASSOU: INSERT direto em salas negado';
  end;
  begin
    insert into public.salas_responsavel_pessoal (sala_id, cpf, usuario_id) values (v_sala, '11111111111', v_a);
    raise notice 'T5d FALHOU: INSERT direto em CPF/matrícula aceito';
  exception when insufficient_privilege then
    raise notice 'T5d PASSOU: INSERT direto em CPF/matrícula negado';
  end;
  begin
    insert into public.auditoria (usuario_id, acao) values (v_a, 'lixo');
    raise notice 'T5e FALHOU: INSERT direto em auditoria aceito';
  exception when insufficient_privilege then
    raise notice 'T5e PASSOU: INSERT direto em auditoria negado';
  end;
  -- e o RPC continua recusando etiqueta em bem alheio
  declare r jsonb;
  begin
    r := public.sincronizar_lote(jsonb_build_object('etiquetas', jsonb_build_array(
           jsonb_build_object('id', gen_random_uuid(), 'bem_id', bem_b, 'numero', '999', 'serie', 'outra'))));
    if jsonb_array_length(r -> 'etiquetas') = 0 and r::text like '%bem_de_outro_usuario%'
      then raise notice 'T5f PASSOU: RPC recusa etiqueta em bem de outro usuário';
      else raise notice 'T5f FALHOU: %', r; end if;
  end;
end
$$;
rollback;

-- ---------- T6 (M-1): anulação mais antiga que a restauração do admin NÃO é confirmada ----------
begin;
update public.usuarios set ativo = true, deve_trocar_senha = false where id in ('<UUID_COLETOR_A>', '<UUID_COLETOR_B>');
do $$
declare
  v_a uuid := '<UUID_COLETOR_A>';
  v_sala uuid := gen_random_uuid(); v_bem uuid := gen_random_uuid();
  r jsonb; sit text;
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform public.sincronizar_lote(jsonb_build_object('salas', jsonb_build_array(jsonb_build_object('id', v_sala, 'nome', 'S-T6')),
    'bens', jsonb_build_array(jsonb_build_object('id', v_bem, 'sala_id', v_sala, 'tipo_bem', 'MESA'))));
  -- simula "admin restaurou agora" (como postgres)
  perform set_config('role', 'postgres', true);
  update public.bens set restaurado_em = now() where id = v_bem;
  perform set_config('role', 'authenticated', true);
  -- o celular reenvia uma anulação feita ANTES da restauração
  r := public.sincronizar_lote(jsonb_build_object('anulacoes', jsonb_build_array(
         jsonb_build_object('bem_id', v_bem, 'motivo', 'teste', 'em', (now() - interval '1 hour')))));
  select situacao into sit from public.bens where id = v_bem;
  if sit = 'ativo' and jsonb_array_length(r -> 'anulacoes') = 0 and jsonb_array_length(r -> 'anulacoes_ignoradas') = 1
    then raise notice 'T6 PASSOU: anulação antiga ignorada e NÃO confirmada (vem em anulacoes_ignoradas)';
    else raise notice 'T6 FALHOU: situacao=%, resposta=%', sit, r; end if;
end
$$;
rollback;

-- ---------- T7 (M-6, migração 003): pull paginado ----------
begin;
update public.usuarios set ativo = true, deve_trocar_senha = false where id in ('<UUID_COLETOR_A>', '<UUID_COLETOR_B>');
do $$
declare
  v_a uuid := '<UUID_COLETOR_A>';
  v_sala uuid := gen_random_uuid(); v_bem uuid := gen_random_uuid();
  r jsonb; r2 jsonb; r3 jsonb; vistos int := 0; ultimo uuid := null; mais boolean := true; voltas int := 0;
begin
  -- anon não executa
  perform set_config('role', 'anon', true);
  begin
    perform public.puxar_pagina('tipos');
    raise notice 'T7a FALHOU: anon executou puxar_pagina';
  exception when insufficient_privilege then
    raise notice 'T7a PASSOU: anon não executa puxar_pagina';
  end;
  -- o coletor A cria dados pelo RPC
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform public.sincronizar_lote(jsonb_build_object('salas', jsonb_build_array(jsonb_build_object('id', v_sala, 'nome', 'S-T7')),
    'bens', jsonb_build_array(jsonb_build_object('id', v_bem, 'sala_id', v_sala, 'tipo_bem', 'MESA')),
    'etiquetas', jsonb_build_array(
      jsonb_build_object('id', gen_random_uuid(), 'bem_id', v_bem, 'numero', 'T7-A', 'serie', 'outra'),
      jsonb_build_object('id', gen_random_uuid(), 'bem_id', v_bem, 'numero', 'T7-B', 'serie', 'outra'),
      jsonb_build_object('id', gen_random_uuid(), 'bem_id', v_bem, 'numero', 'T7-C', 'serie', 'outra'))));
  -- página de 2 itens do índice: deve haver "mais" e "ultimo"
  r := public.puxar_pagina('indice', null, null, 2);
  if jsonb_array_length(r -> 'itens') = 2 and (r ->> 'mais')::boolean and r ->> 'ultimo' is not null
    then raise notice 'T7b PASSOU: página cheia traz mais=true e ultimo';
    else raise notice 'T7b FALHOU: %', r; end if;
  -- percorrer todas as páginas de 2 em 2: a soma tem que bater com a página única grande, sem repetir nem perder
  while mais loop
    r2 := public.puxar_pagina('indice', null, ultimo, 2);
    vistos := vistos + jsonb_array_length(r2 -> 'itens');
    mais := (r2 ->> 'mais')::boolean; ultimo := (r2 ->> 'ultimo')::uuid; voltas := voltas + 1;
    exit when voltas > 100000;
  end loop;
  r3 := public.puxar_pagina('indice', null, null, 5000);
  if vistos = jsonb_array_length(r3 -> 'itens') and not (r3 ->> 'mais')::boolean
    then raise notice 'T7c PASSOU: % itens em % páginas = página única', vistos, voltas;
    else raise notice 'T7c FALHOU: paginado=% único=% (mais=%)', vistos, jsonb_array_length(r3 -> 'itens'), r3 ->> 'mais'; end if;
  -- as salas e os tipos também respondem; o pull de salas não traz CPF
  r := public.puxar_pagina('salas', null, null, 5000);
  if r::text !~ 'cpf' and r::text !~ 'matricula' then raise notice 'T7d PASSOU: pull de salas sem CPF/matrícula'; else raise notice 'T7d FALHOU'; end if;
  begin
    perform public.puxar_pagina('tabela_que_nao_existe');      -- ('bens' passou a ser válida com a migração 004)
    raise notice 'T7e FALHOU: aceitou tabela inválida';
  exception when others then
    if sqlerrm = 'tabela_invalida' then raise notice 'T7e PASSOU: tabela inválida recusada'; else raise notice 'T7e FALHOU: %', sqlerrm; end if;
  end;
  r := public.puxar_pagina('meta');
  if r ? 'sem_max' and r ? 'agora' then raise notice 'T7f PASSOU: meta devolve agora e sem_max'; else raise notice 'T7f FALHOU: %', r; end if;
end
$$;
rollback;

-- ---------- T8 (M-7, migração 003): código provisório repetido aparece na view ----------
begin;
update public.usuarios set ativo = true, deve_trocar_senha = false where id in ('<UUID_COLETOR_A>', '<UUID_COLETOR_B>');
do $$
declare
  v_a uuid := '<UUID_COLETOR_A>'; v_b uuid := '<UUID_COLETOR_B>';
  v_sala uuid := gen_random_uuid(); b1 uuid := gen_random_uuid(); b2 uuid := gen_random_uuid(); n int;
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform public.sincronizar_lote(jsonb_build_object('salas', jsonb_build_array(jsonb_build_object('id', v_sala, 'nome', 'S-T8')),
    'bens', jsonb_build_array(jsonb_build_object('id', b1, 'sala_id', v_sala, 'tipo_bem', 'MESA', 'codigo_provisorio', 'SEM-T8-0001', 'observacao', 'teste'))));
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform public.sincronizar_lote(jsonb_build_object(
    'bens', jsonb_build_array(jsonb_build_object('id', b2, 'sala_id', v_sala, 'tipo_bem', 'CADEIRA', 'codigo_provisorio', 'SEM-T8-0001', 'observacao', 'teste'))));
  select count(*) into n from public.v_duplicidades_provisorio where codigo_provisorio = 'SEM-T8-0001' and qtd_bens = 2;
  if n = 1 then raise notice 'T8a PASSOU: v_duplicidades_provisorio sinaliza o código repetido (os dois bens foram aceitos)';
  else raise notice 'T8a FALHOU (n=%)', n; end if;
  perform set_config('role', 'anon', true);
  begin
    select count(*) into n from public.v_duplicidades_provisorio;
    raise notice 'T8b FALHOU: anon leu a view';
  exception when insufficient_privilege then
    raise notice 'T8b PASSOU: anon não lê a view';
  end;
end
$$;
rollback;

-- ---------- T9 (migração 007): mover bens, mesclar salas e desfazer. Só admin ----------
-- Precisa da migração 007. O coletor A vira admin SÓ dentro desta transação (o rollback desfaz).
begin;
update public.usuarios set ativo = true, deve_trocar_senha = false where id in ('<UUID_COLETOR_A>', '<UUID_COLETOR_B>');
update public.usuarios set papel = 'admin' where id = '<UUID_COLETOR_A>';
do $$
declare
  v_a uuid := '<UUID_COLETOR_A>'; v_b uuid := '<UUID_COLETOR_B>';
  s1 uuid := gen_random_uuid(); s2 uuid := gen_random_uuid(); s3 uuid := gen_random_uuid();
  b1 uuid := gen_random_uuid(); b2 uuid := gen_random_uuid(); b3 uuid := gen_random_uuid();
  r jsonb; mid uuid; mid2 uuid; n int; st text; sala uuid;
begin
  -- o coletor B cria as salas e os bens pelo RPC
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform public.sincronizar_lote(jsonb_build_object(
    'salas', jsonb_build_array(jsonb_build_object('id', s1, 'nome', 'S-T9a'), jsonb_build_object('id', s2, 'nome', 'S-T9b'), jsonb_build_object('id', s3, 'nome', 'S-T9c')),
    'bens', jsonb_build_array(jsonb_build_object('id', b1, 'sala_id', s1, 'tipo_bem', 'MESA'), jsonb_build_object('id', b2, 'sala_id', s1, 'tipo_bem', 'CADEIRA'), jsonb_build_object('id', b3, 'sala_id', s2, 'tipo_bem', 'MESA'))));

  -- T9a: coletor (B) não executa nenhuma das quatro funções
  begin perform public.mover_bens(array[b1], s2); raise notice 'T9a FALHOU: coletor moveu bem';
  exception when others then if sqlerrm = 'sem_permissao' then raise notice 'T9a PASSOU: coletor não move bens'; else raise notice 'T9a FALHOU: %', sqlerrm; end if; end;
  begin perform public.mesclar_salas(s1, s2); raise notice 'T9b FALHOU: coletor mesclou salas';
  exception when others then if sqlerrm = 'sem_permissao' then raise notice 'T9b PASSOU: coletor não mescla salas'; else raise notice 'T9b FALHOU: %', sqlerrm; end if; end;
  begin perform public.desfazer_movimento(gen_random_uuid()); raise notice 'T9c FALHOU: coletor desfez movimento';
  exception when others then if sqlerrm = 'sem_permissao' then raise notice 'T9c PASSOU: coletor não desfaz'; else raise notice 'T9c FALHOU: %', sqlerrm; end if; end;
  begin perform public.listar_movimentos(); raise notice 'T9d FALHOU: coletor listou movimentos';
  exception when others then if sqlerrm = 'sem_permissao' then raise notice 'T9d PASSOU: coletor não lista movimentos'; else raise notice 'T9d FALHOU: %', sqlerrm; end if; end;
  -- anon
  perform set_config('role', 'anon', true);
  begin perform public.mover_bens(array[b1], s2); raise notice 'T9e FALHOU: anon executou mover_bens';
  exception when insufficient_privilege then raise notice 'T9e PASSOU: anon não executa mover_bens'; end;

  -- o administrador (A)
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  r := public.mover_bens(array[b1, b2], s2);
  mid := (r ->> 'movimento_id')::uuid;
  select count(*) into n from public.bens where id in (b1, b2) and sala_id = s2;
  if (r ->> 'ok')::boolean and (r ->> 'movidos')::int = 2 and n = 2 then raise notice 'T9f PASSOU: admin move 2 bens'; else raise notice 'T9f FALHOU: % (n=%)', r, n; end if;
  r := public.mover_bens(array[b1, b2], s2);
  if (r ->> 'ok')::boolean and (r ->> 'movidos')::int = 0 then raise notice 'T9g PASSOU: mover para a sala em que já estão não faz nada'; else raise notice 'T9g FALHOU: %', r; end if;
  r := public.mover_bens(array[b1], gen_random_uuid());
  if r ->> 'erro' = 'sala_inexistente' then raise notice 'T9h PASSOU: destino inexistente recusado'; else raise notice 'T9h FALHOU: %', r; end if;
  r := public.desfazer_movimento(mid);
  select count(*) into n from public.bens where id in (b1, b2) and sala_id = s1;
  if (r ->> 'ok')::boolean and (r ->> 'restaurados')::int = 2 and n = 2 then raise notice 'T9i PASSOU: desfazer devolve os 2 bens'; else raise notice 'T9i FALHOU: % (n=%)', r, n; end if;
  r := public.desfazer_movimento(mid);
  if r ->> 'erro' = 'ja_desfeito' then raise notice 'T9j PASSOU: desfazer duas vezes é recusado'; else raise notice 'T9j FALHOU: %', r; end if;
  -- desfazer conservador: b1 vai para s2 e depois para s3; desfazer o 1º movimento NÃO mexe no b1
  r := public.mover_bens(array[b1], s2); mid := (r ->> 'movimento_id')::uuid;
  perform public.mover_bens(array[b1], s3);
  r := public.desfazer_movimento(mid);
  select sala_id into sala from public.bens where id = b1;
  if (r ->> 'pulados')::int = 1 and sala = s3 then raise notice 'T9k PASSOU: bem movido de novo não é puxado de volta'; else raise notice 'T9k FALHOU: % (sala=%)', r, sala; end if;

  -- mesclar s1 (b2) em s2 (b3 e antigos)
  r := public.mesclar_salas(s1, s2); mid := (r ->> 'movimento_id')::uuid;
  select status into st from public.salas where id = s1;
  select count(*) into n from public.bens where sala_id = s1;
  if (r ->> 'ok')::boolean and st = 'mesclada' and n = 0 and (select mesclada_em_id from public.salas where id = s1) = s2
    then raise notice 'T9l PASSOU: mesclar move os bens e marca a origem como mesclada'; else raise notice 'T9l FALHOU: % (st=%, n=%)', r, st, n; end if;
  r := public.mesclar_salas(s3, s1);
  if r ->> 'erro' = 'destino_mesclado' then raise notice 'T9m PASSOU: mesclar em sala já mesclada é recusado'; else raise notice 'T9m FALHOU: %', r; end if;
  r := public.mesclar_salas(s2, s2);
  if r ->> 'erro' = 'salas_invalidas' then raise notice 'T9n PASSOU: mesclar sala nela mesma é recusado'; else raise notice 'T9n FALHOU: %', r; end if;
  r := public.desfazer_movimento(mid);
  select status into st from public.salas where id = s1;
  select count(*) into n from public.bens where sala_id = s1;
  if (r ->> 'ok')::boolean and st <> 'mesclada' and n = 1 then raise notice 'T9o PASSOU: desfazer a mesclagem reativa a sala e devolve o bem'; else raise notice 'T9o FALHOU: % (st=%, n=%)', r, st, n; end if;
  select count(*) into n from public.auditoria where acao in ('bens_movidos', 'salas_mescladas', 'movimento_desfeito') and usuario_id = v_a;
  if n >= 6 then raise notice 'T9p PASSOU: movimentos e desfazeres ficam na auditoria (%)', n; else raise notice 'T9p FALHOU: só % registros', n; end if;
  r := public.listar_movimentos(10);
  if jsonb_array_length(r) >= 4 then raise notice 'T9q PASSOU: admin lista os movimentos'; else raise notice 'T9q FALHOU: %', r; end if;
end
$$;
rollback;

-- ---------- T10 (migração 008): exportar_bens_pagina. Só admin; pessoais só quando pedido; auditoria só na 1ª página ----------
begin;
update public.usuarios set ativo = true, deve_trocar_senha = false where id in ('<UUID_COLETOR_A>', '<UUID_COLETOR_B>');
update public.usuarios set papel = 'admin' where id = '<UUID_COLETOR_A>';
do $$
declare
  v_a uuid := '<UUID_COLETOR_A>'; v_b uuid := '<UUID_COLETOR_B>';
  s uuid := gen_random_uuid(); b1 uuid := gen_random_uuid(); b2 uuid := gen_random_uuid(); b3 uuid := gen_random_uuid();
  r jsonb; txt text; n0 int; n1 int; vistos int := 0; ultimo uuid := null; mais boolean := true; voltas int := 0; r2 jsonb;
begin
  -- o coletor B cria uma sala (com responsável, CPF e matrícula) e 3 bens com etiqueta
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform public.sincronizar_lote(jsonb_build_object(
    'salas', jsonb_build_array(jsonb_build_object('id', s, 'nome', 'S-T10', 'responsavel_nome', 'RESP T10', 'responsavel_cpf', '52998224725', 'responsavel_matricula', '0042')),
    'bens', jsonb_build_array(jsonb_build_object('id', b1, 'sala_id', s, 'tipo_bem', 'MESA'), jsonb_build_object('id', b2, 'sala_id', s, 'tipo_bem', 'CADEIRA'), jsonb_build_object('id', b3, 'sala_id', s, 'tipo_bem', 'MESA')),
    'etiquetas', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'bem_id', b1, 'numero', '01888', 'serie', 'curto'), jsonb_build_object('id', gen_random_uuid(), 'bem_id', b2, 'numero', '01889', 'serie', 'curto'))));
  begin perform public.exportar_bens_pagina(); raise notice 'T10a FALHOU: coletor exportou';
  exception when others then if sqlerrm = 'sem_permissao' then raise notice 'T10a PASSOU: coletor não exporta pelo servidor'; else raise notice 'T10a FALHOU: %', sqlerrm; end if; end;
  perform set_config('role', 'anon', true);
  begin perform public.exportar_bens_pagina(); raise notice 'T10b FALHOU: anon exportou';
  exception when insufficient_privilege then raise notice 'T10b PASSOU: anon não executa exportar_bens_pagina'; end;

  -- o administrador (A)
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  r := public.exportar_bens_pagina(null, 2, false);
  if jsonb_array_length(r -> 'itens') = 2 and (r ->> 'mais')::boolean and r ->> 'ultimo' is not null
    then raise notice 'T10c PASSOU: página cheia traz mais=true e ultimo'; else raise notice 'T10c FALHOU: %', r; end if;
  txt := public.exportar_bens_pagina(null, 2000, false)::text;
  if txt !~ '52998224725' and txt !~ 'responsavel_cpf' and txt !~ 'responsavel_matricula' and txt ~ '01888' and txt ~ 'S-T10'
    then raise notice 'T10d PASSOU: sem pessoais por padrão (traz sala e etiquetas)'; else raise notice 'T10d FALHOU'; end if;
  txt := public.exportar_bens_pagina(null, 2000, true)::text;
  if txt ~ '52998224725' and txt ~ '0042' and txt ~ 'RESP T10'
    then raise notice 'T10e PASSOU: com pessoais traz CPF, matrícula e nome'; else raise notice 'T10e FALHOU'; end if;
  -- paginar de 2 em 2 soma o mesmo que a página única, sem repetir nem perder
  while mais loop
    r2 := public.exportar_bens_pagina(ultimo, 2, false);
    vistos := vistos + jsonb_array_length(r2 -> 'itens'); mais := (r2 ->> 'mais')::boolean; ultimo := (r2 ->> 'ultimo')::uuid; voltas := voltas + 1;
    exit when voltas > 100000;
  end loop;
  r2 := public.exportar_bens_pagina(null, 2000, false);
  if vistos = jsonb_array_length(r2 -> 'itens') and not (r2 ->> 'mais')::boolean
    then raise notice 'T10f PASSOU: % bens em % páginas = página única', vistos, voltas; else raise notice 'T10f FALHOU: paginado=% único=%', vistos, jsonb_array_length(r2 -> 'itens'); end if;
  -- auditoria: só a PRIMEIRA página de cada exportação grava
  select count(*) into n0 from public.auditoria where acao = 'exportacao_servidor' and usuario_id = v_a;
  perform public.exportar_bens_pagina(null, 2, true);
  select count(*) into n1 from public.auditoria where acao = 'exportacao_servidor' and usuario_id = v_a;
  if n1 = n0 + 1 then raise notice 'T10g PASSOU: a primeira página grava na auditoria'; else raise notice 'T10g FALHOU (% -> %)', n0, n1; end if;
  perform public.exportar_bens_pagina(ultimo, 2, true);
  select count(*) into n0 from public.auditoria where acao = 'exportacao_servidor' and usuario_id = v_a;
  perform public.exportar_bens_pagina((r ->> 'ultimo')::uuid, 2, true);
  select count(*) into n1 from public.auditoria where acao = 'exportacao_servidor' and usuario_id = v_a;
  if n1 = n0 then raise notice 'T10h PASSOU: páginas seguintes não repetem o registro'; else raise notice 'T10h FALHOU'; end if;
end
$$;
rollback;

-- ---------- T11 (migração 009): listar_usuarios e alterar_usuario. Só admin; não se rebaixa/desativa; auditoria ----------
begin;
update public.usuarios set ativo = true, deve_trocar_senha = false, aprovado_em = null, papel = 'coletor' where id in ('<UUID_COLETOR_A>', '<UUID_COLETOR_B>');
update public.usuarios set papel = 'admin' where id = '<UUID_COLETOR_A>';
do $$
declare
  v_a uuid := '<UUID_COLETOR_A>'; v_b uuid := '<UUID_COLETOR_B>';
  r jsonb; j jsonb; n0 int; n1 int;
begin
  -- o coletor B não lista nem altera
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  begin perform public.listar_usuarios(); raise notice 'T11a FALHOU: coletor listou usuários';
  exception when others then if sqlerrm = 'sem_permissao' then raise notice 'T11a PASSOU: coletor não lista usuários'; else raise notice 'T11a FALHOU: %', sqlerrm; end if; end;
  begin perform public.alterar_usuario(v_a, 'desativar'); raise notice 'T11b FALHOU: coletor alterou usuário';
  exception when others then if sqlerrm = 'sem_permissao' then raise notice 'T11b PASSOU: coletor não altera usuários'; else raise notice 'T11b FALHOU: %', sqlerrm; end if; end;
  perform set_config('role', 'anon', true);
  begin perform public.listar_usuarios(); raise notice 'T11c FALHOU: anon listou usuários';
  exception when insufficient_privilege then raise notice 'T11c PASSOU: anon não executa listar_usuarios'; end;
  begin perform public.alterar_usuario(v_a, 'desativar'); raise notice 'T11d FALHOU: anon alterou usuário';
  exception when insufficient_privilege then raise notice 'T11d PASSOU: anon não executa alterar_usuario'; end;

  -- o administrador A
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  r := public.listar_usuarios();
  select x.value into j from jsonb_array_elements(r) x where x.value ->> 'id' = v_b::text;
  if jsonb_array_length(r) >= 2 and j is not null and jsonb_exists(j, 'email') and (j ->> 'papel') = 'coletor'
    then raise notice 'T11e PASSOU: admin lista usuários (com e-mail e papel)'; else raise notice 'T11e FALHOU: %', r; end if;
  if (public.alterar_usuario(v_a, 'desativar') ->> 'erro') = 'nao_em_si_mesmo'
     and (public.alterar_usuario(v_a, 'tornar_coletor') ->> 'erro') = 'nao_em_si_mesmo'
     and (public.alterar_usuario(v_a, 'exigir_troca_senha') ->> 'erro') = 'nao_em_si_mesmo'
    then raise notice 'T11f PASSOU: admin não desativa, rebaixa nem tranca a si mesmo'; else raise notice 'T11f FALHOU'; end if;
  if (public.alterar_usuario(v_b, 'apagar') ->> 'erro') = 'acao_invalida'
     and (public.alterar_usuario(gen_random_uuid(), 'ativar') ->> 'erro') = 'usuario_inexistente'
    then raise notice 'T11g PASSOU: ação inválida e usuário inexistente são recusados'; else raise notice 'T11g FALHOU'; end if;

  select count(*) into n0 from public.auditoria where acao = 'usuario_alterado' and usuario_id = v_a;
  r := public.alterar_usuario(v_b, 'desativar');
  select x.value into j from jsonb_array_elements(public.listar_usuarios()) x where x.value ->> 'id' = v_b::text;
  select count(*) into n1 from public.auditoria where acao = 'usuario_alterado' and usuario_id = v_a;
  if (r ->> 'ok')::boolean and (j ->> 'ativo')::boolean = false and n1 = n0 + 1
    then raise notice 'T11h PASSOU: admin desativa e a auditoria registra'; else raise notice 'T11h FALHOU: % %', r, j; end if;
  if (public.alterar_usuario(v_b, 'tornar_admin') ->> 'erro') = 'usuario_inativo'
    then raise notice 'T11i PASSOU: usuário inativo não vira administrador'; else raise notice 'T11i FALHOU'; end if;
  r := public.alterar_usuario(v_b, 'ativar');
  select x.value into j from jsonb_array_elements(public.listar_usuarios()) x where x.value ->> 'id' = v_b::text;
  if (r ->> 'ok')::boolean and (j ->> 'ativo')::boolean and (j ->> 'aprovado_em') is not null
    then raise notice 'T11j PASSOU: admin ativa/aprova (preenche aprovado_em)'; else raise notice 'T11j FALHOU: % %', r, j; end if;
  r := public.alterar_usuario(v_b, 'tornar_admin');
  select x.value into j from jsonb_array_elements(public.listar_usuarios()) x where x.value ->> 'id' = v_b::text;
  if (r ->> 'ok')::boolean and (j ->> 'papel') = 'admin' then raise notice 'T11k PASSOU: coletor vira administrador'; else raise notice 'T11k FALHOU: % %', r, j; end if;

  -- B, agora administrador, rebaixa A (sobra B, ativo); B não rebaixa a si mesmo
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  r := public.alterar_usuario(v_a, 'tornar_coletor');
  select x.value into j from jsonb_array_elements(public.listar_usuarios()) x where x.value ->> 'id' = v_a::text;
  if (r ->> 'ok')::boolean and (j ->> 'papel') = 'coletor' then raise notice 'T11l PASSOU: administrador rebaixa outro administrador'; else raise notice 'T11l FALHOU: % %', r, j; end if;
  if (public.alterar_usuario(v_b, 'tornar_coletor') ->> 'erro') = 'nao_em_si_mesmo'
    then raise notice 'T11m PASSOU: o último administrador não se rebaixa'; else raise notice 'T11m FALHOU'; end if;
  r := public.alterar_usuario(v_a, 'exigir_troca_senha');
  select x.value into j from jsonb_array_elements(public.listar_usuarios()) x where x.value ->> 'id' = v_a::text;
  if (r ->> 'ok')::boolean and (j ->> 'deve_trocar_senha')::boolean then raise notice 'T11n PASSOU: exige a troca de senha'; else raise notice 'T11n FALHOU: % %', r, j; end if;
  -- A, rebaixado, perde o acesso de administrador na hora
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  begin perform public.listar_usuarios(); raise notice 'T11o FALHOU: ex-admin ainda lista usuários';
  exception when others then if sqlerrm = 'sem_permissao' then raise notice 'T11o PASSOU: quem foi rebaixado perde o acesso na hora'; else raise notice 'T11o FALHOU: %', sqlerrm; end if; end;
end
$$;
rollback;

-- ---------- T12 (migração 010): catálogo legado (tabela siads_bens, nome histórico; só leitura por usuário ativo; só com plaqueta antiga) e mover_bem (coletor move UM bem) ----------
begin;
update public.usuarios set ativo = true, deve_trocar_senha = false, papel = 'coletor' where id in ('<UUID_COLETOR_A>', '<UUID_COLETOR_B>');
insert into public.siads_bens (numero_siads, plaqueta_antiga, item, descricao, item_material, antiga_repetida) values
  ('99000001', '09991', 'MONITOR', 'MONITOR DE VIDEO', '123', false),
  ('99000002', null, 'MESA', 'MESA', '456', false)
on conflict do nothing;
do $$
declare
  v_a uuid := '<UUID_COLETOR_A>'; v_b uuid := '<UUID_COLETOR_B>';
  s1 uuid := gen_random_uuid(); s2 uuid := gen_random_uuid(); s3 uuid := gen_random_uuid(); b1 uuid := gen_random_uuid();
  r jsonb; txt text; n int;
begin
  perform set_config('role', 'anon', true);
  begin perform public.listar_siads_antigas(); raise notice 'T12a FALHOU: anon leu o catálogo legado';
  exception when insufficient_privilege then raise notice 'T12a PASSOU: anon não lê o catálogo legado'; end;
  begin perform public.mover_bem(gen_random_uuid(), gen_random_uuid()); raise notice 'T12b FALHOU: anon executou mover_bem';
  exception when insufficient_privilege then raise notice 'T12b PASSOU: anon não move bens'; end;

  -- B (coletor) cria duas salas e um bem
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform public.sincronizar_lote(jsonb_build_object(
    'salas', jsonb_build_array(jsonb_build_object('id', s1, 'nome', 'S1-T12'), jsonb_build_object('id', s2, 'nome', 'S2-T12'), jsonb_build_object('id', s3, 'nome', 'S3-T12')),
    'bens', jsonb_build_array(jsonb_build_object('id', b1, 'sala_id', s1, 'tipo_bem', 'MONITOR'))));
  txt := public.listar_siads_antigas()::text;
  if txt ~ '99000001' and txt !~ '99000002' then raise notice 'T12c PASSOU: coletor lê só os bens do catálogo legado com plaqueta antiga';
  else raise notice 'T12c FALHOU: %', left(txt, 200); end if;

  -- A (OUTRO coletor) move o bem de B
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  r := public.mover_bem(b1, s2);
  select count(*) into n from public.bens where id = b1 and sala_id = s2;
  if (r ->> 'ok')::boolean and n = 1 then raise notice 'T12d PASSOU: coletor move um bem (de outro coletor)'; else raise notice 'T12d FALHOU: %', r; end if;
  if (public.mover_bem(b1, gen_random_uuid()) ->> 'erro') = 'sala_inexistente'
     and (public.mover_bem(gen_random_uuid(), s1) ->> 'erro') = 'bem_inexistente'
     and (public.mover_bem(b1, s2) ->> 'movidos')::int = 0
    then raise notice 'T12e PASSOU: sala/bem inexistente recusados; mesma sala não faz nada'; else raise notice 'T12e FALHOU'; end if;
  perform set_config('role', 'postgres', true);
  update public.salas set status = 'mesclada', mesclada_em_id = s1 where id = s3;
  perform set_config('role', 'authenticated', true);
  if (public.mover_bem(b1, s3) ->> 'erro') = 'sala_mesclada' then raise notice 'T12f PASSOU: não move para sala mesclada'; else raise notice 'T12f FALHOU'; end if;

  -- o movimento fica em movimentos_admin (o admin desfaz)
  perform set_config('role', 'postgres', true);
  select count(*) into n from public.movimentos_admin m where m.feito_por = v_a and m.dados -> 'bens' -> 0 ->> 'bem_id' = b1::text;
  if n = 1 then raise notice 'T12g PASSOU: o movimento fica registrado para desfazer'; else raise notice 'T12g FALHOU (%)', n; end if;
end
$$;
rollback;
