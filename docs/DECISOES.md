# Decisões

O que foi decidido e por quê.

## Dados e etiquetas
- **Número sempre em texto.** Senão `01888` vira `1888`. Vale para o banco, a tela e o CSV (no CSV do Excel, `="01888"`).
- **Número livre + série.** Há etiquetas de 3, 5, 7 e 8 dígitos. Cada etiqueta guarda o número e uma *série*
  (curto, longo ou outra), sugerida pelo formato (curto = 5 caracteres com zero à esquerda; longo = 7 ou 8 dígitos) e
  editável. O app não pergunta a coluna por tamanho. O CSV tem uma coluna por série.
- **Um bem pode ter várias etiquetas** (a antiga e a nova). Não existe etiqueta "principal"; qual é a chave de
  conciliação com o catálogo legado ainda será definida.
- **Formato errado só avisa, nunca bloqueia.** O campo é livre; valor fora do padrão é salvo com alerta.
- **Número não é único.** Duplicidade é sinalizada (mesmo número e mesma série em bens diferentes = conflito; mesmo
  número em séries diferentes = aviso leve), mas os dois registros são mantidos. Nunca se sobrescreve nem se apaga.
- **Sem etiqueta, dois caminhos:** código provisório `SEM-<sigla>-nnnn` com observação obrigatória, ou "etiquetado em
  campo" (lê/digita a etiqueta nova colada e marca o bem).

## Apagar nunca
- **Anulação em vez de apagar.** Desfazer um registro o marca como anulado, com motivo. No banco ninguém tem DELETE.
- **Restaurar bem anulado: só admin.**
- **Mesclar salas não altera os bens.** A sala mesclada aponta para a de destino e a exportação usa a sala final;
  dá para desfazer.

## Offline primeiro
- **Gravar no celular antes de tudo**, com confirmação de gravação em disco, e só depois avisar o usuário.
- **O celular gera os ids (UUID).** Reenviar o mesmo registro não duplica (`on conflict do nothing`).
- **Fila derivada do estado local.** Cada item a enviar é calculado a partir dos dados salvos, então nada se perde se o
  app fechar, a bateria acabar ou o celular reiniciar.
- **O registro local nunca é apagado**, nem depois de confirmado. Sair da conta e limpar dados ficam bloqueados com
  pendências.
- **Dados anteriores ao primeiro login não sincronizam.** São testes; entram só se o usuário decidir recomeçar do zero.
  O caminho é exportar o JSON e limpar os dados locais.
- **Um celular por pessoa.** Um aparelho fica preso ao primeiro usuário que entrar.
- **Contador do código provisório:** o maior entre o local e o do servidor, mais um.

## Servidor
- **Supabase (Postgres + login + API).** O trabalho difícil do projeto é o offline e a integridade, não a API; o Supabase
  entrega login, API e RLS prontos. A região é escolhida ao criar o projeto.
- **Sem `supabase-js`.** O adaptador fala direto com as APIs REST do Supabase via `fetch`: menos código de terceiros,
  sem CDN. Trocar de backend (Railway, Apps Script) é escrever outro adaptador.
- **Sem auto-cadastro.** O admin cria as contas; qualquer e-mail serve. Sem recuperação de senha por e-mail: o admin
  redefine no painel.
- **Sigla única no servidor.** Evita códigos provisórios repetidos entre pessoas.
- **Todo usuário ativo lê salas, bens e o índice de números** (necessário para o aviso de duplicidade). Usuário
  desativado perde o acesso (RLS exige `ativo = true`).
- **CPF e matrícula em tabela separada, só admin lê.** Os celulares nunca os baixam.
- **Tipo e descrição como texto, sem chave estrangeira.** O bem guarda o nome do tipo e a descrição (e o Item Material).
  Assim um bem nunca é rejeitado por causa de uma lista que ainda não sincronizou, e editar a lista não mexe nos bens.
  O servidor é a fonte das listas; o celular só lê.
- **O servidor nunca rejeita por formato ou duplicidade.** Só marca alerta. Itens cujo "pai" ainda não existe voltam como
  erro com o motivo e são reenviados.
