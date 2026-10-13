# Testes

## 1. Teste automático do app (modo local)
Na raiz do projeto:

    powershell -ExecutionPolicy Bypass -File tools\teste-headless.ps1

Precisa de Python e de Edge ou Chrome. O script semeia um banco no formato antigo, abre o app (testa a migração) e confere
salas, localidades, CPF mascarado, marca e fornecedor, descrições e busca, CSV (com e sem dados pessoais, sem injeção de
fórmula), filtro por sala, tema, lanterna, armazenamento, faixa do topo, aviso de duplicidade com bem de outro aparelho e as
verificações do Lote 1 (`elegivel_sync`, `sem_config_bloqueia`, telas "Aguardando aprovação" e "senha obrigatória",
`descricoes.json` sem 6+ dígitos) e as do **Lote 2**: `norm_numero_igual_ao_servidor`, `duplicidade_normalizada` (M-14),
`falha_de_gravacao_avisa`, `anular_com_falha_nao_marca_anulado` (M-11), `sw_arquivos_existem_e_nao_ignorados`,
`sw_atualizacao_atomica` (M-5), `csp_html_sem_script_inline`, `cabecalhos_de_seguranca` (M-9) e `pull_*` (M-6: páginas,
retomada depois de queda, cursor só no fim, cai para a função antiga). Também cobre o v0.8.0 (`catalogo_*`: preenchimento pelo catálogo legado sem salvar sozinho, plaqueta repetida que só avisa;
`plaqueta_outro_orgao_identificada_sem_alerta`; colunas `numero_catalogo_legado` e `plaqueta_outro_orgao` no CSV; mover bem).
Cada linha termina em `PASS` ou `FAIL`, e o fim
traz um resumo (total, passou, falhou).
O código de saída é 0 só se tudo passou; é 1 se alguma verificação falhou **ou** se o teste não conseguiu rodar.

O script apaga seus arquivos temporários (`_t.html`, `_td.html`, `_seed.html`, perfil do navegador em `%TEMP%`) e encerra
só os processos que ele mesmo iniciou (servidor local e navegador), mesmo se o teste falhar.

### Parâmetros
| Parâmetro | Efeito |
|---|---|
| `-Diagnostico` | Não roda os testes. Imprime versão do PowerShell, navegadores achados, navegadores já abertos com depuração remota, porta 9337, **políticas corporativas no registro** (HKLM e HKCU: URLBlocklist, URLAllowlist, depuração, extensões, proxy; diz se `file://` está bloqueado) e uma **sonda por navegador**: conecta, abre `_seed.html` por `http://127.0.0.1`, imprime o resultado da semeadura, o estado da página (URL, título, readyState, texto do body) e os eventos do navegador (exceções, console, log, requisições que falharam); testa também `localhost`. Cole a saída na conversa. |
| `-Modo auto\|cdp\|dom` | `auto` (padrão) tenta CDP e, se falhar, cai no `dom`. |
| `-Navegador auto\|edge\|chrome` | `auto` tenta o Edge e depois o Chrome. |
| `-Porta`, `-PortaDebug` | `0` (padrão) = escolhe porta livre. |

### Como os arquivos são servidos
O teste **não usa `file://`**: serve a pasta do projeto por `http://127.0.0.1:<porta livre>` (`py -m http.server --bind 127.0.0.1`
ou, se não houver Python, um servidor HTTP mínimo em .NET) e encerra o servidor no fim. Usa `127.0.0.1` e `--no-proxy-server`
para fugir de resolução de nome e de proxy do ambiente.

### Os dois modos
- **CDP** (depuração remota por WebSocket): rápido, com porta livre aleatória, perfil temporário e `--remote-allow-origins=*`.
- **dom** (plano B, sem WebSocket): roda o navegador duas vezes com o mesmo perfil, `--dump-dom` e tempo virtual. A 1ª
  execução semeia o IndexedDB; a 2ª roda o roteiro e o resultado sai em `<pre id="resultado">`.
O script diz no início do resultado qual modo e qual navegador foram usados (`Modo usado: ...`).

### Erros comuns
| Mensagem | Significado | O que fazer |
|---|---|---|
| `Nao consegui conectar na depuracao remota` + `handshake ... 403` | Origem ou política recusou o WebSocket | Use `-Modo dom`; rode `-Diagnostico` |
| `O navegador fechou sozinho` | Política corporativa ou perfil bloqueado | `-Modo dom` ou `-Navegador chrome` |
| `Nenhuma aba (page) apareceu` | Navegador não abriu a porta de depuração | Rode `-Diagnostico` (veja processos e porta) |
| `dump-dom: ... nao escreveu <pre id="resultado">` | O modo dom estourou o tempo | Tente o outro navegador |
| `_seed.html nao terminou` / `A semeadura falhou dentro da pagina` | A página de semeadura não concluiu. A mensagem traz o estado da página e os eventos do navegador (requisição bloqueada, exceção JS, IndexedDB bloqueado). A própria página tem timeout interno de 15 s e escreve `SEMEADO-ERRO: <motivo>` | Leia os eventos impressos; rode `-Diagnostico` |
| `A navegacao para ... falhou: net::ERR_...` | O navegador não conseguiu abrir a URL (ex.: `ERR_BLOCKED_BY_ADMINISTRATOR` = política corporativa) | Veja a seção de políticas do `-Diagnostico` |
| `FAIL <nome>` | O app falhou naquela verificação (não é problema do script) | Veja o roteiro em `tools/teste-headless.ps1` |

