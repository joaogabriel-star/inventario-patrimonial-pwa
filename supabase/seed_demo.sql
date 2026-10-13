-- ==========================================================================================================
-- SEED DE DEMONSTRAÇÃO — TODOS OS DADOS SÃO FICTÍCIOS (nenhum órgão, pessoa ou patrimônio real).
-- Rode DEPOIS das migrações 001 a 010 e DEPOIS que o administrador entrou uma vez no app e foi promovido.
-- É idempotente: pode rodar de novo sem duplicar.
-- Rode cada bloco (separado por linhas "-- ===") separadamente se o editor do Supabase reclamar de texto cortado.
-- ==========================================================================================================

-- === 0) pré-requisito: precisa existir um administrador ativo ===
do $$
begin
  if not exists (select 1 from public.usuarios where papel = 'admin' and ativo) then
    raise exception 'Crie e promova o administrador antes de rodar este seed (veja o cabeçalho).';
  end if;
end
$$;

-- === 1) localidades e descrições (listas que o app usa nos formulários) ===
insert into public.localidades (nome, nome_norm)
select n, public.norm_texto(n) from unnest(array['Prédio Central', 'Anexo']) as n
on conflict (nome_norm) do nothing;

insert into public.descricoes_bem (tipo_nome, tipo_norm, texto, texto_norm, item_material, origem)
select v.tipo, public.norm_texto(v.tipo), v.texto, public.norm_texto(v.texto), v.mat, 'app'
from (values
  ('MONITOR', 'MONITOR LED 24 POLEGADAS', '100001'),
  ('MONITOR', 'MONITOR LED 27 POLEGADAS', '100002'),
  ('MICROCOMPUTADOR', 'MICROCOMPUTADOR DESKTOP', '100003'),
  ('NOTEBOOK', 'NOTEBOOK 14 POLEGADAS', '100004'),
  ('MESA', 'MESA DE TRABALHO RETA', '100005'),
  ('MESA', 'MESA DE REUNIAO OVAL', '100006'),
  ('CADEIRA', 'CADEIRA GIRATORIA COM BRACOS', '100007'),
  ('POLTRONA', 'POLTRONA DE ESPERA', '100008'),
  ('GAVETEIRO', 'GAVETEIRO VOLANTE 3 GAVETAS', '100009'),
  ('ARMARIO', 'ARMARIO ALTO COM PORTAS', '100010'),
  ('IMPRESSORA', 'IMPRESSORA MULTIFUNCIONAL LASER', '100011'),
  ('PROJETOR', 'PROJETOR MULTIMIDIA', '100012'),
  ('TELEVISOR', 'TELEVISOR LED 50 POLEGADAS', '100013'),
  ('AR CONDICIONADO', 'AR CONDICIONADO SPLIT 12000 BTU', '100014')
) as v(tipo, texto, mat)
on conflict (tipo_norm, texto_norm, item_material) do nothing;

-- === 2) salas (órgão fictício "Ministério Demo" e unidades inventadas) ===
insert into public.salas (id, nome, nome_norm, coordenacao, coordenacao_norm, uorg, andar, localidade, status, origem, criado_por)
select gen_random_uuid(), v.nome, public.norm_sala(v.nome), v.coord, public.norm_texto(v.coord), '', v.andar, v.loc, 'ativa', 'campo',
       (select id from public.usuarios where papel = 'admin' and ativo order by criado_em limit 1)
from (values
  ('DAD - Sala 101', 'Diretoria de Administração', '1º andar', 'Prédio Central'),
  ('DAD - Sala 102', 'Diretoria de Administração', '1º andar', 'Prédio Central'),
  ('CTI - Sala 201', 'Coordenação de Tecnologia da Informação', '2º andar', 'Prédio Central'),
  ('CTI - Sala 202', 'Coordenação de Tecnologia da Informação', '2º andar', 'Prédio Central'),
  ('COM - Sala 203', 'Coordenação de Comunicação', '2º andar', 'Prédio Central'),
  ('JUR - Sala 301', 'Consultoria Jurídica', '3º andar', 'Prédio Central'),
  ('PLAN - Sala 302', 'Coordenação de Planejamento', '3º andar', 'Prédio Central'),
  ('Sala de Reunião - Sala 305', 'Sala de Reunião', '3º andar', 'Prédio Central'),
  ('GAB - Sala 401', 'Gabinete', '4º andar', 'Prédio Central'),
  ('Copa - 2º andar', 'Copa', '2º andar', 'Prédio Central'),
  ('Auditório', 'Auditório', 'Térreo', 'Prédio Central'),
  ('ALM - Sala S01', 'Almoxarifado', '-1º andar', 'Anexo')
) as v(nome, coord, andar, loc)
where not exists (select 1 from public.salas s where s.nome_norm = public.norm_sala(v.nome));