- **Tipos, descrições e localidades: só admin** (fase 2b).
- **Sala já sincronizada: qualquer usuário logado e ativo edita (v0.6.1, migração 004).** Nome, coordenação, UORG, andar,
  localidade e responsável. A alteração vai **primeiro** ao servidor (`atualizar_sala`, só online; sem conexão não salva,
  para não divergir do que os outros veem) e depois ao aparelho. Toda edição fica na auditoria com o estado anterior e quem
  editou. **CPF e matrícula continuam só do admin** (o coletor nem os vê). Risco aceito: um coletor pode renomear uma sala
  por engano; a auditoria permite desfazer.
- **Planilha de patrimônio = lista de CONSULTA, não bens (v0.6.2, migração 005).** Os números que já constam na planilha de
  inventário anterior ficam em `patrimonio_planilha` (número, tipo, marca, coordenação, andar, localidade), baixada inteira em cada
  sincronização e guardada em `meta`. Ao ler/digitar um número que consta, o app preenche tipo e marca (sem trocar o que a
  pessoa já escolheu neste registro) e avisa "consta na planilha". Foi escolhida em vez de inserir bens porque bem exige sala e
  dono, geraria uma duplicidade a cada item registrado de verdade e não pode ser editado depois (fase 2b). Entram só os
  números de EXATAMENTE 5 dígitos (o primeiro de cada célula, sem letra colada); os demais itens receberão plaqueta nova.
  Nada pessoal (nomes, e-mails, CPF) entra.
- **Catálogo legado na leitura, botão Mover e plaqueta de outro órgão (v0.8.0, migração 010).** (No esquema do banco o nome
  histórico é `siads`: `siads_bens`, `numero_siads`, `listar_siads_antigas`, `origem 'siads'`; equivale ao catálogo legado.)
  - **O número do catálogo legado é a chave do "não localizado"** (que se faz depois de coletar todas as salas): bem do catálogo
    sem nenhum bem do levantamento ligado a ele = não localizado. A ligação vem da plaqueta ANTIGA lida (tabela `siads_bens`,
    carregada por CSV pelo painel) e, para os bens emplacados agora (plaqueta nova de 5 dígitos), da conciliação pela descrição
    depois de cada sala (CSV; a fazer).
  - Plaqueta antiga com 1 a 4 dígitos perdeu os zeros na planilha: completa até 5. Com 6 a 8 dígitos: ignorada (será coletada).
    Plaqueta antiga repetida no catálogo: só avisa, não preenche.
  - Ao ler uma plaqueta que consta no catálogo legado, o app preenche tipo (Item do catálogo, que vence o tipo da planilha),
    descrição e Item Material e **espera o Salvar** (a pessoa completa marca e fornecedor; o catálogo não tem esses dados). O
    salvamento automático da v0.7.4 fica só para o que consta apenas na planilha.
  - O celular baixa só os bens do catálogo **com plaqueta antiga** (os únicos que a leitura acha); o resto fica no servidor.
    Valor, data e conta contábil não entram em lugar nenhum.
  - **Mover**: no cartão do bem e no aviso "JÁ FOI LIDO" ("Está nesta sala: mover"), para **coletor e administrador** (risco
    aceito: qualquer coletor move bem de qualquer um; fica registrado e o admin desfaz). Bem ainda não enviado muda só no aparelho.
  - Plaqueta que começa com **A** + dígitos (ex.: A00005933) é **de outro órgão**: sem alerta de formato, marcada no app e no
    CSV (`plaqueta_outro_orgao`).
  - O CSV ganhou as colunas `numero_catalogo_legado` e `plaqueta_outro_orgao` (as duas exportações, deste aparelho e do
    servidor). A coluna `numero_catalogo_legado` vem de `bens.numero_siads` (nome histórico do esquema).
