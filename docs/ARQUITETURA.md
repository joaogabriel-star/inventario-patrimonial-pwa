# Arquitetura

## Visão geral

```
CELULAR (PWA, HTTPS)                                              SUPABASE (Postgres)
┌──────────────────────────────────────────┐                      ┌──────────────────────────────┐
│ Câmera → leitor ZXing (nativo ou WASM)   │                      │ Auth (e-mail/senha)          │
│ Digitação manual                         │                      │ RLS em todas as tabelas,     │
│        │                                 │                      │   sem DELETE                 │
│        ▼                                 │   lotes de 50        │ sincronizar_lote()  ◄────────┼── idempotente
│ IndexedDB  (nunca é apagado)             │ ───────────────────► │ puxar_pagina()      ────────►┼── salas, listas,
│  bens, salas, tipos, descrições, ...     │   HTTPS + login      │ v_duplicidades               │   índice de números
│  outbox (pendente / erro / ok)           │ ◄─────────────────── │ v_exportacao                 │
│  indice (números de outros celulares)    │   pull               └──────────────────────────────┘
└──────────────────────────────────────────┘
   sync.js decide quando enviar; remote-adapter.js é a única peça que conhece o Supabase.
```

## Arquivos

| Arquivo | Função |
|---|---|
| `index.html`, `style.css` | Telas (Registrar, Bens, Salas, Diagnóstico, Mais), temas claro/escuro/automático |
| `app.js` | Banco local (IndexedDB), leitor de câmera, regras de etiqueta e duplicidade, telas, CSV/JSON |
| `sync.js` | Motor de sincronização: fila de saída, lotes, tentativas, pull, login/perfil/senha, faixa do topo |
| `remote-adapter.js` | Contrato do backend + adaptador Supabase (REST via `fetch`, sem biblioteca). Trocar de backend = novo adaptador |
| `sw.js`, `manifest.webmanifest`, `icons/` | Instalação na tela inicial e uso offline |
| `vendor/` | Leitor ZXing-C++ (barcode-detector + `.wasm`), local para funcionar offline |
| `descricoes.json` | Pares Item × Descrição × Item Material (na demonstração, itens fictícios; sem números patrimoniais, valores ou datas) |
| `config.js` | URL e chave publishable do Supabase (não vai para o Git; no Vercel é gerado no build) |
| `vercel.json`, `.vercelignore` | Geração do `config.js` no deploy; o que não é publicado no site |
| `supabase/` | Migrações do banco, seed de demonstração, testes de permissão (RLS) |
| `tools/` | Scripts: teste headless, teste de volume, backup manual |

## Dados no celular
- Tudo é gravado primeiro no IndexedDB, com durabilidade estrita (o bip só vem depois de gravar de verdade).
- Cada bem tem uma lista de **etiquetas** (número em texto, série, origem, simbologia). O número é sempre texto, para
  não perder o zero à esquerda.
- **Outbox**: uma linha por item a enviar (sala, bem, etiqueta, anulação) com estado pendente / erro / ok. As linhas são
  derivadas do estado local, então nada se perde se o app fechar no meio.
- **Índice**: números de bens registrados por outras pessoas (vindos do pull), usado só para o aviso de duplicidade.

## Sincronização
1. Ao salvar, o registro vai para o IndexedDB e a fila é atualizada.
2. O motor envia em lotes de 50 (salas, bens, etiquetas, anulações, nessa ordem), com limite de 15 s por pedido.
3. O servidor grava com `on conflict (id) do nothing` (reenviar não duplica) e devolve os ids que agora existem lá.
4. O celular marca esses itens como **ok**. O registro local continua guardado.
5. Falha de rede: o item continua pendente e a nova tentativa espera cada vez mais (até 5 minutos).
6. Item cujo "pai" ainda não chegou (ex.: bem cuja sala falhou): volta como **erro** com o motivo e é reenviado.
7. Gatilhos: ao salvar, ao voltar a internet, a cada 30 s, ao abrir o app e no botão "Sincronizar agora".
8. Pull (ao abrir, manual e a cada 5 minutos): salas, tipos, descrições, localidades e o índice de números. Vem em
   **páginas de 2.000 itens por tabela** (`puxar_pagina`), cada página é aplicada ao chegar, o ponto onde parou fica
   guardado e o cursor só avança quando tudo foi aplicado. Se o servidor ainda não tiver a migração 003, o app usa a
   função antiga `puxar_mudancas` (tudo de uma vez). Falha do pull aparece na faixa do topo e em *Mais*.
9. Duplicidade: o número é normalizado no celular da mesma forma que no servidor (`normNumero` = `norm_numero`: sem
   espaços, hífens e pontos, em maiúsculas), então `A-12` e `A12` são o mesmo número dos dois lados.

## Instalação e atualização do app (service worker)
- Todos os arquivos ficam em **um cache só**, `inventario-<VERSION>-<BUILD>`. O build do Vercel troca `BUILD` pelo SHA do commit,
  então cada deploy é uma versão nova mesmo que ninguém troque `VERSION`.
- A versão nova é baixada **por inteiro** (tudo ou nada) e **fica esperando**; o app mostra "Atualizar agora". Nunca se
  serve HTML novo com JS velho, e nada é trocado no meio de um registro. Se a instalação falhar (arquivo ausente, sem
  rede), o app avisa e continua na versão atual; se falhar na primeira instalação, avisa que o uso offline não foi preparado.
- O `vercel.json` envia cabeçalhos de segurança (CSP restrita a `'self'` e `https://*.supabase.co`, `X-Frame-Options`,
  `nosniff`, `Referrer-Policy`, `Permissions-Policy` liberando só a câmera). Por isso o app não tem script inline.

## Servidor
- Tabelas: `usuarios`, `localidades`, `salas`, `salas_responsavel_pessoal` (CPF e matrícula, só admin lê),
  `tipos_bem`, `descricoes_bem`, `bens`, `etiquetas`, `resolucoes_duplicidade`, `auditoria`.
- Views: `v_duplicidades` (números repetidos), `v_duplicidades_provisorio` (códigos `SEM-…` repetidos, migração 003) e
  `v_exportacao` (uma linha por bem, com a sala final).
- Funções: `meu_perfil`, `criar_perfil`, `senha_trocada`, `sincronizar_lote`, `puxar_pagina` (migração 003) e `puxar_mudancas`
  (a antiga, mantida para o app 0.5.1 e como alternativa).
- **Segurança**: RLS em todas as tabelas; ninguém tem DELETE; **ninguém grava direto nas tabelas de dados pela API**:
  toda escrita do coletor passa pela função `sincronizar_lote` (security definer), que valida o dono e calcula os campos;
  perfil novo nasce inativo e o administrador aprova; a senha provisória precisa ser trocada no primeiro login; usuário
  desativado perde acesso a tudo; a chave secreta nunca é usada no app (ele recusa o `sb_secret` e o build do Vercel falha).

## Leitura da etiqueta
- Etiqueta metálica: código de barras lido por câmera em vídeo contínuo (`BarcodeDetector` nativo quando existe; senão
  ZXing-C++ em WASM, que também roda no iPhone).
- Etiqueta de papel sem código de barras: digitação manual.
- O **modo diagnóstico** mostra a simbologia e o conteúdo exatos lidos.
