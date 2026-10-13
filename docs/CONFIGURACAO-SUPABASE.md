# Configuração do Supabase (passo a passo)

Faça uma vez, na ordem. Você precisa de uma conta no [Supabase](https://supabase.com) e, para publicar, de uma conta no
GitHub e outra no Vercel. Nada neste guia usa dados reais: o seed de demonstração é 100% fictício.

> **Nota de nomes:** no banco existem `siads_bens`, `numero_siads`, `listar_siads_antigas` e `origem = 'siads'`. É o
> **nome histórico do esquema** e equivale ao **catálogo legado** (lista de consulta de bens antigos). Na interface e nos
> documentos o termo é "catálogo legado".

## 1. Criar o projeto
1. No Supabase, crie um projeto novo (o plano **Free** serve). Escolha a região mais próxima de quem vai usar; ela não pode
   ser trocada depois. Anote a senha do banco num gerenciador de senhas (você não vai precisar dela no app).
2. Em *Project Settings → API Keys*, copie a **URL** do projeto e a chave **publishable** (`sb_publishable_...`).
3. **Nunca** use a chave `sb_secret_...` no app nem no repositório. O app recusa essa chave e o build do Vercel falha se
   ela aparecer.
4. **Desligue o cadastro aberto.** Em *Authentication → Sign In / Providers*, desligue **Allow new users to sign up** e
   confirme que **Anonymous sign-ins** está desligado. Mesmo que algum deles ficasse ligado, o perfil novo nasce inativo e só
   o administrador aprova (migração 002).
5. **Tamanho mínimo da senha: 10 caracteres.** Procure *Minimum password length* em *Authentication → Sign In / Providers →
   Email* (em algumas versões do painel fica em *Authentication → Policies*). O app também exige 10 caracteres ao trocar a
   senha.

## 2. Rodar as migrações (001 a 010, em ordem)
No *SQL Editor*, cole e rode **todo** o conteúdo de cada arquivo de `supabase/migrations/`, **nesta ordem**:

| # | Arquivo | O que faz |
|---|---|---|
| 001 | `001_schema.sql` | Tabelas, RLS, funções de normalização, `sincronizar_lote`, views de duplicidade e exportação, seed de tipos e localidades (`Prédio Central`, `Anexo`) |
| 002 | `002_endurecimento.sql` | Perfil novo nasce inativo; troca obrigatória da senha provisória; tira dos coletores o INSERT direto nas tabelas |
| 003 | `003_lote2.sql` | `puxar_pagina` (pull em páginas) e `v_duplicidades_provisorio` |
| 004 | `004_bens_no_pull_e_edicao_de_sala.sql` | Bens de todos no pull; `atualizar_sala`; `ler_responsavel_pessoal` (só admin) |
| 005 | `005_patrimonio_planilha.sql` | Tabela de consulta `patrimonio_planilha` e `listar_patrimonio_planilha` |
| 006 | `006_unidades_responsaveis.sql` | Tabela de consulta `unidades_responsaveis` e `listar_unidades_responsaveis` |
| 007 | `007_mover_bens_mesclar_salas.sql` | `movimentos_admin`, `mover_bens`, `mesclar_salas`, `desfazer_movimento`, `listar_movimentos` (só admin) |
| 008 | `008_exportar_servidor.sql` | `exportar_bens_pagina` (só admin) |
| 009 | `009_usuarios_admin.sql` | `listar_usuarios` e `alterar_usuario` (só admin) |
| 010 | `010_siads_e_mover_bem.sql` | Tabela de consulta do catálogo legado (`siads_bens`), `listar_siads_antigas` e `mover_bem` |

Se o editor do Supabase reclamar de texto cortado, rode um bloco `create ... $fn$ ... $fn$;` por vez e depois o
`revoke/grant` no fim do arquivo. As migrações são idempotentes.

Opcional: rode `supabase/tests/rls.sql` (troque `<UUID_COLETOR_A>` e `<UUID_COLETOR_B>` pelos ids de dois coletores; tudo
termina em ROLLBACK). Veja [TESTES.md](TESTES.md).

## 3. Criar o administrador, primeiro login e promoção
1. *Authentication → Users → Add user → Create new user*: informe e-mail e uma senha provisória e marque
   **Auto Confirm User** (qualquer e-mail serve; não há recuperação de senha por e-mail).
2. **Primeiro login:** abra o app (veja a seção 5), entre com esse usuário e informe **nome + sigla** (2 a 4 letras ou
   números, única). O app mostra **"Aguardando aprovação"**: o perfil foi criado, mas ainda está inativo.
3. **Promover** (SQL Editor; troque o e-mail):

       update public.usuarios set papel = 'admin', ativo = true, aprovado_em = now()
       where id = (select id from auth.users where email = 'EMAIL_DO_ADMIN');

4. O app detecta a aprovação sozinho (até 30 s) e pede a **troca da senha provisória** (mínimo de 10 caracteres).
5. Para os demais usuários, repita o passo 1 e o 2; depois aprove em *Mais → Administração → Usuários* (ou por SQL:
   `update public.usuarios set ativo = true, aprovado_em = now() where sigla = 'XX';`).

## 4. Rodar o seed de demonstração
Depois que o administrador entrou e foi promovido, rode **todo** o `supabase/seed_demo.sql` no *SQL Editor* (se o editor
reclamar, rode cada bloco separado por `-- ===`). Ele cria dados **100% fictícios**: localidades, descrições, 12 salas,
bens com etiquetas (inclui um número repetido, um bem anulado e uma plaqueta "A..." de outro órgão), uma planilha de
consulta, unidades com responsáveis fictícios (sem CPF nem matrícula) e um pequeno catálogo legado. É idempotente. O
último comando mostra uma conferência (esperado: `salas_demo 12`, `bens_demo 41`, `etiquetas_demo 40`, `planilha 50`,
`catalogo_legado 10`).

Para trocar os dados de demonstração por dados reais depois (fora deste repositório), carregue os CSV pelo painel
(*Table Editor → tabela → Insert → Import data from CSV*): `patrimonio_planilha` (colunas `numero, tipo, marca,
coordenacao, andar, localidade`), `unidades_responsaveis` (`sigla, uorg, denominacao, codigo_siorg, responsavel,
matricula, cpf`, com CPF e matrícula como **texto**) e `siads_bens` (`numero_siads, plaqueta_antiga, item, descricao,
item_material, antiga_repetida`). Esses CSV **nunca** vão para o Git (o `.gitignore` já os ignora).

## 5. Configurar o app
- **No seu computador:** copie `config.example.js` para `config.js` e preencha a URL e a chave publishable. O `config.js`
  está no `.gitignore` e nunca deve ser commitado.
- **No Vercel:** em *Settings → Environment Variables*, crie `SUPABASE_URL` e `SUPABASE_PUBLISHABLE_KEY`. O `vercel.json`
  gera o `config.js` no build a partir delas e **o build falha** se faltar uma variável, se a URL não começar com
  `https://` ou se a chave for secreta. Mantenha o Framework Preset "Other". Faça um novo deploy.
- Se um aparelho já vinculado ao servidor abrir o app sem `config.js`, o app bloqueia o registro e avisa.

## 6. Gerenciar usuários
- **Redefinir senha:** *Authentication → Users →* o usuário → definir nova senha. Depois obrigue a troca no próximo login:
  `select public.exigir_troca_senha('XX');` (ou *Mais → Administração → Usuários → Exigir troca de senha*).
- **Desativar:** `update public.usuarios set ativo = false where sigla = 'XX';`. O RLS passa a negar tudo para ele.
- **Reativar:** o mesmo comando com `true`.

## 7. Publicar uma nova versão
Troque `VERSION` em `sw.js` e em `app.js`, faça commit e push. O Vercel publica sozinho. O build também carimba o SHA do
commit em `BUILD` (no `sw.js`): se alguém esquecer de trocar `VERSION`, o celular ainda assim enxerga a versão nova. No
celular, a versão nova é baixada em segundo plano e o app mostra a faixa **"Atualizar agora"**.

**Cabeçalhos de segurança (`vercel.json`):** o site é servido com uma Content-Security-Policy que só aceita scripts e
conexões do próprio site e de `https://*.supabase.co`. Se um dia usar um domínio próprio para o Supabase, acrescente-o em
`connect-src`. **Depois de publicar, teste a câmera** (motor nativo e WASM). Se algo parar por causa da política, o
rollback é remover o bloco `headers` do `vercel.json` (ou só a linha `Content-Security-Policy`), commit e push. Dica:
publique primeiro numa **branch** (o Vercel cria um deploy de pré-visualização) e teste lá.

## Plano Free: o que muda
- Não há backup automático do Supabase; veja [BACKUP.md](BACKUP.md) (e a nota sobre repositório público).
- O projeto **pausa após cerca de 1 semana sem uso**. Confira os limites atuais na página de preços do Supabase.