-- === 3) bens com etiquetas (inclui um número repetido, um bem anulado e uma plaqueta "A" de outro órgão) ===
with admin as (
  select id from public.usuarios where papel = 'admin' and ativo order by criado_em limit 1
),
v(sala, tipo, descricao, mat, marca, num, serie, sit) as (values
  ('DAD - Sala 101', 'MONITOR', 'MONITOR LED 24 POLEGADAS', '100001', 'POSITIVO', '01001', 'curto', 'ativo'),
  ('DAD - Sala 101', 'MICROCOMPUTADOR', 'MICROCOMPUTADOR DESKTOP', '100003', 'POSITIVO', '01002', 'curto', 'ativo'),
  ('DAD - Sala 101', 'MESA', 'MESA DE TRABALHO RETA', '100005', '', '01003', 'curto', 'ativo'),
  ('DAD - Sala 101', 'CADEIRA', 'CADEIRA GIRATORIA COM BRACOS', '100007', '', '01004', 'curto', 'ativo'),
  ('DAD - Sala 101', 'GAVETEIRO', 'GAVETEIRO VOLANTE 3 GAVETAS', '100009', '', '01005', 'curto', 'ativo'),
  ('DAD - Sala 102', 'MONITOR', 'MONITOR LED 24 POLEGADAS', '100001', 'POSITIVO', '01006', 'curto', 'ativo'),
  ('DAD - Sala 102', 'NOTEBOOK', 'NOTEBOOK 14 POLEGADAS', '100004', 'DELL', '01007', 'curto', 'ativo'),
  ('DAD - Sala 102', 'MESA', 'MESA DE TRABALHO RETA', '100005', '', '01008', 'curto', 'ativo'),
  ('DAD - Sala 102', 'POLTRONA', 'POLTRONA DE ESPERA', '100008', '', '01009', 'curto', 'ativo'),
  ('DAD - Sala 102', 'GAVETEIRO', 'GAVETEIRO VOLANTE 3 GAVETAS', '100009', '', '01005', 'curto', 'ativo'),
  ('CTI - Sala 201', 'MONITOR', 'MONITOR LED 27 POLEGADAS', '100002', 'LG', '01010', 'curto', 'ativo'),
  ('CTI - Sala 201', 'MONITOR', 'MONITOR LED 27 POLEGADAS', '100002', 'LG', '01011', 'curto', 'ativo'),
  ('CTI - Sala 201', 'MICROCOMPUTADOR', 'MICROCOMPUTADOR DESKTOP', '100003', 'POSITIVO', '01012', 'curto', 'ativo'),
  ('CTI - Sala 201', 'MICROCOMPUTADOR', 'MICROCOMPUTADOR DESKTOP', '100003', 'POSITIVO', '01013', 'curto', 'ativo'),
  ('CTI - Sala 201', 'IMPRESSORA', 'IMPRESSORA MULTIFUNCIONAL LASER', '100011', 'HP', '01014', 'curto', 'ativo'),
  ('CTI - Sala 201', 'NOTEBOOK', 'NOTEBOOK 14 POLEGADAS', '100004', 'DELL', '90000001', 'longo', 'ativo'),
  ('CTI - Sala 202', 'MONITOR', 'MONITOR LED 24 POLEGADAS', '100001', 'POSITIVO', '01015', 'curto', 'ativo'),
  ('CTI - Sala 202', 'MICROCOMPUTADOR', 'MICROCOMPUTADOR DESKTOP', '100003', 'POSITIVO', '01016', 'curto', 'ativo'),
  ('CTI - Sala 202', 'ARMARIO', 'ARMARIO ALTO COM PORTAS', '100010', '', '01017', 'curto', 'ativo'),
  ('COM - Sala 203', 'TELEVISOR', 'TELEVISOR LED 50 POLEGADAS', '100013', 'SAMSUNG', '01018', 'curto', 'ativo'),
  ('COM - Sala 203', 'PROJETOR', 'PROJETOR MULTIMIDIA', '100012', 'EPSON', '90000002', 'longo', 'ativo'),
  ('COM - Sala 203', 'MESA', 'MESA DE TRABALHO RETA', '100005', '', '01019', 'curto', 'ativo'),
  ('COM - Sala 203', 'CADEIRA', 'CADEIRA GIRATORIA COM BRACOS', '100007', '', '01020', 'curto', 'ativo'),
  ('JUR - Sala 301', 'MESA', 'MESA DE TRABALHO RETA', '100005', '', '01021', 'curto', 'ativo'),
  ('JUR - Sala 301', 'CADEIRA', 'CADEIRA GIRATORIA COM BRACOS', '100007', '', '01022', 'curto', 'ativo'),
  ('JUR - Sala 301', 'ARMARIO', 'ARMARIO ALTO COM PORTAS', '100010', '', '01023', 'curto', 'ativo'),
  ('JUR - Sala 301', 'MONITOR', 'MONITOR LED 24 POLEGADAS', '100001', 'POSITIVO', '01024', 'curto', 'anulado'),
  ('PLAN - Sala 302', 'MONITOR', 'MONITOR LED 24 POLEGADAS', '100001', 'POSITIVO', '01025', 'curto', 'ativo'),
  ('PLAN - Sala 302', 'NOTEBOOK', 'NOTEBOOK 14 POLEGADAS', '100004', 'DELL', '01026', 'curto', 'ativo'),
  ('ALM - Sala S01', 'ARMARIO', 'ARMARIO ALTO COM PORTAS', '100010', '', '01027', 'curto', 'ativo'),
  ('ALM - Sala S01', 'ARMARIO', 'ARMARIO ALTO COM PORTAS', '100010', '', '01028', 'curto', 'ativo'),
  ('ALM - Sala S01', 'MESA', 'MESA DE TRABALHO RETA', '100005', '', 'A00001234', 'outra', 'ativo'),
  ('Sala de Reunião - Sala 305', 'MESA', 'MESA DE REUNIAO OVAL', '100006', '', '01029', 'curto', 'ativo'),
  ('Sala de Reunião - Sala 305', 'CADEIRA', 'CADEIRA GIRATORIA COM BRACOS', '100007', '', '01030', 'curto', 'ativo'),
  ('Sala de Reunião - Sala 305', 'CADEIRA', 'CADEIRA GIRATORIA COM BRACOS', '100007', '', '01031', 'curto', 'ativo'),
  ('Sala de Reunião - Sala 305', 'TELEVISOR', 'TELEVISOR LED 50 POLEGADAS', '100013', 'SAMSUNG', '01032', 'curto', 'ativo'),
  ('Sala de Reunião - Sala 305', 'AR CONDICIONADO', 'AR CONDICIONADO SPLIT 12000 BTU', '100014', '', '01033', 'curto', 'ativo'),
  ('Auditório', 'PROJETOR', 'PROJETOR MULTIMIDIA', '100012', 'EPSON', '01034', 'curto', 'ativo'),
  ('GAB - Sala 401', 'POLTRONA', 'POLTRONA DE ESPERA', '100008', '', '01035', 'curto', 'ativo'),
  ('GAB - Sala 401', 'MESA', 'MESA DE TRABALHO RETA', '100005', '', '01036', 'curto', 'ativo')
),
novos as (
  select gen_random_uuid() as id, s.id as sala_id, v.*
  from v join public.salas s on s.nome = v.sala
  where not exists (select 1 from public.etiquetas e where e.numero_normalizado = public.norm_numero(v.num) and e.serie = v.serie)
),
b as (
  insert into public.bens (id, sala_id, tipo_bem, descricao, item_material, descricao_origem, marca, situacao,
                           motivo_anulacao, anulado_por, anulado_em, usuario_id, registrado_em, dispositivo_id)
  select n.id, n.sala_id, n.tipo, n.descricao, n.mat, 'lista', n.marca, n.sit,
         case when n.sit = 'anulado' then 'registro de demonstração' end,
         case when n.sit = 'anulado' then (select id from admin) end,
         case when n.sit = 'anulado' then now() end,
         (select id from admin), now() - interval '1 day', 'demo'
  from novos n
  returning id
)
insert into public.etiquetas (id, bem_id, numero, numero_normalizado, serie, origem, usuario_id, registrado_em, dispositivo_id)
select gen_random_uuid(), n.id, n.num, public.norm_numero(n.num), n.serie, 'camera', (select id from admin), now() - interval '1 day', 'demo'
from novos n;