- **Leitura em ritmo de levantamento (v0.7.4, decisão do responsável).** Só para a leitura pela **câmera** (a digitação continua
  manual, porque passa por números incompletos):
  - número que **consta na planilha** e ainda não foi lido, com a sala escolhida: **salva sozinho** como localizado, com tipo e
    marca da planilha (sem descrição/fornecedor "fixados", que seriam de outro bem) e mostra **Desfazer** (anula, não apaga).
    Risco aceito: com a sala errada escolhida, vários bens entram na sala errada; o conserto é *Administração → Mover bens*.
    Não salva sozinho se a pessoa já começou o item à mão (escolheu tipo/marca ou digitou observação). Enquanto uma janela está
    aberta ou um salvamento está em curso, a câmera é ignorada (é preciso afastar e apontar de novo);
  - número **já lido** neste levantamento (mesmo número e série em bem ativo): **não registra de novo** e oferece "É outro bem:
    registrar mesmo assim" (que volta o número ao formulário e pede a confirmação de duplicidade). Isto muda a regra "duplicidade
    só avisa": pela câmera, o padrão agora é não gravar; gravar continua possível, sempre por escolha explícita;
  - **CSV da planilha** (*Mais → Exportar*): cada número da planilha como localizado / não localizado, em que sala, por quem, e se
    foi achado em **outra** coordenação. Vale até a última sincronização do aparelho; a planilha é por coordenação, então numa
    coordenação com várias salas o "não localizado" só é definitivo depois de ler todas elas.
- **Correções de campo (v0.7.3).** (1) `salvarSala` não depende mais do estado da tela depois de esperar o servidor: cancelar
  durante o envio criava sala nova, e o toque duplo em "Salvar sala" criava duas; agora há trava, aviso "Salvando…" e prazo de 20 s.
  (2) **Sigla e nome completo da coordenação valem como a mesma** (`chaveCoord`, pela tabela de unidades): a planilha usa a sigla
  (`JUR`) e a sala pode ter o nome completo (`Consultoria Jurídica`); sem isso o cartão "(planilha)" não sumia (e quem tocava em
  "Editar" nele criava sala nova) e a sala não mostrava os itens da planilha. Depende de a tabela de unidades ter a `denominacao`
  igual ao nome usado na sala. Salas já duplicadas se resolvem em *Administração → Mesclar salas*.
- **Usuários na administração (v0.7.2, migração 009).** Só o admin (`listar_usuarios`, `alterar_usuario`; precisam de internet).
  Ações: ativar (aprovar ou reativar), desativar, tornar administrador/coletor e exigir troca de senha. **As regras ficam no
  servidor:** o administrador não desativa, rebaixa nem tranca a própria conta (assim sempre sobra um administrador ativo, e o
  servidor ainda trava as linhas dos administradores para dois não se rebaixarem ao mesmo tempo); só usuário ativo vira
  administrador. Nada é apagado e cada alteração vai para a auditoria com o estado anterior. A tela mostra o e-mail do perfil
  (o administrador já o vê no painel do Supabase). **Não há botão para redefinir a senha:** isso é no painel do Supabase, seguido
  de “Exigir troca de senha”. Desativar vale na hora para o servidor (RLS), mesmo com o app aberto no celular da pessoa.
- **Exportar CSV pelo servidor (v0.7.1, migração 008).** Só o admin. O servidor devolve os bens em páginas (`exportar_bens_pagina`)
  e o app monta o CSV com **as mesmas colunas e regras** do CSV deste aparelho (a montagem é uma função só, `linhaCSV`). Serve
  para ter a lista completa mesmo se o celular não sincronizou, e o app mostra "N bens no servidor (este aparelho tem M)". Dados
  pessoais só com a caixa marcada e confirmação; o servidor grava a exportação na auditoria. Fica de fora o XLSX (etapa 4).
- **Administração: mover bens, mesclar salas e desfazer (v0.7.0, migração 007).** Só o administrador, pelo servidor
  (`mover_bens`, `mesclar_salas`, `desfazer_movimento`, `listar_movimentos`; precisam de internet). Mesclar **não apaga**: a
  sala de origem fica `mesclada` (e some das listas) e os bens vão para a de destino. Todo movimento guarda o estado anterior
  em `movimentos_admin` e vai para a auditoria. **Desfazer é conservador**: só devolve o bem que ainda está onde o movimento o
  deixou, e recusa desfazer uma mesclagem se a sala foi alterada depois. Bem criado neste aparelho e movido pelo admin recebe a
  nova sala no pull. Esta etapa não permite desfazer o desfazer.
