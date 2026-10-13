# Limitações

## O que o app ainda não faz
- **XLSX:** a exportação é CSV (Excel e dados) e cópia JSON. Não há gerador de XLSX.
- **Tela para resolver duplicidades:** o app e o servidor sinalizam duplicidade (`v_duplicidades`,
  `v_duplicidades_provisorio`), mas resolver é feito por SQL. A tabela `resolucoes_duplicidade` existe no esquema.
- **Edição de tipos, descrições e localidades:** o administrador faz pelas telas básicas de *Mais* e pelo SQL Editor; não
  há uma tela de administração completa dessas listas.
- **Recuperação de senha por e-mail:** não existe; o administrador redefine no painel do Supabase.
- **Backup agendado:** este repositório não traz workflow de backup (em repositório público os artefatos do Actions são
  públicos). Há um script manual em `tools/backup/backup.sh`; veja [BACKUP.md](BACKUP.md). Ele não cobre a perda total do
  projeto Supabase (os usuários não entram no dump).

## Regras que valem hoje
- **Perfil novo fica "aguardando aprovação"** até o administrador aprovar, e a senha provisória precisa ser trocada no
  primeiro login (mínimo de 10 caracteres). Enquanto isso o app não deixa registrar.
- **Ninguém escreve direto nas tabelas pela API**: todo envio passa pela função `sincronizar_lote`. Corrigir um dado
  enviado por engano exige o SQL Editor (nem o administrador tem DELETE).
- **Anulação ignorada pelo servidor:** se o administrador restaurar um bem depois de uma anulação reenviada, o servidor
  não a aplica e o app volta o bem para "ativo".
- **O bem é enviado uma vez.** Depois de sincronizado, anular e adicionar etiqueta sincronizam normalmente, mas outras
  mudanças no bem (por exemplo, a marca ao adicionar uma etiqueta) ficam só no celular.
- **Restaurar bem anulado: só admin.**
- **Dados salvos antes do primeiro login não são enviados.** Para descartá-los: *Mais → Exportar JSON e limpar dados
  locais*.
- **Um aparelho por pessoa.** O mesmo usuário em dois celulares (ou apagar os dados do navegador) pode gerar códigos
  provisórios `SEM-` repetidos. O app não bloqueia; o administrador os vê em `select * from public.v_duplicidades_provisorio;`.
- **Um aparelho fica preso ao primeiro usuário** que entrar até os dados locais serem exportados e limpos.

## Limites da tecnologia
- **Registro que nunca saiu do celular** (aparelho perdido ou quebrado antes de sincronizar) é perdido. Sincronize
  sempre que houver sinal.
- **iPhone:** não vibra pelo navegador, o som pode ficar mudo com a chave de silêncio, a lanterna normalmente não está
  disponível e os dados do Safari não passam para o app instalado: instale na tela inicial **antes** de registrar. Fora
  do app instalado, o iOS pode apagar dados de sites pouco usados.
- **Câmera:** só funciona em HTTPS ou em `localhost`.
- **Leitura de etiqueta metálica** pode sofrer com reflexo; incline o celular. Etiqueta de papel sem código de barras
  é digitada.
- **Plano Free do Supabase:** sem backup automático e o projeto pausa após cerca de 1 semana sem uso. Projeto pausado
  fica fora do ar até ser reativado no painel.
- **O aviso de duplicidade** vale até o último pull: números registrados por outros celulares ainda não baixados não
  aparecem no aviso (o servidor sinaliza depois em `v_duplicidades`).
- **Sessão no celular:** o token de acesso fica no armazenamento do app (IndexedDB), em texto, como em qualquer PWA sem
  cofre do sistema. O que o protege é não existir script de terceiros (a política de segurança do site só aceita o próprio
  código) e o celular ter bloqueio de tela. Se um aparelho for perdido, desative o usuário (`ativo = false`) e redefina a senha.
- **Pull longo em sinal fraco:** o app baixa as listas em páginas e continua de onde parou, mas a primeira carga (milhares
  de números) ainda consome dados. Faça-a com Wi-Fi.

## Dados sensíveis
- A cópia JSON é um backup completo e contém tudo, inclusive CPF e matrícula dos responsáveis. Guarde com cuidado.
- Os CSV não trazem nome, matrícula nem CPF do responsável, a menos que o usuário marque a opção e confirme (fica na
  auditoria).
- Antes de usar o projeto com dados reais, confirme região dos servidores, política de TI/proteção de dados (LGPD) e a
  autorização formal da organização.