Se os acentos aparecerem estragados no console ou o PowerShell 5.1 reclamar de caracteres, salve o script com BOM:
`$p='tools\teste-headless.ps1'; $t=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8); [IO.File]::WriteAllText($p,$t,(New-Object Text.UTF8Encoding $true))`

**Não cobre** a sincronização com o Supabase. Para isso, use os testes abaixo.

## 2. Permissões do banco (RLS)
No *SQL Editor*, rode `supabase/tests/rls.sql`, trocando `<UUID_COLETOR_A>` e `<UUID_COLETOR_B>` pelos ids de dois
coletores (*Authentication → Users*, coluna UID). Cada teste imprime PASSOU ou FALHOU em *Messages*. Tudo termina em
ROLLBACK: nada fica gravado. Verifica que:
- anônimo não lê nem executa nada;
- logado sem perfil não lê nem sincroniza;
- reenviar o mesmo lote não duplica;
- formato fora do padrão só gera alerta;
- coletor não lê CPF/matrícula, não apaga, não altera bem direto e não insere em nome de outro;
- o mesmo número em dois bens e dois usuários é aceito e aparece em `v_duplicidades`.

### Testes novos da migração 002 (T5 e T6)
- **T5** confirma que INSERT direto em `etiquetas`, `bens`, `salas`, CPF/matrícula e `auditoria` é negado e que o RPC
  continua recusando etiqueta em bem de outro usuário.
- **T6** confirma que uma anulação mais antiga que a restauração do admin **não** é confirmada (vem em
  `anulacoes_ignoradas`).
- Rode as migrações 001 e 002 antes. Se algum teste que passava antes falhar com `sem_permissao`, confira se os dois
  coletores existem e não estão pendentes (o teste os ativa dentro do ROLLBACK).

### Testes novos da migração 003 (T7 e T8) — Lote 2
- **T7 (M-6)** confirma que `puxar_pagina` é negada ao anônimo, que uma página cheia traz `mais = true` e `ultimo`, que
  percorrer o índice de 2 em 2 dá o mesmo total que uma página única (sem repetir nem perder), que o pull de salas não traz
  CPF/matrícula, que tabela inválida é recusada e que `meta` devolve `agora` e `sem_max`.
- **T8 (M-7)** confirma que dois bens com o mesmo código `SEM-…` são aceitos e aparecem em `v_duplicidades_provisorio`, e que
  o anônimo não lê a view.
- Rode as migrações 001, 002 e 003 antes.

### Manuais para o Lote 2 (celular e Vercel)
| # | Teste | Esperado |
|---|---|---|
| L2-1 | **Câmera com a CSP (M-9):** depois de publicar, abra o app instalado, ligue a câmera e leia uma etiqueta (motor nativo e, em *Diagnóstico*, o motor WASM) | Lê normalmente. Se a câmera ou o WASM pararem, **reverta** o `vercel.json` (ver `docs/CONFIGURACAO-SUPABASE.md`, seção 7) e me avise |
| L2-2 | Entrar, registrar, sincronizar, exportar CSV e JSON, **instalar na tela inicial** com a CSP ativa | Tudo funciona (a CSP só libera `'self'` e `https://*.supabase.co`) |
| L2-3 | **Atualização (M-5):** com a versão N instalada, publique a N+1 e abra o app (duas vezes) | Aparece a faixa azul **"Há uma versão nova do app… Atualizar agora"**; ao tocar, o app recarrega já na N+1 e *Mais* mostra a versão nova. Nada é trocado sozinho no meio do registro |
| L2-4 | Publicar duas vezes **sem** trocar `VERSION` | Mesmo assim o celular vê versão nova (o build carimba o SHA do commit em `sw.js`) |
| L2-5 | Abrir o app **offline** logo depois de instalar | Abre normalmente (o `config.js` e todos os arquivos já estão no cache) |
| L2-6 | **Pull (M-6):** com pouco sinal, derrube a internet no meio da primeira sincronização (modo avião) e volte | A faixa mostra "baixando listas…", depois "⚠ listas desatualizadas" se falhar; ao voltar a rede, continua de onde parou e o aviso some |
| L2-7 | **Duplicidade normalizada (M-14):** em um celular registre `A-12`; no outro (depois do pull) digite `A12` | O segundo avisa "JÁ REGISTRADO"; `v_duplicidades` mostra `A12` |
| L2-8 | **Falha de gravação (M-11):** no Chrome do computador, DevTools → Application → Storage, simule cota cheia e tente anular um bem | Aparece "NÃO FOI SALVO", o bem continua ativo |
| L2-9 | Código provisório repetido (M-7): `select * from public.v_duplicidades_provisorio;` | Lista os `SEM-…` repetidos (vazio se não houver) |

