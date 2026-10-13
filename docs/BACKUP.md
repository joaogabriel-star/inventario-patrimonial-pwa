# Backup do banco

> **Atenção (repositório público):** este repositório **não inclui** workflow de backup agendado. Em repositório público, os
> artefatos do GitHub Actions também são públicos, e um backup (mesmo criptografado) não deve ficar exposto. **Não crie um
> workflow de backup neste repositório.** Se quiser agendar, use um repositório **privado** à parte, um agendador do seu
> computador/servidor ou rode o script à mão.

O plano Free do Supabase **não tem backup automático**. O script `tools/backup/backup.sh` faz uma cópia do schema `public`,
confere o conteúdo, grava contagens e **criptografa** com [age](https://github.com/FiloSottile/age). Guarde o resultado fora
do GitHub.

## O que entra e o que fica de fora
- **Entra:** o schema `public` inteiro (bens, etiquetas, salas, usuários, auditoria, movimentos, tipos, descrições,
  localidades, planilha de consulta, funções, políticas).
- **Fica de fora (só o conteúdo; a estrutura entra):** `salas_responsavel_pessoal` (CPF e matrícula),
  `unidades_responsaveis` (planilha de responsáveis) e `usuarios_seguranca` (referência de senha). Eles se refazem a partir da
  sua planilha de unidades. Assim, mesmo que a chave de criptografia vaze, nenhum CPF vaza.
- **Não entra:** o schema `auth` (e-mails e hashes de senha dos usuários). Veja "Limites" abaixo.

## Rodar o backup (à mão)
1. **Chaves.** Instale o `age` e rode `age-keygen -o chave-backup.txt`. O comando mostra `Public key: age1...`.
   - A **pública** (`age1...`) não é segredo.
   - A **privada** (o arquivo `chave-backup.txt`) é o que abre os backups: guarde no gerenciador de senhas **e** numa cópia
     offline. **Se você a perder, todos os backups ficam impossíveis de abrir.** Nunca a coloque no repositório
     (o `.gitignore` já ignora `chave*`).
2. **Conexão.** Use a string do **Session Pooler** do Supabase (botão *Connect* do projeto), porta **5432**. Formato:
   `postgresql://postgres.<ref>:[SENHA]@<host>.pooler.supabase.com:5432/postgres`. Caracteres especiais na senha
   (`@`, `/`, `#`, `:`) precisam ser codificados na URL. Não cole a senha em arquivo, chat ou commit.
3. **Executar** (precisa de `bash`, `pg_dump`/`pg_restore`/`psql`, `age` e `sha256sum`):

       export SUPABASE_DB_URL='postgresql://...'      # só no seu terminal
       export BACKUP_AGE_RECIPIENT='age1...'
       bash tools/backup/backup.sh

   A saída fica em `backup-saida/` (pasta ignorada pelo Git).
4. Cada execução gera `inventario-AAAAMMDD-HHMMSS.dump.age` (o backup), `.sha256` e `.contagens.txt`. **Olhe as contagens
   de vez em quando**: o backup não avisa se o banco encolheu, só se o dump falhou.
5. **Faça o teste de restauração** abaixo. Um backup que nunca foi restaurado não é backup.

## Restaurar
Você precisa de `age` e das ferramentas do PostgreSQL (`pg_restore`, `psql`, `createdb`; a versão deve ser a do servidor ou
mais nova). Os comandos abaixo foram testados num PostgreSQL 16 local em Linux, **não** num projeto Supabase e **não** no Windows.

**Descriptografar e conferir:**

    age -d -i chave-backup.txt -o inventario.dump inventario-AAAAMMDD-HHMMSS.dump.age
    sha256sum -c inventario-AAAAMMDD-HHMMSS.dump.age.sha256     # na pasta onde estão os arquivos
    pg_restore --list inventario.dump

**Restaurar num banco de teste (o jeito seguro, e o que serve para recuperar dados apagados por engano).** O dump é só do schema
`public`; `usuarios` aponta para `auth.users`, que não está nele. Por isso o banco de teste precisa de um `auth` de mentira:

    createdb -T template0 restaurado
    psql -d restaurado -X -v ON_ERROR_STOP=1 <<'EOF'
    drop schema public;
    create schema auth;
    create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
    create role anon nologin; create role authenticated nologin;
    EOF
    PR="pg_restore -d restaurado --no-owner --no-privileges --exit-on-error"
    $PR --section=pre-data  inventario.dump
    $PR --section=data      inventario.dump
    psql -d restaurado -c "insert into auth.users(id) select id from public.usuarios"
    $PR --section=post-data inventario.dump

O `insert` entre `data` e `post-data` é obrigatório (a chave estrangeira de `usuarios` só é criada no `post-data`). Se algum
papel (`anon`, `authenticated`) já existir no seu PostgreSQL, ignore o erro dessa linha do `create role`. Depois compare as
contagens do banco restaurado com o `.contagens.txt`. Para recuperar linhas apagadas, copie só o que falta do banco de teste
para o Supabase (por exemplo, `\copy` ou `insert ... select`), **sem** restaurar por cima do projeto.

**Não faça** `pg_restore --clean` direto no projeto Supabase: ele apaga o schema `public` inteiro. Só foi testado num banco de
teste.

## Limites (leia)
- **Perda total do projeto Supabase:** o backup não traz os usuários (`auth.users`). Num projeto novo seria preciso rodar as
  migrações, recriar os usuários **com os mesmos ids** (ou remapear os ids nos dados) e recarregar CPF/matrícula e a planilha
  de unidades. **Não existe script nem teste para isso.** O backup cobre bem "alguém apagou/moveu dados por engano" e mal "o
  projeto sumiu".
- **Dados do dia:** o backup reflete o momento em que foi gerado. O que foi registrado depois só está no servidor e nos
  celulares. A cópia JSON do app continua sendo a rede de segurança dos celulares.
- **Versão do PostgreSQL:** o cliente precisa ser da versão do servidor ou mais novo; se o Supabase subir de versão, o dump falha
  com erro de versão.
- **Pausa do plano Free:** o plano Free pausa projetos sem uso por cerca de 1 semana. Rodar o backup gera atividade no banco,
  mas não está verificado que isso baste para evitar a pausa.
