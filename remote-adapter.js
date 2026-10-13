'use strict';
/* Camada de armazenamento remoto.

   O app (app.js) e o motor de sincronização (sync.js) NUNCA falam direto com Supabase, Railway ou Google Apps Script.
   Eles só conhecem `window.Remote`, um "adaptador" com o contrato abaixo. Para trocar de backend, escreva outro adaptador,
   registre-o em RemoteAdapters e escolha-o em ADAPTADOR_ATIVO. Nada mais muda.

   CONTRATO (todos assíncronos, exceto nome/configurado/sessao/restaurar):
     nome                       'supabase' | 'nenhum' | ...
     configurado()              há URL e chave? Se false, o app funciona só neste aparelho.
     restaurar(sessao)          recoloca a sessão guardada (a persistência é feita pelo motor via `persistir`)
     sessao()                   sessão atual ou null
     entrar(email, senha)       -> { id, email }
     sair()                     encerra a sessão (apenas local; nunca apaga dados)
     trocarSenha(atual, nova)
     meuPerfil()                -> perfil | null (null = ainda não tem perfil)
     criarPerfil(nome, sigla)   -> { ok, erro?, perfil? }
     enviarLote(lote)           lote = { dispositivo_id, salas, bens, etiquetas, anulacoes }
                                -> { salas:[id], bens:[id], etiquetas:[id], anulacoes:[bem_id], adiados:[{tabela,id,motivo}], recebido_em }
                                Idempotente: reenviar o mesmo id não duplica nem sobrescreve.
     baixarMudancas(cursor)     -> { agora, salas, tipos, localidades, descricoes, indice, sem_max }   (tudo de uma vez; legado)
     baixarPagina(tabela, desde, apos, limite)
                                -> { agora, itens, mais, ultimo }  tabela = tipos | localidades | salas | descricoes | bens | indice
                                   (paginado por id: passe `ultimo` como `apos` enquanto `mais` for true;
                                    `bens` exige a migração 004: sem ela o servidor responde 400 'tabela_invalida')
                                -> { agora, sem_max }              tabela = meta
     atualizarSala(sala)        edita uma sala JÁ no servidor (qualquer usuário ativo; CPF/matrícula só o admin)
                                -> { ok, erro? }
     lerResponsavelPessoal(id)  só admin: -> { cpf, matricula }
     moverBens(ids, sala)       só admin (migração 007): move bens de sala -> { ok, movidos, movimento_id } ou { ok:false, erro }
     mesclarSalas(origem, destino)  só admin: move os bens e marca a origem como 'mesclada' -> { ok, movidos, movimento_id }
     desfazerMovimento(id)      só admin: desfaz um dos dois acima -> { ok, restaurados, pulados } ou { ok:false, erro }
     listarMovimentos()         só admin: -> [{ id, tipo, feito_em, feito_por, desfeito_em, origem, destino, quantidade }]
     exportarBensPagina(apos, limite, pessoais)  só admin (migração 008): bens direto do banco, em páginas
                                -> { itens:[{ id, etiquetas, sala, coordenacao, ... }], mais, ultimo }; pessoais=true traz nome/matrícula/CPF
     listarUsuarios()           só admin (migração 009): -> [{ id, nome, sigla, email, papel, ativo, aprovado_em, deve_trocar_senha, criado_em }]
     alterarUsuario(id, acao)   só admin: acao = 'ativar' | 'desativar' | 'tornar_admin' | 'tornar_coletor' | 'exigir_troca_senha'
                                -> { ok } ou { ok:false, erro: nao_em_si_mesmo | ultimo_admin | usuario_inativo | usuario_inexistente | acao_invalida }
     moverBem(bem, sala)        qualquer usuário ativo (migração 010): move UM bem já no servidor -> { ok, movidos } ou { ok:false, erro }
     baixarCatalogoLegado()     bens do catálogo legado com plaqueta antiga (migração 010; no banco: tabela siads_bens, nome histórico
                                do esquema): -> [{ a: plaqueta, s: nº do catálogo, i: item, d: descrição,
                                m: item material, r: plaqueta repetida no catálogo }]; servidor sem a 010: 404 (o app ignora)
     baixarPlanilha()           lista de consulta (migração 005): -> [{ numero, tipo, marca, coordenacao, andar, localidade }]
                                Servidor sem a 005: erro 404 (o app ignora e segue)
     baixarUnidades()           unidades e responsáveis p/ preencher a criação de sala (migração 006):
                                -> [{ sigla, uorg, denominacao, siorg, responsavel, matricula, cpf }]
                                matricula e cpf só vêm preenchidos para o administrador; servidor sem a 006: 404 (ignorado)

   Erros lançados trazem uma destas marcas: .rede (sem conexão/tempo esgotado), .auth (sessão inválida), .permissao (403),
   ou .http (status). O motor de sincronização decide o que fazer com cada uma. */