### Manuais para a migração 002 (não dá para automatizar no SQL Editor)
| # | Teste | Esperado |
|---|---|---|
| 1 | Crie um usuário novo no painel e entre no app | Tela de nome + sigla; depois **"Aguardando aprovação"**; não dá para fechar nem registrar |
| 2 | Aprove (`update public.usuarios set ativo = true, aprovado_em = now() where sigla = 'XX';`) | Em até 30 s o app pede a **troca da senha provisória** |
| 3 | Tente trocar para uma senha de 9 caracteres | Recusa (mínimo de 10) |
| 4 | Troque para uma senha válida | O app libera e sincroniza; `select deve_trocar_senha from public.usuarios where sigla='XX'` = `false` |
| 5 | `select public.exigir_troca_senha('XX');` e reabra o app | Pede a troca de senha de novo |
| 6 | Registre um bem, mude a data do celular 1 mês para trás, registre outro, volte a data | Os dois chegam ao servidor (a elegibilidade não depende mais da hora) |
| 7 | Um aparelho já usado, abra o site gerado por um deploy **sem** variáveis (ou sem `config.js`) | Painel "Servidor não configurado" e o app não deixa registrar |
| 8 | Deploy no Vercel sem `SUPABASE_URL` | O **build falha** com mensagem de erro |
| 9 | Exporte o "CSV para Excel" com o número `1"&1+1&"` em um bem e abra no Excel | A célula mostra o texto, não `12` |
| 10 | Exporte a cópia JSON com uma sala com CPF | Pede confirmação; em *Mais → Auditoria* aparece `exportacao` (a auditoria registra `dados_pessoais: true`) |

## 3. Sem login deve falhar
Troque `URL` e `CHAVE_PUBLISHABLE`. Os três devem devolver erro (401, 403 ou *permission denied*):

    curl -i "URL/rest/v1/bens?select=*" -H "apikey: CHAVE_PUBLISHABLE"
    curl -i -X POST "URL/rest/v1/rpc/sincronizar_lote" -H "apikey: CHAVE_PUBLISHABLE" -H "Content-Type: application/json" -d "{\"p_lote\":{}}"
    curl -i -X DELETE "URL/rest/v1/bens?id=eq.00000000-0000-0000-0000-000000000000" -H "apikey: CHAVE_PUBLISHABLE"

## 4. Roteiro de campo (celular)
Marque o resultado de cada um.

| # | Teste | Como fazer | Esperado | Resultado |
|---|---|---|---|---|
| 1 | Modo avião no meio do envio | Registre ~20 bens, ligue o modo avião logo após salvar alguns, registre mais, desligue | Pendentes (⏳) zeram sozinhos; sem duplicatas | |
| 2 | Matar o app | Registre offline, feche o app à força, abra de novo | Registros continuam; pendentes seguem na faixa | |
| 3 | Reiniciar o celular | Registre offline, reinicie o aparelho, abra o app | Idem | |
| 4 | 2.000 registros offline | `tools/gerar-2000-registros.js` (instruções no próprio arquivo) | Pendentes caem de 50 em 50 até zerar; `select count(*) from public.bens` bate | |
| 5 | 4 celulares ao mesmo tempo | Registre bens diferentes nos 4 | Todos chegam; contadores batem | |
| 6 | Dois usuários, mesmo bem | Registre o mesmo número em dois celulares | Os dois bens são aceitos; o segundo celular avisa depois de um pull; `select * from public.v_duplicidades` lista o número | |
| 7 | Sair com pendentes | Com pendentes, toque em *Sair* e em *Exportar JSON e limpar dados locais* | Os dois são negados | |
| 8 | Sem login | Abra o app sem sessão | Tela de login; nada é lido nem enviado | |
| 9 | Usuário desativado | Desative um usuário no SQL | Faixa mostra "usuário desativado"; nada sincroniza | |
| 10 | Faixa do topo | Conectado / modo avião / sem `config.js` | "Servidor conectado" / "Sem conexão (trabalhando offline)" / "Modo local (sem servidor)" | |

Conferências úteis no SQL Editor:

    select count(*) from public.bens;
    select id, count(*) from public.bens group by id having count(*) > 1;   -- deve vir vazio
    select * from public.v_duplicidades;

## 5. Depois dos testes
Se usou dados de demonstração ou de teste e quer recomeçar, apague-os do servidor pelo SQL Editor (por exemplo, `truncate`
das tabelas de dados, com muito cuidado e só em projeto de teste) e use *Mais → Exportar JSON e limpar dados locais* em cada
celular.

## 6. Dados usados nos testes
Todos fictícios. Os CPFs que aparecem em `tools/teste-headless.ps1` e em `supabase/tests/rls.sql` são **sintéticos, de teste**
(`52998224725` é válido só pelo dígito verificador e não pertence a ninguém). Os e-mails usam `exemplo.com`.