- **Cada celular vê os bens de todos (v0.6.1, migração 004).** O pull paginado traz também os bens com etiquetas (só nome e
  sigla de quem registrou). Esses bens ficam marcados `servidor: true` no aparelho e **nunca são reenviados** (não têm
  `elegivel_sync`). Por isso não dá para anular nem acrescentar etiqueta neles pelo celular de outra pessoa: a alteração
  não chegaria ao servidor. Isso fica para a tela de administração (fase 2b).
- **`config.js` com URL e chave publishable, fora do Git.** No Vercel é gerado no build. A chave secreta nunca é usada.

## Endurecimento (migração 002, v0.6)
- **Perfil novo nasce inativo e o administrador aprova.** O app mostra "Aguardando aprovação". Assim, mesmo que o
  auto-cadastro do Supabase ficasse ligado por engano, ninguém de fora lê o inventário.
- **Toda escrita do coletor passa pelo RPC.** Revogamos o INSERT direto nas tabelas de dados: pela API REST um coletor
  poderia anexar etiquetas a bens de outros (e ninguém consegue apagar depois).
- **Elegibilidade ao envio por marca gravada na criação** (`elegivel_sync`), não por comparação de horas: o relógio do
  celular pode andar para trás e deixar registros de fora sem aviso.
- **Anulação ignorada pelo servidor não é confirmada.** O servidor devolve `anulacoes_ignoradas` e o app volta o bem a
  "ativo" (o servidor é a verdade).
- **Senha provisória: troca obrigatória.** O servidor guarda uma referência do hash da senha (em tabela sem acesso pela
  API) para conferir que a senha mudou de verdade.
- **O CSV do Excel só usa `="..."` para números só com dígitos.** Qualquer outro texto (inclusive o que vem de um código
  de barras) é escapado: um código malicioso não vira fórmula.
- **`descricoes.json` sem números longos nem séries e fora do site.**
- **O build do Vercel falha** sem as variáveis do Supabase ou com chave secreta; um aparelho já vinculado que abra o app
  sem `config.js` fica bloqueado em vez de trabalhar em "modo local" sem avisar.

## Leitura e telas
- **Leitor de código de barras com reserva.** `BarcodeDetector` nativo quando existe; senão ZXing-C++ em WASM (o iPhone
  não tem o nativo). Tudo local, para funcionar offline.
- **OCR da etiqueta de papel: não.** Não dá para prometer precisão, e a digitação manual custa poucos segundos por bem.
- **Modo diagnóstico** para descobrir o que cada etiqueta realmente contém antes de fixar a configuração.
- **Tipo e descrição em lista com busca**, sem abrir o teclado sozinho no celular.
- **Lanterna:** só aparece se o navegador declarar suporte; senão, uma dica para ligar pela Central de Controle.
- **Tema claro/escuro/automático**, sem fontes externas, para funcionar offline.
- **CSV para Excel brasileiro:** separador `;`, UTF-8 com BOM, número como texto. CPF e matrícula só saem se o usuário
  marcar e confirmar, e a exportação fica registrada.
- **XLSX (fase 2b):** gerador próprio mínimo, só entra se abrir no Excel sem pedir reparo.

## Plano Free
O plano Free não tem backup automático e pausa o projeto após cerca de 1 semana sem uso. Por isso há um script de
backup criptografado, para rodar fora do Supabase (`docs/BACKUP.md`).

## Backup
- **Script manual (`tools/backup/backup.sh`), sem workflow neste repositório.** O projeto original agendava o backup pelo
  GitHub Actions num repositório privado. Em repositório **público** os artefatos do Actions também são públicos, então a
  versão de demonstração não traz o workflow e a documentação avisa para não criá-lo aqui.
- **`pg_dump` pelo Session Pooler** (a conexão direta do Supabase é IPv6, que nem todo ambiente tem).
- **Criptografia com `age`:** a chave pública vai para o script e a **privada fica só com o responsável**. Perdeu a privada,
  perdeu os backups.
- **Fica de fora o conteúdo de CPF/matrícula, da planilha de responsáveis e das referências de senha**, e todo o schema `auth`:
  um vazamento da chave não expõe CPF nem senha. Custo: a restauração total exige recriar usuários e recarregar essas planilhas
  (sem script; ver limites em `docs/BACKUP.md`).
- Rodar o backup gera atividade no banco, mas não está verificado que isso baste para o projeto Free não pausar.