// ---------- adaptador "nenhum" (app só local) ----------
const AdaptadorNenhum = {
  nome: 'nenhum',
  configurado: () => false,
  erroConfig: null,
  restaurar() {}, sessao: () => null, persistir: null,
  async entrar() { throw new Error('Sem servidor configurado.'); },
  async sair() {}, async trocarSenha() { throw new Error('Sem servidor configurado.'); },
  async meuPerfil() { return null; }, async criarPerfil() { return { ok: false, erro: 'sem_servidor' }; },
  async senhaTrocada() { return { ok: false, erro: 'sem_servidor' }; },
  async enviarLote() { return { salas: [], bens: [], etiquetas: [], anulacoes: [], adiados: [] }; },
  async baixarMudancas(c) { return { agora: c || null, salas: [], tipos: [], localidades: [], descricoes: [], indice: [], sem_max: 0 }; },
  async baixarPagina(tabela, desde) { return { agora: desde || null, itens: [], mais: false, ultimo: null, sem_max: 0 }; },
  async atualizarSala() { return { ok: false, erro: 'sem_servidor' }; },
  async lerResponsavelPessoal() { return { cpf: '', matricula: '' }; },
  async moverBens() { return { ok: false, erro: 'sem_servidor' }; }, async mesclarSalas() { return { ok: false, erro: 'sem_servidor' }; },
  async desfazerMovimento() { return { ok: false, erro: 'sem_servidor' }; }, async listarMovimentos() { return []; },
  async exportarBensPagina() { return { itens: [], mais: false, ultimo: null }; },
  async listarUsuarios() { return []; }, async alterarUsuario() { return { ok: false, erro: 'sem_servidor' }; },
  async moverBem() { return { ok: false, erro: 'sem_servidor' }; }, async baixarCatalogoLegado() { return []; },
  async baixarPlanilha() { return []; },
  async baixarUnidades() { return []; }
};