-- bem sem plaqueta (código provisório)
insert into public.bens (id, sala_id, tipo_bem, descricao, item_material, descricao_origem, observacao, codigo_provisorio, situacao, usuario_id, registrado_em, dispositivo_id)
select gen_random_uuid(), s.id, 'CADEIRA', 'CADEIRA GIRATORIA COM BRACOS', '100007', 'lista', 'Sem plaqueta; aguardando emplacamento', 'SEM-' || u.sigla || '-0001', 'ativo', u.id, now(), 'demo'
from public.salas s,
     (select id, sigla from public.usuarios where papel = 'admin' and ativo order by criado_em limit 1) u
where s.nome = 'COM - Sala 203'
  and not exists (select 1 from public.bens b where b.codigo_provisorio = 'SEM-' || u.sigla || '-0001');

-- === 4) planilha de consulta (o que "deveria" existir; parte já lida, parte ainda não localizada) ===
insert into public.patrimonio_planilha (numero, tipo, marca, coordenacao, andar, localidade)
select e.numero, b.tipo_bem, b.marca, s.coordenacao, s.andar, s.localidade
from public.etiquetas e
join public.bens b on b.id = e.bem_id
join public.salas s on s.id = b.sala_id
where e.dispositivo_id = 'demo' and e.serie = 'curto' and b.situacao = 'ativo'
on conflict (numero) do nothing;

