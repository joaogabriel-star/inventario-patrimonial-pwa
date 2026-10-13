'use strict';
/* Motor de sincronização offline-first. Independe do backend: só fala com `Remote` (remote-adapter.js).

   Como funciona (resumo):
   - Cada registro local elegível (criado depois do primeiro login neste aparelho) tem uma linha no "outbox" (IndexedDB)
     com estado pendente / erro / ok. As linhas são DERIVADAS do estado local ("reconciliar"), então nenhum evento se
     perde se o app fechar, a bateria acabar ou o celular reiniciar no meio.
   - O registro local NUNCA é apagado, nem depois de "ok".
   - Envio em lotes de 50 (salas, bens, etiquetas, anulações, nessa ordem), com tempo limite de 15 s e reenvio com backoff.
     O servidor é idempotente: reenviar não duplica.
   - Dados salvos antes do primeiro login (testes) não entram na fila.
   Funções usadas de app.js: getAll, getMeta, setMeta, writeMany, reload, S, uuid, nowISO, fmtBR, modal, confirmBox, toast ... */

const Sync = {
  afterWrite() { Engine.notificar(); }     // chamado por writeMany depois de gravar algo localmente
};

const Engine = (() => {
  const est = {
    ligado: false, logado: false, perfil: null, rodando: false, refazer: false,
    ultima: null, erro: '', cont: { ok: 0, pendente: 0, erro: 0 }, proxima: 0, falhas: 0, ultimoPull: 0,
    okIds: new Set(), precisaLogin: false, redeOk: null,     // redeOk: null = ainda não tentou; true/false = resultado da última tentativa
    recarregar: false
  };
  const ORDEM = { salas: 0, bens: 1, etiquetas: 2, anulacoes: 3 };
  const q = s => document.querySelector(s);
  let debounce = null;

  // ---------- contagem e faixa do topo ----------
  async function recontar() {
    const ob = await getAll('outbox');
    est.cont = { ok: 0, pendente: 0, erro: 0 }; est.okIds = new Set();
    for (const o of ob) {
      if (o.estado === 'ok') { est.cont.ok++; est.okIds.add(o.id); }
      else if (o.estado === 'erro') est.cont.erro++;
      else est.cont.pendente++;
    }
  }
  // faixa do topo: estado real da conexão com o servidor
  function desenharModo() {
    const m = q('#statusModo'); if (!m) return;
    let txt, cls = 'chip';
    if (!est.ligado) txt = 'Modo local (sem servidor)';
    else if (!est.logado || est.precisaLogin) { txt = 'Servidor: entre para conectar'; cls += ' bad'; }
    else if (!navigator.onLine || est.redeOk === false) { txt = 'Sem conexão (trabalhando offline)'; cls += ' warn'; }
    else if (est.redeOk === true) { txt = 'Servidor conectado'; cls += ' good'; }
    else txt = 'Conectando ao servidor…';
    m.textContent = txt; m.className = cls;
  }
  function desenhar() {
    desenharModo();
    const chip = q('#statusSync'); if (!chip) return;
    if (!est.ligado) { chip.hidden = true; return; }
    chip.hidden = false;
    const c = est.cont; let txt, cls = 'chip chip-btn';
    if (!est.logado) { txt = '☁ não conectado — toque para entrar'; cls += ' bad'; }
    else if (!est.perfil) { txt = '☁ sem perfil — não sincroniza'; cls += ' bad'; }
    else if (!est.perfil.ativo) { txt = est.perfil.aprovado_em ? '☁ usuário desativado' : '☁ aguardando aprovação do administrador'; cls += ' bad'; }
    else if (est.perfil.deve_trocar_senha) { txt = '☁ troque a senha para continuar'; cls += ' bad'; }
    else {
      const hora = est.ultima ? fmtBR(est.ultima).slice(11, 16) : '—';
      txt = `☁ ✔ ${c.ok} · ⏳ ${c.pendente} · ⚠ ${c.erro} · ${est.rodando ? (est.pullTexto ? 'baixando ' + est.pullTexto : 'sincronizando…') : 'última ' + hora}`;
      if (est.erroPull && !est.rodando) txt += ' · ⚠ listas desatualizadas';       // M-6: falha do pull não passa em silêncio
      cls += (c.erro || est.precisaLogin || (est.erroPull && !est.rodando)) ? ' bad' : c.pendente ? '' : ' good';
    }
    chip.textContent = txt; chip.className = cls;
  }

  // ---------- fila: derivada do estado local ----------
  async function reconciliar() {
    const dono = await getMeta('sync_user_id');
    const [salas, bens, ob] = await Promise.all([getAll('salas'), getAll('bens'), getAll('outbox')]);
    const ctx = { salas: new Map(salas.map(s => [s.id, s])), bens: new Map(bens.map(b => [b.id, b])), etq: new Map(), dono };
    for (const b of bens) for (const e of b.etiquetas || []) if (e.id) ctx.etq.set(e.id, { bem_id: b.id, e });
    if (!dono) { await recontar(); return ctx; }                    // ainda sem vínculo com o servidor: nada é elegível
    const tem = new Set(ob.map(o => o.id)), novos = [], bensAlterados = [];
    const add = (tabela, registroId, id = tabela + ':' + registroId) => {
      if (tem.has(id)) return; tem.add(id);
      novos.push({ id, tabela, registro_id: registroId, estado: 'pendente', tentativas: 0, ultimo_erro: '', criado_em: nowISO() });
    };
    // Elegibilidade = marca gravada NA CRIAÇÃO (elegivel_sync), e não comparação de horas: o relógio do celular
    // pode andar para trás e deixar registros novos de fora sem aviso (auditoria A-1).
    for (const s of salas) if (!s.servidor && s.elegivel_sync) add('salas', s.id);
    for (const b of bens) {
      if (!b.elegivel_sync || b.servidor) continue;                    // teste anterior ao vínculo, ou bem de OUTRO usuário/aparelho vindo do pull: nunca é reenviado
      const sala = ctx.salas.get(b.sala_id);
      if (sala && !sala.servidor) add('salas', sala.id);               // a sala do bem precisa existir no servidor
      add('bens', b.id);
      let mudou = false;
      for (const e of b.etiquetas || []) { if (!e.id) { e.id = uuid(); mudou = true; ctx.etq.set(e.id, { bem_id: b.id, e }); } add('etiquetas', e.id); }
      if (mudou) bensAlterados.push(['bens', b]);
      if (b.situacao === 'anulado' && b.anulado_em) add('anulacoes', b.id, 'anulacoes:' + b.id + '@' + b.anulado_em);
    }
    const ents = [...novos.map(o => ['outbox', o]), ...bensAlterados];
    if (ents.length) await writeMany(ents, { silencioso: true });
    await recontar();
    return ctx;
  }

  // Uma vez só (aparelhos que já usavam a v0.5): registros criados depois do primeiro login, que ainda não têm a
  // marca elegivel_sync, ganham a marca pela regra antiga (data >= sync_inicio). Depois disso, só vale a marca.
  async function migrarElegibilidade() {
    if (await getMeta('elegivel_migrado')) return;
    const inicio = await getMeta('sync_inicio'), ents = [];
    if (inicio) {
      for (const s of await getAll('salas')) if (!s.servidor && s.elegivel_sync === undefined && s.criado_em >= inicio) ents.push(['salas', { ...s, elegivel_sync: true }]);
      for (const b of await getAll('bens')) if (!b.servidor && b.elegivel_sync === undefined && b.criado_em >= inicio) ents.push(['bens', { ...b, elegivel_sync: true }]);
    }
    ents.push(['meta', { k: 'elegivel_migrado', v: true }]);
    await writeMany(ents, { silencioso: true });
    if (inicio) await reload();
  }

  // M-1: o servidor disse que a anulação ficou para trás de uma restauração do administrador: o bem volta a "ativo"
  async function reverterAnulacaoLocal(bemId, restauradoEm) {
    const b = await getOne('bens', bemId);
    if (!b || b.situacao !== 'anulado') return;
    const agora = nowISO();
    b.situacao = 'ativo'; b.atualizado_em = agora; b.restaurado_em = restauradoEm;
    (b.eventos ||= []).push({ em: agora, usuario: 'servidor', acao: 'restaurado_pelo_administrador', restaurado_em: restauradoEm });
    await writeMany([['bens', b], ['auditoria', { id: uuid(), em: agora, usuario: S.user, sigla: S.sigla, dispositivo: S.device, acao: 'anulacao_ignorada_pelo_servidor', detalhe: { bem: bemId, restaurado_em: restauradoEm } }]], { silencioso: true });
    est.recarregar = true;
  }

  function montarItem(o, ctx) {
    if (o.tabela === 'salas') {
      const s = ctx.salas.get(o.registro_id); if (!s) return null;
      const r = s.responsavel || {}, c = S.coords.find(x => x.id === s.coordenacao_id);
      return { id: s.id, nome: s.nome, coordenacao: c ? c.nome : '', uorg: s.uorg || '', andar: s.andar || '', localidade: s.localidade || '',
        responsavel_nome: r.nome || '', responsavel_siorg: r.siorg || '', responsavel_uorg: r.uorg || '',
        responsavel_cpf: r.cpf || '', responsavel_matricula: r.matricula || '', legado: s.legado || null, origem: 'campo', criado_em: s.criado_em };
    }
    if (o.tabela === 'bens') {
      const b = ctx.bens.get(o.registro_id); if (!b) return null;
      return { id: b.id, sala_id: b.sala_id, tipo_bem: b.tipo_bem || '', tipo_bem_outro: b.tipo_bem_outro || '', descricao: b.descricao || '',
        item_material: b.item_material || '', descricao_origem: b.descricao_origem || '', marca: b.marca || '', fornecedor: b.fornecedor || '',
        observacao: b.observacao || '', etiquetado_em_campo: !!b.etiquetado_em_campo, codigo_provisorio: b.codigo_provisorio || null, registrado_em: b.criado_em };
    }
    if (o.tabela === 'etiquetas') {
      const x = ctx.etq.get(o.registro_id); if (!x) return null;
      return { id: x.e.id, bem_id: x.bem_id, numero: x.e.numero, serie: x.e.serie, origem: x.e.origem || 'manual', simbologia: x.e.simbologia || '', registrado_em: (ctx.bens.get(x.bem_id) || {}).criado_em };
    }
    const b = ctx.bens.get(o.registro_id); if (!b) return null;           // anulacoes
    return { bem_id: b.id, motivo: b.motivo_anulacao || '', em: b.anulado_em };
  }

  const gravarOutbox = rows => writeMany(rows.map(r => ['outbox', r]), { silencioso: true });

  async function enviarLote(lote, ctx) {
    const payload = { dispositivo_id: S.device, salas: [], bens: [], etiquetas: [], anulacoes: [] };
    const validos = [], atualizacoes = [];
    for (const o of lote) {
      const it = montarItem(o, ctx);
      if (!it) atualizacoes.push({ ...o, estado: 'erro', ultimo_erro: 'registro local ausente', tentativas: (o.tentativas || 0) + 1 });
      else { payload[o.tabela].push(it); validos.push(o); }
    }
    if (validos.length) {
      let r;
      try { r = await Remote.enviarLote(payload); }
      catch (e) {
        if (e.rede || e.auth || e.permissao) { if (atualizacoes.length) await gravarOutbox(atualizacoes); throw e; }   // continua pendente
        if (validos.length > 1) {                                       // lote recusado: isola o item problemático
          for (const o of validos) await enviarLote([o], ctx);
          if (atualizacoes.length) await gravarOutbox(atualizacoes);
          return;
        }
        atualizacoes.push({ ...validos[0], estado: 'erro', ultimo_erro: e.message, tentativas: (validos[0].tentativas || 0) + 1 });
        await gravarOutbox(atualizacoes); return;
      }
      const ack = { salas: new Set(r.salas || []), bens: new Set(r.bens || []), etiquetas: new Set(r.etiquetas || []), anulacoes: new Set(r.anulacoes || []) };
      const adiados = new Map((r.adiados || []).map(a => [a.tabela + ':' + a.id, a.motivo]));
      const ignoradas = new Map((r.anulacoes_ignoradas || []).map(a => [a.bem_id, a]));
      for (const o of validos) {
        if (ack[o.tabela].has(o.registro_id)) atualizacoes.push({ ...o, estado: 'ok', ultimo_erro: '', enviado_em: nowISO(), recebido_em: r.recebido_em });
        else if (o.tabela === 'anulacoes' && ignoradas.has(o.registro_id)) {
          await reverterAnulacaoLocal(o.registro_id, ignoradas.get(o.registro_id).restaurado_em);
          atualizacoes.push({ ...o, estado: 'ok', ultimo_erro: 'ignorada: bem restaurado pelo administrador', enviado_em: nowISO() });
        } else {
          const m = adiados.get(o.tabela + ':' + o.registro_id);
          if (m) atualizacoes.push({ ...o, estado: 'erro', ultimo_erro: m, tentativas: (o.tentativas || 0) + 1 });
        }
      }
    }
    if (atualizacoes.length) await gravarOutbox(atualizacoes);
  }

  async function enviarTudo(ctx) {
    const visitados = new Set();
    for (;;) {
      const fila = (await getAll('outbox')).filter(o => o.estado !== 'ok' && !visitados.has(o.id))
        .sort((a, b) => ORDEM[a.tabela] - ORDEM[b.tabela] || (a.criado_em < b.criado_em ? -1 : 1));
      if (!fila.length) return;
      const lote = fila.slice(0, 50); lote.forEach(o => visitados.add(o.id));
      await enviarLote(lote, ctx);
      await recontar(); desenhar();
    }
  }

  // ---------- pull ----------
  // opc.soGravar: página intermediária do índice (grande): só grava, sem recarregar tudo na memória a cada página
  async function aplicarPull(r, opc = {}) {
    const ents = [];
    const tiposLocal = new Map(S.tipos.map(t => [normSimples(t.nome), t]));
    for (const t of r.tipos || []) {
      const l = tiposLocal.get(normSimples(t.nome));
      if (!l) ents.push(['tipos', { id: t.id, nome: t.nome, ativo: t.ativo, usos: 0, servidor: true }]);
      else if (l.ativo !== t.ativo) ents.push(['tipos', { ...l, ativo: t.ativo }]);
    }
    const locLocal = new Map(S.localidades.map(l => [l.nome_norm, l]));
    for (const l of r.localidades || []) {
      const k = normSimples(l.nome), x = locLocal.get(k);
      if (!x) ents.push(['localidades', { id: l.id, nome: l.nome, nome_norm: k, ativo: l.ativo, servidor: true }]);
      else if (x.ativo !== l.ativo) ents.push(['localidades', { ...x, ativo: l.ativo }]);
    }
    const chaveDesc = d => `${d.tipo_norm}|${d.texto_norm}|${d.item_material || ''}`;
    const descLocal = new Map(S.descricoes.map(d => [chaveDesc(d), d]));
    for (const d of r.descricoes || []) {
      const novo = { tipo: d.tipo, tipo_norm: normSimples(d.tipo), texto: d.texto, texto_norm: normSimples(d.texto), item_material: d.item_material || '' };
      const x = descLocal.get(chaveDesc(novo));
      if (!x) ents.push(['descricoes', { id: d.id, ...novo, ativo: d.ativo, origem: d.origem, servidor: true }]);
      else if (x.ativo !== d.ativo) ents.push(['descricoes', { ...x, ativo: d.ativo }]);
    }
    const coordPorNome = new Map(S.coords.map(c => [normSimples(c.nome), c]));
    const salasLocal = new Map(S.salas.map(s => [s.id, s]));
    for (const s of r.salas || []) {
      let c = null;
      if (s.coordenacao) {
        const k = normSimples(s.coordenacao); c = coordPorNome.get(k);
        if (!c) { c = { id: uuid(), nome: s.coordenacao, nome_norm: k, criado_em: nowISO(), criado_por: 'servidor' }; coordPorNome.set(k, c); ents.push(['coordenacoes', c]); }
      }
      const base = { nome: s.nome, nome_norm: norm(s.nome), coordenacao_id: c ? c.id : null, uorg: s.uorg || '', andar: s.andar || '', localidade: s.localidade || '', status: s.status, mesclada_em_id: s.mesclada_em_id || null };
      if (s.legado) base.legado = s.legado;
      const resp = { nome: s.responsavel_nome || '', siorg: s.responsavel_siorg || '', uorg: s.responsavel_uorg || '' };
      const l = salasLocal.get(s.id);
      if (l) ents.push(['salas', { ...l, ...base, responsavel: { ...(l.responsavel || {}), ...resp } }]);      // mantém CPF/matrícula locais, se houver
      else ents.push(['salas', { id: s.id, ...base, responsavel: { ...resp, cpf: '', matricula: '' }, criado_em: s.recebido_em, criado_por: 'servidor', servidor: true }]);
    }
    // Bens de TODOS os usuários (v0.6.1). Os que não existem aqui entram marcados `servidor: true` e NUNCA são reenviados
    // (sem `elegivel_sync`): o servidor é a fonte da verdade deles. Bem que já é meu: só se completa o que veio de fora.
    const bensLocal = new Map(S.bens.map(b => [b.id, b]));
    for (const x of r.bens || []) {
      const doServ = (x.etiquetas || []).map(e => ({ id: e.id, numero: e.numero, serie: e.serie, origem: e.origem || 'manual', simbologia: e.simbologia || '', servidor: true }));
      const l = bensLocal.get(x.id);
      if (!l || l.servidor) {
        const idsServ = new Set(doServ.map(e => e.id));
        const extras = l ? (l.etiquetas || []).filter(e => !e.servidor && !idsServ.has(e.id)) : [];
        ents.push(['bens', { ...(l || {}), id: x.id, etiquetas: [...doServ, ...extras], codigo_provisorio: x.codigo_provisorio || null, etiquetado_em_campo: !!x.etiquetado_em_campo,
          tipo_bem: x.tipo_bem || '', tipo_bem_outro: x.tipo_bem_outro || '', marca: x.marca || '', fornecedor: x.fornecedor || '',
          descricao: x.descricao || '', item_material: x.item_material || '', descricao_origem: x.descricao_origem || '',
          sala_id: x.sala_id, observacao: x.observacao || '', situacao: x.situacao || 'ativo',
          motivo_anulacao: x.motivo_anulacao || '', anulado_em: x.anulado_em || null,
          criado_por: x.usuario_nome || x.usuario_sigla || '', sigla: x.usuario_sigla || '', criado_em: x.registrado_em || x.recebido_em,
          atualizado_em: x.recebido_em, eventos: (l && l.eventos) || [], servidor: true }]);
        continue;
      }
      let mudou = false;                                                // bem meu (criado neste aparelho): completa etiquetas e anulação vindas de fora
      if (x.sala_id && x.sala_id !== l.sala_id) { l.sala_id = x.sala_id; mudou = true; }       // o administrador moveu o bem para outra sala (ou mesclou salas)
      const ids = new Set((l.etiquetas || []).map(e => e.id).filter(Boolean));
      for (const e of doServ) if (!ids.has(e.id)) { (l.etiquetas ||= []).push(e); mudou = true; }
      if (x.situacao === 'anulado' && l.situacao === 'ativo') {
        Object.assign(l, { situacao: 'anulado', motivo_anulacao: x.motivo_anulacao || '', anulado_em: x.anulado_em || nowISO() }); mudou = true;
      }
      if (mudou) ents.push(['bens', l]);
    }
    for (const e of r.indice || []) ents.push(['indice', e]);
    if (S.sigla) {                                                      // contador SEM = max(local, servidor)
      const k = 'sem_seq_' + S.sigla, local = (await getMeta(k)) || 0, mx = Math.max(local, Number(r.sem_max) || 0);
      if (mx !== local) ents.push(['meta', { k, v: mx }]);
      semSeqCache[S.sigla] = mx;
    }
    if (ents.length) await writeMany(ents, { silencioso: true });
    if (opc.soGravar) return;
    S.indiceCarregado = false; await reload();
    if (typeof refreshUI === 'function') refreshUI();
  }

  // M-6: o pull vem em PÁGINAS (2.000 itens por chamada, por tabela, na ordem do id). Cada página é aplicada ao chegar, e o
  // ponto onde parou fica guardado (pull_progresso): se a conexão cair no meio, a próxima rodada continua dali. O cursor
  // (pull_cursor) só avança quando TODAS as páginas foram aplicadas. Aplicar duas vezes é inofensivo (gravação por id).
  // 'bens' vem DEPOIS de 'salas' (o bem aponta para a sala). Páginas de bens são menores: cada bem leva suas etiquetas.
  const PAGINA = 2000, PAGINA_BENS = 500, TABELAS_PULL = ['tipos', 'localidades', 'salas', 'descricoes', 'bens', 'indice'];
  const ROTULO_PULL = { tipos: 'tipos', localidades: 'localidades', salas: 'salas', descricoes: 'descrições', bens: 'bens de outros aparelhos', indice: 'números de outros aparelhos', meta: 'finalizando' };
  const gravarProgresso = p => writeMany([['meta', { k: 'pull_progresso', v: p }]], { silencioso: true });
  async function puxarPaginado(desde) {
    let ped = await getMeta('pull_progresso');                          // { desde, agora, tabela, apos, baixados }
    if (!ped || (ped.desde || null) !== desde) ped = { desde, agora: null, tabela: TABELAS_PULL[0], apos: null, baixados: 0 };
    let i0 = TABELAS_PULL.indexOf(ped.tabela); if (i0 < 0) i0 = TABELAS_PULL.length;      // 'meta' = só falta a etapa final
    for (let i = i0; i < TABELAS_PULL.length; i++) {
      const tabela = TABELAS_PULL[i];
      let apos = tabela === ped.tabela ? ped.apos : null;
      for (;;) {
        est.pullTexto = `listas: ${ROTULO_PULL[tabela]} (${ped.baixados})`; desenhar();
        let r;
        try { r = await Remote.baixarPagina(tabela, desde, apos, tabela === 'bens' ? PAGINA_BENS : PAGINA); }
        catch (e) {
          // servidor sem a migração 004: não conhece 'bens'. Segue sem eles (o resto do pull continua normal).
          if (tabela === 'bens' && e.http === 400 && /tabela_invalida/.test(e.message || '')) { est.semBensNoServidor = true; break; }
          throw e;
        }
        if (tabela === 'bens') est.semBensNoServidor = false;
        if (!ped.agora) ped.agora = r.agora;
        const itens = r.itens || [];
        await aplicarPull({ [tabela]: itens }, { soGravar: (tabela === 'indice' || tabela === 'bens') && !!r.mais });
        ped = { ...ped, tabela, apos: r.mais ? r.ultimo : null, baixados: ped.baixados + itens.length };
        await gravarProgresso(ped);
        if (!r.mais) break;
        apos = r.ultimo;
      }
      ped = { ...ped, tabela: TABELAS_PULL[i + 1] || 'meta', apos: null }; await gravarProgresso(ped);
    }
    est.pullTexto = `listas: ${ROTULO_PULL.meta}`; desenhar();
    const m = await Remote.baixarPagina('meta', desde, null, 1);
    if (!ped.agora) ped.agora = m.agora;
    await aplicarPull({ sem_max: m.sem_max });
    await writeMany([['meta', { k: 'pull_cursor', v: ped.agora }], ['meta', { k: 'pull_progresso', v: null }]], { silencioso: true });   // só avança depois de aplicar tudo
  }
  // servidor sem a migração 003 (não existe puxar_pagina): usa a função antiga, de uma vez só
  async function puxarLegado(desde) {
    const r = await Remote.baixarMudancas(desde);
    await aplicarPull(r);
    await setMeta('pull_cursor', r.agora);
  }
  // Lista de consulta da planilha de patrimônio (migração 005): poucas centenas de linhas, baixada inteira. Falha aqui
  // (inclusive servidor sem a 005, erro 404) NUNCA derruba o pull: o app só deixa de preencher tipo e marca.
  async function puxarPlanilha() {
    try {
      const itens = await Remote.baixarPlanilha();
      if (Array.isArray(itens)) { await writeMany([['meta', { k: 'planilha', v: itens }]], { silencioso: true }); await carregarPlanilha(); }
    } catch (e) { if (e.http !== 404) console.warn('planilha de patrimônio não atualizou:', e && e.message); }
    try {                                                                // unidades e responsáveis (migração 006), mesma regra
      const un = await Remote.baixarUnidades();
      if (Array.isArray(un)) { await writeMany([['meta', { k: 'unidades', v: un }]], { silencioso: true }); await carregarUnidades(); }
    } catch (e) { if (e.http !== 404) console.warn('unidades não atualizaram:', e && e.message); }
    try {                                                                // catálogo legado: bens com plaqueta antiga (migração 010), mesma regra
      const sd = await Remote.baixarCatalogoLegado();
      if (Array.isArray(sd)) { await writeMany([['meta', { k: 'catalogo_legado', v: sd }]], { silencioso: true }); await carregarCatalogoLegado(); }
    } catch (e) { if (e.http !== 404) console.warn('catálogo legado não atualizou:', e && e.message); }
  }
  async function puxar() {
    const desde = (await getMeta('pull_cursor')) || null;
    try {
      try { await puxarPaginado(desde); }
      catch (e) { if (e.http === 404) await puxarLegado(desde); else throw e; }
      est.ultimoPull = Date.now(); est.erroPull = '';
      await puxarPlanilha();
    } catch (e) { est.erroPull = e.message || String(e); throw e; }       // aparece na faixa do topo e em Mais (M-6)
    finally { est.pullTexto = ''; }
  }

  // ---------- ciclo de sincronização ----------
  function tratarErro(e) {
    est.redeOk = !e.rede;                                       // erro de auth/permissão/servidor: o servidor respondeu, há rede
    if (e.rede) { est.falhas++; est.proxima = Date.now() + Math.min(300000, 2000 * 2 ** est.falhas); est.erro = 'Sem conexão. Tentando de novo automaticamente.'; }
    else if (e.auth) { est.precisaLogin = true; est.erro = 'Sessão expirada. Toque na faixa do topo para entrar de novo. Seus registros continuam guardados.'; }
    else if (e.permissao) { est.erro = 'Sem permissão no servidor (perfil ausente, desativado ou senha provisória).'; revalidarPerfil(); }
    else { est.falhas++; est.proxima = Date.now() + Math.min(300000, 2000 * 2 ** est.falhas); est.erro = e.message || String(e); }
  }
  async function sincronizar({ forcar = false, puxar: querPull = false } = {}) {
    if (!est.ligado || !est.logado || !est.perfil || !est.perfil.ativo || est.perfil.deve_trocar_senha) return;
    if (est.rodando) { est.refazer = true; return; }
    if (!forcar && Date.now() < est.proxima) return;
    est.rodando = true; desenhar();
    try {
      do {
        est.refazer = false;
        const ctx = await reconciliar();
        await enviarTudo(ctx);
        est.falhas = 0; est.proxima = 0; est.erro = ''; est.precisaLogin = false; est.redeOk = true;
      } while (est.refazer);
      if (est.recarregar) { est.recarregar = false; await reload(); if (typeof refreshUI === 'function') refreshUI(); }
      if (querPull || Date.now() - est.ultimoPull > 300000) await puxar();
      est.ultima = nowISO(); await setMeta('ultima_sync', est.ultima);
    } catch (e) { tratarErro(e); }
    finally { est.rodando = false; await recontar(); desenhar(); renderMais(); }
  }
  function notificar() {
    if (!est.ligado || !est.logado) return;
    clearTimeout(debounce); debounce = setTimeout(() => sincronizar({ forcar: true }), 400);
  }

  // ---------- login, perfil, senha ----------
  // Modos que NÃO podem ser fechados (perfil, aprovação, senha obrigatória, sem configuração): enquanto estão abertos o
  // app não deixa registrar, porque o que fosse salvo nesse estado não entraria na fila de envio.
  function abrirAuth(modo, msg = '') {
    const mapa = { login: 'authLogin', perfil: 'authPerfil', senha: 'authSenha', senhaobrig: 'authSenha', inativo: 'authInativo', semconfig: 'authInativo', aprovacao: 'authAprovacao' };
    const titulos = { login: 'Entrar', perfil: 'Seu perfil', senha: 'Trocar senha', senhaobrig: 'Troque sua senha', inativo: 'Usuário desativado', semconfig: 'Servidor não configurado', aprovacao: 'Aguardando aprovação' };
    for (const id of new Set(Object.values(mapa))) q('#' + id).hidden = true;
    q('#' + mapa[modo]).hidden = false;
    q('#authSenhaAviso').hidden = modo !== 'senhaobrig';
    q('#authTitulo').textContent = titulos[modo]; q('#authMsg').textContent = msg;
    est.authModo = modo;
    q('#authFechar').hidden = !(modo === 'senha' || modo === 'inativo' || (modo === 'login' && est.logado));
    q('#authPanel').hidden = false;
  }
  const fecharAuth = () => { q('#authPanel').hidden = true; };
  const msgAuth = t => { q('#authMsg').textContent = t; };

  async function fazerLogin() {
    const email = q('#authEmail').value.trim(), senha = q('#authSenhaAtual').value;
    if (!email || !senha) return msgAuth('Informe e-mail e senha.');
    const btn = q('#btnAuthEntrar'); btn.disabled = true; msgAuth('Entrando…');
    try {
      const u = await Remote.entrar(email, senha);
      const dono = await getMeta('sync_user_id');
      if (dono && dono !== u.id) {
        await Remote.sair(); est.logado = false;
        throw new Error('Este aparelho tem dados de outro usuário. Em Mais, use “Exportar JSON e limpar dados locais” antes de entrar com outra conta.');
      }
      est.logado = true; est.precisaLogin = false; q('#authSenhaAtual').value = '';
      await aposLogin();
    } catch (e) { msgAuth(e.message); }
    finally { btn.disabled = false; desenhar(); }
  }
  async function aposLogin() {
    let p;
    try { p = await Remote.meuPerfil(); }
    catch (e) { abrirAuth('login', e.rede ? 'Sem conexão para carregar seu perfil. Tente de novo.' : e.message); return; }
    if (!p) { q('#authNome').value = ''; q('#authSigla').value = ''; abrirAuth('perfil'); return; }
    await aplicarPerfil(p);
  }
  async function aplicarPerfil(p) {
    est.perfil = p; await setMeta('perfil', p);
    if (!p.ativo) {                                                      // A-6: perfil novo nasce inativo e o admin aprova
      desenhar(); renderMais();
      if (p.aprovado_em) abrirAuth('inativo', 'Peça ao administrador para reativar sua conta. Seus registros locais continuam guardados.');
      else abrirAuth('aprovacao', 'Seu perfil foi criado e está aguardando a aprovação do administrador. Esta tela atualiza sozinha.');
      return;
    }
    if (p.deve_trocar_senha) {                                           // M-12: senha provisória precisa ser trocada
      desenhar(); renderMais();
      abrirAuth('senhaobrig', 'Digite a senha provisória e escolha uma nova (mínimo de 10 caracteres).');
      return;
    }
    if (!(await getMeta('sync_user_id'))) await writeMany([['meta', { k: 'sync_user_id', v: p.id }], ['meta', { k: 'sync_inicio', v: nowISO() }]], { silencioso: true });
    S.syncDono = p.id;                                                   // a partir daqui, tudo que for criado é elegível
    S.user = p.nome; S.sigla = p.sigla;                                  // identidade vem do servidor
    await writeMany([['meta', { k: 'usuario', v: p.nome }], ['meta', { k: 'sigla', v: p.sigla }]], { silencioso: true });
    semSeqCache[S.sigla] = (await getMeta('sem_seq_' + S.sigla)) || 0;
    fecharAuth(); renderStatus(); syncDraftUI(); desenhar(); renderMais();
    await sincronizar({ forcar: true, puxar: true });
  }
  async function salvarPerfil() {
    const nome = q('#authNome').value.trim(), sigla = q('#authSigla').value.trim().toUpperCase();
    if (!nome) return msgAuth('Informe seu nome.');
    if (!/^[A-Z0-9]{2,4}$/.test(sigla)) return msgAuth('A sigla deve ter de 2 a 4 letras ou números.');
    const btn = q('#btnAuthPerfil'); btn.disabled = true; msgAuth('Salvando…');
    try {
      const r = await Remote.criarPerfil(nome, sigla);
      if (!r.ok) { msgAuth({ sigla_em_uso: 'Essa sigla já está em uso por outro usuário. Escolha outra.', sigla_invalida: 'Sigla inválida.', nome_vazio: 'Informe seu nome.', perfil_existente: 'Você já tem perfil. Feche e entre de novo.' }[r.erro] || 'Não foi possível criar o perfil.'); return; }
      await aplicarPerfil(r.perfil);
    } catch (e) { msgAuth(e.rede ? 'Sem conexão. Tente de novo.' : e.message); }
    finally { btn.disabled = false; }
  }
  async function trocarSenha() {
    const obrigatoria = est.authModo === 'senhaobrig';
    const atual = q('#authSenhaVelha').value, nova = q('#authSenhaNova').value, rep = q('#authSenhaRep').value;
    if (!atual || !nova) return msgAuth('Preencha a senha atual e a nova.');
    if (nova.length < 10) return msgAuth('A nova senha deve ter pelo menos 10 caracteres.');
    if (nova === atual) return msgAuth('A nova senha deve ser diferente da atual.');
    if (nova !== rep) return msgAuth('A confirmação não confere.');
    const btn = q('#btnAuthSenha'); btn.disabled = true; msgAuth('Trocando…');
    try {
      await Remote.trocarSenha(atual, nova);
      const r = await Remote.senhaTrocada();                             // o servidor confere que a senha mudou de verdade
      if (!r.ok) { msgAuth({ senha_igual: 'O servidor não detectou mudança de senha. Tente outra senha.', sem_perfil_ativo: 'Seu perfil ainda não está ativo.' }[r.erro] || 'Não foi possível confirmar a troca de senha.'); return; }
      ['authSenhaVelha', 'authSenhaNova', 'authSenhaRep'].forEach(i => (q('#' + i).value = ''));
      fecharAuth(); toast('Senha trocada.', 'ok');
      if (r.perfil) { if (obrigatoria) await aplicarPerfil(r.perfil); else { est.perfil = r.perfil; await setMeta('perfil', r.perfil); desenhar(); renderMais(); } }
    } catch (e) { msgAuth(e.rede ? 'Sem conexão. Tente de novo.' : e.message); }
    finally { btn.disabled = false; }
  }
  // consulta o perfil no servidor (aprovação do administrador, troca de senha exigida, desativação)
  async function revalidarPerfil() {
    if (!est.ligado || !est.logado) return;
    try {
      const p = await Remote.meuPerfil();
      if (!p) { est.perfil = null; desenhar(); renderMais(); return; }
      const mudou = !est.perfil || p.ativo !== est.perfil.ativo || p.deve_trocar_senha !== est.perfil.deve_trocar_senha || p.papel !== est.perfil.papel;
      if (mudou) await aplicarPerfil(p);
      else if (est.authModo === 'aprovacao') msgAuth('Ainda aguardando aprovação.');
    } catch { /* sem conexão: tenta de novo no próximo ciclo */ }
  }
  // logout/limpeza só sem pendências (nada é perdido: o que não foi confirmado fica no aparelho)
  async function pendentes() { await reconciliar(); return est.cont.pendente + est.cont.erro; }
  async function sair() {
    const p = await pendentes();
    if (p > 0) {
      await modal({ title: 'Não dá para sair agora', msg: `Há ${p} registro(s) ainda não confirmados no servidor.\nConecte-se à internet e use “Sincronizar agora”. Nada se perde: eles continuam guardados neste aparelho.`, okLabel: 'Entendi', cancel: false });
      return;
    }
    if (!(await confirmBox('Sair da conta', 'Os dados continuam neste aparelho. Para voltar a usar o app você precisará entrar de novo.', 'Sair'))) return;
    await Remote.sair(); est.logado = false; desenhar(); renderMais(); abrirAuth('login');
  }

  // ---------- tela Mais ----------
  function renderMais() {
    const info = q('#syncInfo'); if (!info) return;
    const ids = ['btnSyncAgora', 'btnLogin', 'btnSenha', 'btnSair'];
    if (!est.ligado) {
      info.textContent = Remote.erroConfig || 'Servidor não configurado (falta o config.js). O app funciona só neste aparelho.';
      ids.forEach(i => (q('#' + i).hidden = true)); return;
    }
    const c = est.cont, p = est.perfil;
    info.innerHTML = est.logado
      ? `Conta: <b>${esc((p && p.nome) || '—')}</b>${p ? ` (${esc(p.sigla)} · ${esc(p.papel)})` : ''}${p && !p.ativo ? (p.aprovado_em ? ' — <b>desativado</b>' : ' — <b>aguardando aprovação</b>') : ''}<br>` +
        `Confirmados no servidor: <b>${c.ok}</b> · pendentes: <b>${c.pendente}</b> · com erro: <b>${c.erro}</b><br>` +
        `Última sincronização: <b>${est.ultima ? esc(fmtBR(est.ultima)) : 'nunca'}</b>${est.erro ? `<br><span class="dup">⚠ ${esc(est.erro)}</span>` : ''}` +
        (est.semBensNoServidor ? '<br><span class="small">ℹ O servidor ainda não tem a migração 004: este aparelho não mostra os bens registrados em outros aparelhos.</span>' : '') +
        (est.erroPull ? `<br><span class="dup">⚠ As listas e o aviso de duplicidade de outros aparelhos NÃO atualizaram: ${esc(est.erroPull)}. Seus registros não foram afetados; toque em “Sincronizar agora” para tentar de novo.</span>` : '')
      : 'Você não está conectado. Entre para sincronizar.';
    q('#btnSyncAgora').hidden = !est.logado; q('#btnSenha').hidden = !est.logado; q('#btnSair').hidden = !est.logado; q('#btnLogin').hidden = est.logado;
    const tu = q('#btnTrocarUser'); if (tu) tu.hidden = true;                  // com servidor, nome e sigla vêm do perfil
  }

  // ---------- início ----------
  async function iniciar() {
    est.ligado = Remote.configurado();
    if (!est.ligado) {
      desenhar(); renderMais(); if (Remote.erroConfig) toast(Remote.erroConfig, 'err', 8000);
      // A-2: aparelho que já falou com o servidor, mas o app abriu sem config.js (deploy sem variáveis): bloqueia o registro
      if (await getMeta('sync_user_id')) abrirAuth('semconfig', 'Este aparelho já foi usado com o servidor, mas o app abriu SEM a configuração (config.js). NÃO registre nada agora: avise o administrador. Seus dados continuam guardados no aparelho.');
      return;
    }
    await migrarElegibilidade();
    Remote.persistir = s => writeMany([['meta', { k: 'sessao', v: s || null }]], { silencioso: true });
    const s = await getMeta('sessao'); if (s) Remote.restaurar(s);
    est.logado = !!s; est.perfil = (await getMeta('perfil')) || null; est.ultima = (await getMeta('ultima_sync')) || null;
    await recontar(); desenhar(); renderMais();

    q('#statusSync').onclick = () => (est.logado ? showTab('mais') : abrirAuth('login'));
    q('#btnAuthEntrar').onclick = fazerLogin; q('#btnAuthPerfil').onclick = salvarPerfil; q('#btnAuthSenha').onclick = trocarSenha;
    q('#authFechar').onclick = fecharAuth; q('#btnAuthVerificar').onclick = () => { msgAuth('Verificando…'); revalidarPerfil(); };
    q('#authSenhaAtual').onkeydown = e => { if (e.key === 'Enter') fazerLogin(); };
    q('#authNome').oninput = e => { if (!q('#authSigla').value) q('#authSigla').placeholder = siglaSugerida(e.target.value); };
    q('#btnSyncAgora').onclick = () => sincronizar({ forcar: true, puxar: true });
    q('#btnLogin').onclick = () => abrirAuth('login'); q('#btnSenha').onclick = () => abrirAuth('senha'); q('#btnSair').onclick = sair;
    window.addEventListener('online', () => { desenhar(); sincronizar({ forcar: true, puxar: true }); });
    window.addEventListener('offline', desenhar);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) sincronizar({ forcar: true }); });
    setInterval(() => {
      sincronizar({});
      if (est.perfil && (!est.perfil.ativo || est.perfil.deve_trocar_senha)) revalidarPerfil();     // detecta a aprovação sozinho
    }, 30000);

    if (!est.logado) { abrirAuth('login'); return; }
    if (!est.perfil) { await aposLogin(); return; }
    if (!est.perfil.ativo) {
      abrirAuth(est.perfil.aprovado_em ? 'inativo' : 'aprovacao', est.perfil.aprovado_em ? 'Peça ao administrador para reativar sua conta.' : 'Seu perfil está aguardando a aprovação do administrador. Esta tela atualiza sozinha.');
      revalidarPerfil(); return;
    }
    if (est.perfil.deve_trocar_senha) { abrirAuth('senhaobrig', 'Digite a senha provisória e escolha uma nova (mínimo de 10 caracteres).'); revalidarPerfil(); return; }
    S.user = est.perfil.nome; S.sigla = est.perfil.sigla; S.syncDono = est.perfil.id;
    sincronizar({ forcar: true, puxar: true });
  }

  return {
    iniciar, notificar, sincronizar, renderMais, pendentes, abrirAuth, puxar /* exposto para o teste do pull paginado */,
    aplicarPull /* exposto para o teste do pull de bens */,
    get ligado() { return est.ligado; }, get logado() { return est.logado; }, get rodando() { return est.rodando; }, get perfil() { return est.perfil; },
    get admin() { return !!(est.perfil && est.perfil.ativo && !est.perfil.deve_trocar_senha && est.perfil.papel === 'admin'); },
    itemOk: (tabela, id) => est.okIds.has(tabela + ':' + id)
  };
})();