// ---------- adaptador Supabase (REST: sem supabase-js, sem CDN) ----------
function lerConfig() {
  const c = window.APP_CONFIG || {};
  const url = String(c.SUPABASE_URL || '').trim().replace(/\/+$/, '');
  const key = String(c.SUPABASE_PUBLISHABLE_KEY || '').trim();
  if (!url && !key) return { cfg: null, erro: null };                    // config.js ausente: modo local
  if (!/^https:\/\//.test(url) || !key || /COLE_AQUI/i.test(url + key)) return { cfg: null, erro: 'config.js incompleto (URL e chave publishable).' };
  // trava de segurança: nunca aceitar chave secreta no navegador
  let papel = '';
  try { papel = JSON.parse(atob(key.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).role || ''; } catch {}
  if (/^sb_secret_/.test(key) || papel === 'service_role') return { cfg: null, erro: 'CHAVE SECRETA no config.js. Remova-a: use somente a chave publishable.' };
  return { cfg: { url, key }, erro: null };
}

function criarAdaptadorSupabase(cfg) {
  let sessao = null, renovando = null;
  const A = {
    nome: 'supabase', erroConfig: null, persistir: null,
    configurado: () => true,
    sessao: () => sessao,
    restaurar(s) { sessao = s || null; }
  };
  const cab = token => ({ 'Content-Type': 'application/json', apikey: cfg.key, ...(token ? { Authorization: 'Bearer ' + token } : {}) });

  async function req(caminho, { metodo = 'POST', corpo, token, timeout = 15000 } = {}) {
    const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), timeout);
    let res;
    try {
      res = await fetch(cfg.url + caminho, { method: metodo, headers: cab(token), body: corpo === undefined ? undefined : JSON.stringify(corpo), signal: ctl.signal });
    } catch (e) {
      const err = new Error(e && e.name === 'AbortError' ? 'tempo esgotado (15 s)' : 'sem conexão'); err.rede = true; throw err;
    } finally { clearTimeout(t); }
    let dados = null; try { dados = await res.json(); } catch {}
    if (!res.ok) {
      const err = new Error((dados && (dados.message || dados.msg || dados.error_description || dados.error)) || 'HTTP ' + res.status);
      err.http = res.status; err.dados = dados;
      if (res.status === 403) err.permissao = true;
      throw err;
    }
    return dados;
  }
  async function guardar(d) {
    sessao = { access_token: d.access_token, refresh_token: d.refresh_token, expira_em: Date.now() + (d.expires_in || 3600) * 1000, usuario: { id: d.user.id, email: d.user.email } };
    if (A.persistir) await A.persistir(sessao);
  }
  function renovar() {
    if (!sessao) { const e = new Error('sem sessão'); e.auth = true; return Promise.reject(e); }
    if (!renovando) {
      renovando = req('/auth/v1/token?grant_type=refresh_token', { corpo: { refresh_token: sessao.refresh_token } })
        .then(async d => { await guardar(d); return sessao; })
        .catch(e => { if (e.http === 400 || e.http === 401 || e.http === 403) e.auth = true; throw e; })
        .finally(() => { renovando = null; });
    }
    return renovando;
  }
  async function token() {
    if (!sessao) { const e = new Error('sem sessão'); e.auth = true; throw e; }
    return sessao.expira_em - Date.now() > 60000 ? sessao.access_token : (await renovar()).access_token;
  }
  async function reqAuth(caminho, opcoes = {}) {
    try { return await req(caminho, { ...opcoes, token: await token() }); }
    catch (e) {
      if (e.http === 401) { const s = await renovar(); return req(caminho, { ...opcoes, token: s.access_token }); }   // token recusado: renova uma vez
      throw e;
    }
  }
  const rpc = (fn, args) => reqAuth('/rest/v1/rpc/' + fn, { corpo: args || {} });

  A.entrar = async (email, senha) => {
    try {
      const d = await req('/auth/v1/token?grant_type=password', { corpo: { email: String(email).trim(), password: senha } });
      await guardar(d); return sessao.usuario;
    } catch (e) {
      if (e.http === 400 || e.http === 401) e.message = 'E-mail ou senha incorretos.';
      throw e;
    }
  };
  A.sair = async () => {
    try { if (sessao) await req('/auth/v1/logout?scope=local', { token: sessao.access_token, timeout: 5000 }); } catch {}
    sessao = null; if (A.persistir) await A.persistir(null);
  };
  A.trocarSenha = async (atual, nova) => {
    const email = sessao && sessao.usuario.email;
    await A.entrar(email, atual);                                                    // confere a senha atual
    await reqAuth('/auth/v1/user', { metodo: 'PUT', corpo: { password: nova } });
  };
  A.meuPerfil = () => rpc('meu_perfil');
  A.criarPerfil = (nome, sigla) => rpc('criar_perfil', { p_nome: nome, p_sigla: sigla });
  A.senhaTrocada = () => rpc('senha_trocada');
  A.enviarLote = lote => rpc('sincronizar_lote', { p_lote: lote });
  A.baixarMudancas = cursor => rpc('puxar_mudancas', { p_desde: cursor || null });          // tudo de uma vez (servidor sem a migração 003)
  A.baixarPagina = (tabela, desde, apos, limite) => rpc('puxar_pagina', { p_tabela: tabela, p_desde: desde || null, p_apos: apos || null, p_limite: limite || 2000 });
  A.atualizarSala = sala => rpc('atualizar_sala', { p_sala: sala });
  A.lerResponsavelPessoal = id => rpc('ler_responsavel_pessoal', { p_sala: id });
  A.moverBens = (ids, sala) => rpc('mover_bens', { p_bem_ids: ids, p_sala_destino: sala });
  A.mesclarSalas = (origem, destino) => rpc('mesclar_salas', { p_origem: origem, p_destino: destino });
  A.desfazerMovimento = id => rpc('desfazer_movimento', { p_id: id });
  A.listarMovimentos = () => rpc('listar_movimentos', { p_limite: 30 });
  A.exportarBensPagina = (apos, limite, pessoais) => rpc('exportar_bens_pagina', { p_apos: apos || null, p_limite: limite || 1000, p_pessoais: !!pessoais });
  A.listarUsuarios = () => rpc('listar_usuarios');
  A.alterarUsuario = (id, acao) => rpc('alterar_usuario', { p_id: id, p_acao: acao });
  A.moverBem = (bem, sala) => rpc('mover_bem', { p_bem: bem, p_sala: sala });
  A.baixarCatalogoLegado = () => rpc('listar_siads_antigas');          // nome histórico da função no banco
  A.baixarPlanilha = () => rpc('listar_patrimonio_planilha');
  A.baixarUnidades = () => rpc('listar_unidades_responsaveis');
  return A;
}

const _cfg = lerConfig();
const RemoteAdapters = { nenhum: AdaptadorNenhum, supabase: _cfg.cfg ? criarAdaptadorSupabase(_cfg.cfg) : null };
const ADAPTADOR_ATIVO = RemoteAdapters.supabase ? 'supabase' : 'nenhum';
const Remote = RemoteAdapters[ADAPTADOR_ATIVO];
if (ADAPTADOR_ATIVO === 'nenhum') Remote.erroConfig = _cfg.erro;