insert into public.patrimonio_planilha (numero, tipo, marca, coordenacao, andar, localidade)
select to_char(2000 + g, 'FM00000'),
       (array['MONITOR', 'MICROCOMPUTADOR', 'MESA', 'CADEIRA', 'ARMARIO', 'POLTRONA'])[1 + g % 6], '',
       (array['Diretoria de Administração', 'Coordenação de Tecnologia da Informação', 'Coordenação de Comunicação', 'Consultoria Jurídica', 'Coordenação de Planejamento'])[1 + g % 5],
       '', 'Prédio Central'
from generate_series(1, 15) as g
on conflict (numero) do nothing;

-- === 5) unidades e responsáveis (fictícios, sem CPF nem matrícula) ===
insert into public.unidades_responsaveis (sigla, uorg, denominacao, codigo_siorg, responsavel)
values
  ('DAD', '900001', 'Diretoria de Administração', '100001', 'Responsável Demo 1'),
  ('CTI', '900002', 'Coordenação de Tecnologia da Informação', '100002', 'Responsável Demo 2'),
  ('COM', '900003', 'Coordenação de Comunicação', '100003', 'Responsável Demo 3'),
  ('JUR', '900004', 'Consultoria Jurídica', '100004', 'Responsável Demo 4'),
  ('PLAN', '900005', 'Coordenação de Planejamento', '100005', 'Responsável Demo 5')
on conflict (sigla) do nothing;

-- === 6) catálogo legado (plaqueta antiga para consulta pela leitura) ===
insert into public.siads_bens (numero_siads, plaqueta_antiga, item, descricao, item_material, antiga_repetida)
values
  ('80000001', '03001', 'MONITOR', 'MONITOR LED 24 POLEGADAS', '100001', false),
  ('80000002', '03002', 'MICROCOMPUTADOR', 'MICROCOMPUTADOR DESKTOP', '100003', false),
  ('80000003', '03003', 'MESA', 'MESA DE TRABALHO RETA', '100005', false),
  ('80000004', '03004', 'CADEIRA', 'CADEIRA GIRATORIA COM BRACOS', '100007', false),
  ('80000005', '03005', 'POLTRONA', 'POLTRONA DE ESPERA', '100008', false),
  ('80000006', '03006', 'ARMARIO', 'ARMARIO ALTO COM PORTAS', '100010', false),
  ('80000007', '03007', 'IMPRESSORA', 'IMPRESSORA MULTIFUNCIONAL LASER', '100011', true),
  ('80000008', '03007', 'PROJETOR', 'PROJETOR MULTIMIDIA', '100012', true),
  ('80000009', null, 'TELEVISOR', 'TELEVISOR LED 50 POLEGADAS', '100013', false),
  ('80000010', null, 'AR CONDICIONADO', 'AR CONDICIONADO SPLIT 12000 BTU', '100014', false)
on conflict (numero_siads) do nothing;

-- === 7) conferência (esperado: salas_demo 12, bens_demo 41, etiquetas_demo 40, planilha 50, catalogo_legado 10) ===
select (select count(*) from public.salas where origem = 'campo' and localidade in ('Prédio Central', 'Anexo')) as salas_demo,
       (select count(*) from public.bens where dispositivo_id = 'demo') as bens_demo,
       (select count(*) from public.etiquetas where dispositivo_id = 'demo') as etiquetas_demo,
       (select count(*) from public.patrimonio_planilha) as planilha,
       (select count(*) from public.siads_bens) as catalogo_legado;