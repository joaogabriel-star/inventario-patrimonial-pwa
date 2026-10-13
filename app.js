'use strict';
/* Inventário Patrimonial (demonstração) — PWA offline-first.
   Tudo é gravado em IndexedDB neste aparelho. Backend remoto: ver remote-adapter.js. */

const VERSION = '0.8.0';
const TIPOS_INICIAIS = ['MONITOR','POLTRONA','MESA','MICROCOMPUTADOR','GAVETEIRO','ARMARIO','NOTEBOOK','CADEIRA','SOFA','EQUIPAMENTO','CAMERA','TELEVISOR','REFRIGERADOR','UMIDIFICADOR','PROJETOR','WORKSTATION','FORNO','TELA DE PROJECAO','AR CONDICIONADO','FILTRO','SERVIDOR','MICRO-ONDAS','MAQUINA','RECEPTOR','CAIXA','CONDICIONADOR','SWITCH','BEBEDOURO','FRAGMENTADORA','SUPORTE','IMPRESSORA','CAFETEIRA','QUADRO','TAPETE'];
const LOCALIDADES_INICIAIS = ['Prédio Central', 'Anexo'];
const FORNECEDORES = ['Órgão A', 'Órgão B'];
const OUTRO = 'Outro';
const IS_IOS = /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

// ---------- utilidades ----------
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const uuid = () => {
  if (crypto.randomUUID) return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 15) | 64; b[8] = (b[8] & 63) | 128;
  const h = [...b].map(x => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
};
const nowISO = () => new Date().toISOString();
const fmtBR = iso => {
  if (!iso) return '';
  const p = Object.fromEntries(new Intl.DateTimeFormat('pt-BR', {
    timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false
  }).formatToParts(new Date(iso)).map(x => [x.type, x.value]));
  return `${p.day}/${p.month}/${p.year} ${p.hour === '24' ? '00' : p.hour}:${p.minute}:${p.second}`;
};
const norm = s => String(s ?? '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
  .replace(/\b(sala|sl)\b\.?/g, ' ').replace(/[^a-z0-9]+/g, ' ').trim().replace(/\s+/g, ' ');
const normSimples = s => String(s ?? '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, ' ').trim();
const limpaEspacos = s => String(s ?? '').trim().replace(/\s+/g, ' ');
function lev(a, b) {
  if (Math.abs(a.length - b.length) > 1) return 2;
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++) for (let j = 1; j <= b.length; j++)
    d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
  return d[a.length][b.length];
}
let toastTimer;
function toast(msg, kind = '', ms = 2500) {
  const t = $('#toast'); t.textContent = msg; t.className = kind; t.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => (t.hidden = true), ms);
}

// ---------- CPF (só aviso; nunca bloqueia) ----------
const cpfDigits = s => String(s ?? '').replace(/\D/g, '');
function cpfValido(d) {
  if (d.length !== 11 || /^(\d)\1{10}$/.test(d)) return false;
  for (let t = 9; t < 11; t++) {
    let s = 0; for (let i = 0; i < t; i++) s += Number(d[i]) * (t + 1 - i);
    if (((s * 10) % 11) % 10 !== Number(d[t])) return false;
  }
  return true;
}
const cpfMask = d => (d.length === 11 ? `***.${d.slice(3, 6)}.${d.slice(6, 9)}-**` : d ? '***' : '');
const cpfFmt = d => (d.length === 11 ? `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d.slice(9)}` : d);
function cpfAviso(d) {
  if (!d) return '';
  if (d.length !== 11) return `⚠ CPF com ${d.length} dígitos (esperado: 11). Pode salvar.`;
  return cpfValido(d) ? '' : '⚠ Dígito verificador do CPF não confere. Pode salvar.';
}

// ---------- janelas (modal) ----------
// opcoes = [{ v, t }]: mostra uma lista de escolha; devolve o valor escolhido ('' se nenhum) ou null se cancelou
function modal({ title, msg = '', big = '', input = false, okLabel = 'OK', cancel = true, value = '', danger = false, opcoes = null }) {
  return new Promise(resolve => {
    const m = $('#modal'), inp = $('#mInput'), sel = $('#mSelect');
    $('#mTitle').textContent = title; $('#mMsg').textContent = msg;
    $('#mBig').hidden = !big; $('#mBig').textContent = big;
    inp.hidden = !input; inp.value = value;
    sel.hidden = !opcoes;
    sel.innerHTML = opcoes ? '<option value="">— escolha —</option>' + opcoes.map(o => `<option value="${esc(o.v)}">${esc(o.t)}</option>`).join('') : '';
    if (opcoes) sel.value = opcoes.some(o => o.v === value) ? value : '';
    $('#mCancel').hidden = !cancel; $('#mOk').textContent = okLabel;
    $('#mOk').className = 'btn ' + (danger ? 'danger' : 'primary');
    m.hidden = false; if (input) setTimeout(() => inp.focus(), 50);
    const end = v => { m.hidden = true; $('#mOk').onclick = $('#mCancel').onclick = null; resolve(v); };
    $('#mOk').onclick = () => end(opcoes ? sel.value : input ? inp.value.trim() : true);
    $('#mCancel').onclick = () => end(input || opcoes ? null : false);
  });
}
const confirmBox = (title, msg, okLabel = 'Confirmar') => modal({ title, msg, okLabel });
async function askText(title, msg, { required = true, value = '', cancel = true } = {}) {
  for (;;) {
    const v = await modal({ title, msg, input: true, value, cancel });
    if (v === null) return null;
    if (v || !required) return v;
  }
}
const siglaSugerida = nome => String(nome).normalize('NFD').replace(/[̀-ͯ]/g, '').split(/\s+/).map(p => p[0]).join('').replace(/[^A-Za-z0-9]/g, '').toUpperCase().slice(0, 4);
async function askSigla(nome, atual = '', cancel = false) {
  for (;;) {
    const v = await modal({ title: 'Sigla do usuário', msg: 'De 2 a 4 letras ou números, diferente da de cada colega (ex.: iniciais). Entra no código provisório SEM-<sigla>-0001.', input: true, value: atual || siglaSugerida(nome), cancel });
    if (v === null) return null;
    const s = v.toUpperCase().replace(/\s+/g, '');
    if (/^[A-Z0-9]{2,4}$/.test(s)) return s;
  }
}

// ---------- tema (auto / claro / escuro) ----------
const temaAtual = () => { try { return localStorage.getItem('tema') || 'auto'; } catch { return 'auto'; } };
function aplicarTema(t, salvar) {
  document.documentElement.dataset.tema = t;
  if (salvar) { try { localStorage.setItem('tema', t); } catch {} }
  const escuro = t === 'dark' || (t === 'auto' && window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches);
  const meta = $('#metaTheme'); if (meta) meta.content = escuro ? '#12263a' : '#1d4f7c';
  $$('#temaBtns button').forEach(b => b.classList.toggle('on', b.dataset.t === t));
}

// ---------- banco local (IndexedDB) ----------
let db;
const STORES = ['coordenacoes', 'salas', 'tipos', 'bens', 'auditoria', 'localidades', 'descricoes', 'outbox', 'indice'];
function openDB() {
  return new Promise((res, rej) => {
    const r = indexedDB.open('patrimonio-v1', 4);
    r.onupgradeneeded = () => {            // só cria o que falta; nunca mexe nos dados existentes
      const d = r.result;
      if (!d.objectStoreNames.contains('meta')) d.createObjectStore('meta', { keyPath: 'k' });
      STORES.forEach(n => { if (!d.objectStoreNames.contains(n)) d.createObjectStore(n, { keyPath: 'id' }); });
    };
    r.onblocked = () => toast('Feche outras abas ou janelas deste app para concluir a atualização.', 'err', 6000);
    r.onsuccess = () => { r.result.onversionchange = () => r.result.close(); res(r.result); };
    r.onerror = () => rej(r.error);
  });
}
const reqP = r => new Promise((res, rej) => { r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
const txDone = t => new Promise((res, rej) => {
  t.oncomplete = () => res();
  t.onabort = () => rej(t.error || new Error('transação abortada'));
  t.onerror = () => rej(t.error);
});
// durability "strict": só conclui depois de gravado de fato no disco (suportado no Chrome/Android)
function T(names, write) {
  const mode = write ? 'readwrite' : 'readonly';
  if (!write) return db.transaction(names, mode);
  try { return db.transaction(names, mode, { durability: 'strict' }); } catch { return db.transaction(names, mode); }
}
const getAll = n => reqP(T([n]).objectStore(n).getAll());
const getOne = (n, id) => reqP(T([n]).objectStore(n).get(id));
async function getMeta(k) { const r = await reqP(T(['meta']).objectStore('meta').get(k)); return r ? r.v : undefined; }
// grava vários itens de uma vez, de forma atômica: [['bens', obj], ['meta', {k, v}], ...]
// opcoes.silencioso: gravações do próprio motor de sincronização não disparam outra sincronização
async function writeMany(entries, { silencioso = false } = {}) {
  const t = T([...new Set(entries.map(e => e[0]))], true);
  entries.forEach(([s, o]) => t.objectStore(s).put(o));
  await txDone(t);
  const dados = entries.filter(e => !['meta', 'outbox', 'indice'].includes(e[0]));
  if (!silencioso && dados.length) Sync.afterWrite(dados);
}
const setMeta = (k, v) => writeMany([['meta', { k, v }]]);
// M-11: toda gravação local feita por uma ação da pessoa passa por aqui. Se o IndexedDB falhar (cota cheia, armazenamento
// corrompido), avisa com uma janela que exige "Entendi" e devolve false: quem chamou NÃO segue adiante como se tivesse salvo.
async function gravarOuAvisar(entries, { oQue = 'O que você acabou de fazer NÃO foi guardado.', ...opcoes } = {}) {
  try { await writeMany(entries, opcoes); return true; }
  catch (e) {
    try { feedback('err'); } catch {}
    await modal({ title: 'NÃO FOI SALVO', msg: 'Falha ao gravar no aparelho: ' + ((e && e.message) || e) + '\n' + oQue + '\nLibere espaço no aparelho e tente de novo. Não siga adiante sem resolver.', okLabel: 'Entendi', cancel: false });
    return false;
  }
}
// rede de segurança: promessa rejeitada que ninguém tratou não pode passar em silêncio
window.addEventListener('unhandledrejection', ev => {
  const m = (ev.reason && ev.reason.message) || String(ev.reason);
  try { toast('Erro inesperado: ' + m + '. Se foi ao salvar, confira se o registro aparece na aba Bens.', 'err', 7000); } catch {}
});

const S = { bens: [], salas: [], coords: [], tipos: [], aud: [], localidades: [], descricoes: [], indice: [], remotos: [], indiceCarregado: false, user: '', sigla: '', salaId: null, device: '', filtroSala: null, filtroCoord: null, torch: null,
  syncDono: null };     // id do usuário a quem este aparelho está vinculado (depois do primeiro login); quem nasce com isso é elegível ao envio
async function reload() {
  [S.bens, S.salas, S.coords, S.tipos, S.aud, S.localidades, S.descricoes] = await Promise.all(['bens', 'salas', 'coordenacoes', 'tipos', 'auditoria', 'localidades', 'descricoes'].map(getAll));
  S.bens.sort((a, b) => (b.criado_em > a.criado_em ? 1 : -1));
  S.aud.sort((a, b) => (b.em > a.em ? 1 : -1));
  if (!S.indiceCarregado) { S.indice = await getAll('indice'); S.indiceCarregado = true; }
  recalcRemotos();
  renderMarcas();
  // sala escolhida que foi MESCLADA em outra (pelo administrador): passa a valer a sala que ficou
  let sm = salaDe(S.salaId);
  for (let i = 0; i < 5 && sm && sm.status === 'mesclada' && sm.mesclada_em_id; i++) { S.salaId = sm.mesclada_em_id; sm = salaDe(S.salaId); }
}
// bens de OUTRAS pessoas (vindos do servidor), para o aviso de duplicidade. Têm o mesmo formato mínimo de um bem local.
function recalcRemotos() {
  const meus = new Set(S.bens.map(b => b.id)), por = new Map();
  for (const e of S.indice) {
    if (meus.has(e.bem_id) || !e.ativo) continue;
    let b = por.get(e.bem_id);
    if (!b) { b = { id: e.bem_id, remoto: true, etiquetas: [], situacao: 'ativo', tipo_bem: e.tipo_bem, sala_id: e.sala_id, sala_nome: e.sala_nome, criado_por: e.sigla, criado_em: e.registrado_em || '' }; por.set(e.bem_id, b); }
    b.etiquetas.push({ numero: e.numero_normalizado || e.numero, serie: e.serie });
  }
  S.remotos = [...por.values()];
}
const audEntry = (acao, detalhe) => ['auditoria', { id: uuid(), em: nowISO(), usuario: S.user, sigla: S.sigla, dispositivo: S.device, acao, detalhe }];

// Migração: só acrescenta/move campos, nada é apagado.
//  v0.1 -> bens: patrimonio_curto/longo viram etiquetas
//  v0.2 -> salas: nivel_org_1/2/3 vão para o campo oculto `legado`
//  localidades: lista criada a partir dos valores iniciais + os já usados nas salas
async function migrar() {
  const ents = [];
  for (const b of S.bens) {
    if (b.etiquetas) continue;
    b.etiquetas = [];
    if (b.patrimonio_curto) b.etiquetas.push({ numero: b.patrimonio_curto, serie: 'curto', origem: b.origem_curto || 'manual' });
    if (b.patrimonio_longo) b.etiquetas.push({ numero: b.patrimonio_longo, serie: 'longo', origem: b.origem_longo || 'manual' });
    ['patrimonio_curto', 'patrimonio_longo', 'origem_curto', 'origem_longo'].forEach(k => delete b[k]);
    b.etiquetado_em_campo = false; ents.push(['bens', b]);
  }
  for (const s of S.salas) {
    if (!('nivel_org_1' in s || 'nivel_org_2' in s || 'nivel_org_3' in s)) continue;
    const lg = { nivel_org_1: s.nivel_org_1 || '', nivel_org_2: s.nivel_org_2 || '', nivel_org_3: s.nivel_org_3 || '' };
    if (Object.values(lg).some(Boolean)) s.legado = { ...(s.legado || {}), ...lg };
    ['nivel_org_1', 'nivel_org_2', 'nivel_org_3'].forEach(k => delete s[k]);
    ents.push(['salas', s]);
  }
  const vistas = new Set(S.localidades.map(l => l.nome_norm));
  const add = nome => {
    const nome1 = limpaEspacos(nome), nn = normSimples(nome1);
    if (!nn || vistas.has(nn)) return;
    vistas.add(nn); ents.push(['localidades', { id: uuid(), nome: nome1, nome_norm: nn, ativo: true }]);
  };
  LOCALIDADES_INICIAIS.forEach(add);
  S.salas.forEach(s => add(s.localidade));
  if (ents.length) { await writeMany(ents); await reload(); }
}

// ---------- regras de patrimônio ----------
const SERIES = ['curto', 'longo', 'outra'];
const cleanCode = raw => String(raw ?? '').trim().replace(/\s+/g, '');
// M-14: MESMA regra do servidor (norm_numero em 001_schema.sql: tira espaços, hífens e pontos e põe em maiúsculas; zeros à
// esquerda ficam). Toda comparação de duplicidade usa isto, dos dois lados, para "A-12" (digitado) = "A12" (servidor).
const normNumero = t => String(t ?? '').replace(/[\s\-.]/g, '').toUpperCase();
function sugereSerie(v) {
  if (/^0\d{4}$/.test(v)) return 'curto';
  if (/^\d{7,8}$/.test(v)) return 'longo';
  return 'outra';
}
// o número é livre; só alerta (nunca bloqueia)
function alertaNumero(v, serie) {
  if (!v) return '';
  if (/^A\d+$/i.test(String(v).replace(/[\s\-.]/g, ''))) return '';      // plaqueta de outro órgão (A00005933): formato conhecido
  if (!/^\d+$/.test(v)) return 'Contém caracteres que não são dígitos.';
  if (serie === 'curto' && !/^0\d{4}$/.test(v)) return 'Série “curto” espera 5 caracteres começando com 0.';
  if (serie === 'longo' && !/^\d{7,8}$/.test(v)) return 'Série “longo” espera 7 ou 8 dígitos.';
  return '';
}
const salaDe = id => S.salas.find(s => s.id === id);
function salaTexto(s) {
  if (!s) return '(sala removida)';
  const c = S.coords.find(c => c.id === s.coordenacao_id);
  return [s.nome, c && c.nome, s.uorg && 'UORG ' + s.uorg, s.andar, s.localidade].filter(Boolean).join(' · ');
}
const etqs = b => b.etiquetas || [];
const bemNum = b => [...etqs(b).map(e => `${e.numero}`), b.codigo_provisorio].filter(Boolean).join('  +  ') || '(sem número)';
const bemNumSerie = b => [...etqs(b).map(e => `${e.numero} (${e.serie})`), b.codigo_provisorio].filter(Boolean).join(' + ');
const tipoTxt = b => (b.tipo_bem === OUTRO ? 'Outro: ' + (b.tipo_bem_outro || '') : b.tipo_bem);
// mesmo número + mesma série em bens diferentes = conflito (forte);
// mesmo número em séries diferentes = aviso leve; várias etiquetas no mesmo bem nunca conflitam
function findDup(numero, serie, exceptId) {
  const forte = [], leve = [], n = normNumero(numero);
  if (!n) return { forte, leve };
  for (const b of [...S.bens, ...S.remotos]) {
    if (b.situacao !== 'ativo' || b.id === exceptId) continue;
    const m = etqs(b).filter(e => normNumero(e.numero) === n);
    if (m.some(e => e.serie === serie)) forte.push(b); else if (m.length) leve.push(b);
  }
  return { forte, leve };
}
function dupIndex(lista = [...S.bens, ...S.remotos]) {
  const forte = new Map(), series = new Map();
  for (const b of lista) if (b.situacao === 'ativo') for (const e of etqs(b)) {
    const n = normNumero(e.numero); if (!n) continue;
    const k = e.serie + '|' + n;
    if (!forte.has(k)) forte.set(k, new Set()); forte.get(k).add(b.id);
    if (!series.has(n)) series.set(n, new Set()); series.get(n).add(e.serie);
  }
  return { forte, series };
}
function dupInfo(b, idx) {
  const f = [], l = [];
  if (b.situacao !== 'ativo') return { f, l };
  for (const e of etqs(b)) {
    const n = normNumero(e.numero); if (!n) continue;
    if (idx.forte.get(e.serie + '|' + n).size > 1) f.push(`${e.numero} (${e.serie})`);
    else if (idx.series.get(n).size > 1) l.push(e.numero);
  }
  return { f, l };
}
function descreveBem(b) {
  const sala = salaDe(b.sala_id) ? salaTexto(salaDe(b.sala_id)) : (b.sala_nome ? 'sala ' + b.sala_nome : '(sala desconhecida)');
  return `${tipoTxt(b)} — ${sala} — ${fmtBR(b.criado_em)} por ${b.criado_por}${b.remoto ? ' (outro aparelho)' : ''}`;
}

// ---------- marcas (evita Dell/DELL/dell) ----------
let marcas = new Map();
function renderMarcas() {
  marcas = new Map();
  for (const b of S.bens.slice().reverse()) {          // mais antigo primeiro: a primeira grafia vence
    const m = limpaEspacos(b.marca), k = normSimples(m);
    if (k && !marcas.has(k)) marcas.set(k, m);
  }
  const dl = $('#dlMarca');
  if (dl) dl.innerHTML = [...marcas.values()].sort((a, b) => a.localeCompare(b, 'pt-BR')).map(v => `<option value="${esc(v)}">`).join('');
}
function marcaCanon(txt) {
  const m = limpaEspacos(txt), k = normSimples(m);
  return (k && marcas.get(k)) || m;
}

// ---------- planilha de patrimônio (lista de CONSULTA, migração 005) ----------
// Números que já constam na planilha de levantamento, com tipo, marca e coordenação. NÃO são bens: não geram duplicidade nem
// vão para a fila de envio. Ao ler/digitar um número que consta, o app preenche o tipo e a marca e avisa.
let planilha = new Map();
async function carregarPlanilha() {
  planilha = new Map(((await getMeta('planilha')) || []).map(p => [normNumero(p.numero), p]));
}
const planilhaDe = v => (v ? planilha.get(normNumero(v)) : undefined);
const textoPlanilha = p => [p.tipo, p.marca, p.coordenacao && 'coordenação ' + p.coordenacao, [p.andar, p.localidade].filter(Boolean).join(', ')].filter(Boolean).join(' · ');
// tipo da planilha -> tipo do app (mesmo nome, sem acento/maiúscula); sem correspondência vira "Outro" com o texto da planilha
function tipoDaPlanilha(sub) {
  const k = normSimples(sub); if (!k) return null;
  const t = S.tipos.find(x => x.ativo && normSimples(x.nome) === k);
  return t ? { tipo: t.nome, outro: '' } : { tipo: OUTRO, outro: limpaEspacos(sub) };
}
// ---------- catálogo legado: plaqueta ANTIGA -> bem do catálogo (migração 010; v0.8.0) ----------
// (No banco o nome histórico do esquema é "siads"; equivale ao catálogo legado.)
// Só os bens do catálogo que têm plaqueta antiga (5 dígitos, com os zeros à esquerda completados na importação) vêm para o celular.
// Ao ler/digitar uma plaqueta que consta, o app preenche tipo (Item), descrição e Item Material e mostra o número do catálogo; a pessoa
// completa o resto (marca, fornecedor) e salva (NÃO salva sozinho). Plaqueta antiga repetida no catálogo ('r') só avisa.
// Plaqueta que começa com "A" (ex.: A00005933) é de outro órgão: identificada, sem alerta de formato e sem consulta ao catálogo.
let catalogo = new Map();
async function carregarCatalogoLegado() {
  catalogo = new Map(((await getMeta('catalogo_legado')) || []).map(x => [normNumero(x.a), x]));
}
const ehPlaquetaOutroOrgao = v => /^A\d+$/.test(normNumero(v));
function catalogoDe(v) {
  const n = normNumero(v); if (!n || ehPlaquetaOutroOrgao(n)) return undefined;
  return catalogo.get(n) || (/^\d{1,4}$/.test(n) ? catalogo.get(n.padStart(5, '0')) : undefined);   // digitado sem os zeros da frente
}
// número do catálogo legado de um bem (pela plaqueta antiga lida); '' se nenhuma etiqueta consta (ou se a plaqueta é repetida no catálogo)
function catalogoDoBem(b) {
  for (const e of etqs(b)) { const s = catalogoDe(e.numero); if (s && !s.r) return s.s; }
  return '';
}
// preenche tipo e marca do rascunho. Só não mexe no que a PESSOA escolheu neste rascunho (tipoManual/marcaManual); o tipo e a
// marca "mantidos" do registro anterior são trocados pelos da planilha, que é o dado deste item.
// Catálogo legado (v0.8.0): o tipo vem do Item do catálogo (vence o da planilha, porque a lista de descrições é por Item) e a descrição e o
// Item Material também; a marca continua vindo da planilha (o catálogo não tem marca).
function aplicarPlanilha(v) {
  const livre = draft.modo === 'sem' || draft.editId;
  const p = livre ? null : planilhaDe(v), s = livre ? null : catalogoDe(v);
  // A digitação passa por números incompletos (4 -> 00004, 43 -> 00043...), que podem constar no catálogo. O que um preenchimento ANTERIOR
  // do catálogo fez e a pessoa não mexeu volta a como estava antes; senão ficaria tipo/descrição de OUTRO bem no rascunho.
  const ant = draft.catalogoAuto; draft.catalogoAuto = null;
  let descMexida = false;
  if (ant) {
    if (draft.descricao === ant.descricao && draft.itemMaterial === ant.itemMaterial) Object.assign(draft, { descricao: ant.antes.descricao, itemMaterial: ant.antes.itemMaterial, descLivre: ant.antes.descLivre });
    else descMexida = true;
    if (!draft.tipoManual && draft.tipo === ant.tipo && draft.tipoOutro === ant.tipoOutro) Object.assign(draft, { tipo: ant.antes.tipo, tipoOutro: ant.antes.tipoOutro });
  }
  const antes = { tipo: draft.tipo, tipoOutro: draft.tipoOutro, descricao: draft.descricao, itemMaterial: draft.itemMaterial, descLivre: draft.descLivre };
  draft.planilha = p || null; draft.catalogo = s && !s.r ? s : null; draft.catalogoRepetido = !!(s && s.r);
  if (p) {
    if (!draft.tipoManual) { const t = tipoDaPlanilha(p.tipo); if (t) { setTipoSemUI(t.tipo); draft.tipoOutro = t.outro; } }
    if (!draft.marcaManual && p.marca) draft.marca = marcaCanon(p.marca);
  }
  if (draft.catalogo && !draft.tipoManual) {
    const t = tipoDaPlanilha(draft.catalogo.i); if (t) { setTipoSemUI(t.tipo); draft.tipoOutro = t.outro; }
    if (!descMexida) {                                                 // descrição que a pessoa digitou/escolheu não é trocada
      const desc = limpaEspacos(draft.catalogo.d);
      draft.descricao = desc; draft.itemMaterial = String(draft.catalogo.m || '');
      draft.descLivre = !S.descricoes.some(d => d.ativo !== false && normSimples(d.texto) === normSimples(desc));
    }
    draft.catalogoAuto = { antes, tipo: draft.tipo, tipoOutro: draft.tipoOutro, descricao: draft.descricao, itemMaterial: draft.itemMaterial };
  }
}
// ---------- unidades e responsáveis (consulta, migração 006): preenchem a CRIAÇÃO de sala ----------
// Vêm do servidor (nunca fazem parte do código). matricula e cpf só chegam preenchidos para o administrador.
let unidades = new Map(), autoSala = {}, siglaPorNome = new Map();
async function carregarUnidades() {
  const lista = (await getMeta('unidades')) || [];
  unidades = new Map(lista.map(u => [normSimples(u.sigla), u]));
  // só entra no mapa quem tem sigla E denominação não vazias depois de normalizadas (chave '' ligaria coordenação em branco a uma unidade)
  siglaPorNome = new Map(lista.map(u => [normSimples(u.denominacao), normSimples(u.sigla)]).filter(([nome, sigla]) => nome && sigla));
}
// Uma coordenação pode vir escrita pela SIGLA (planilha: "JUR") ou pelo NOME COMPLETO (sala: "Consultoria Jurídica"). A tabela de
// unidades liga os dois; esta chave é a mesma para ambos. Sem a unidade, vale só o nome normalizado (como antes).
function chaveCoord(nome) {
  const k = normSimples(nome);
  return siglaPorNome.get(k) || k;
}
// ao digitar a coordenação (sigla) de uma sala NOVA: preenche UORG, responsável e SIORG (e matrícula/CPF para o admin).
// Só preenche campo vazio ou que ainda tem o valor que o próprio app pôs (trocar a coordenação troca o responsável);
// o que a pessoa digitou nunca é apagado.
function preencherPelaUnidade() {
  if (salaEditId) return;
  const u = unidades.get(normSimples($('#sCoord').value)); if (!u) return;
  const pos = (id, v) => { const el = $('#' + id); if (!el.value.trim() || el.value === autoSala[id]) { el.value = v || ''; autoSala[id] = v || ''; } };
  pos('sUorg', u.uorg); pos('rNome', u.responsavel); pos('rSiorg', u.siorg); pos('rUorg', u.uorg); pos('rMat', u.matricula);
  const cpf = cpfDigits(u.cpf).slice(0, 11);                 // unidade sem CPF (ou usuário não admin): limpa o CPF que o app pôs antes
  if (!cpfAtual || cpfAtual === autoSala.cpf) { cpfAtual = cpf; autoSala.cpf = cpf; $('#rCpf').value = cpf.length === 11 ? cpfMask(cpf) : cpf; $('#rCpfAlt').textContent = cpf ? cpfAviso(cpf) : ''; }
}
function refletirPlanilhaNaTela() {          // digitação do número: atualiza só o que a planilha mexe (sem recriar o campo do número)
  $('#inMarca').value = draft.marca; $('#inTipoOutro').value = draft.tipoOutro; renderTipos(); renderDescricao();
}

// ---------- combobox com busca (sem acento nem maiúscula; o teclado só abre ao tocar na busca) ----------
function filtrarItens(itens, q) {
  const k = normSimples(q);
  return k ? itens.filter(i => normSimples(i.label + ' ' + (i.sub || '')).includes(k)) : itens;
}
function makeCombo(root, { getItens, getLabel, onPick, vazio }) {
  const btn = $('.combo-btn', root), pop = $('.combo-pop', root), q = $('.combo-q', root), ul = $('.combo-list', root), val = $('.combo-val', root);
  const api = {
    abrir() { pop.hidden = false; btn.setAttribute('aria-expanded', 'true'); q.value = ''; api.render(); },   // sem focus() de propósito
    fechar() { pop.hidden = true; btn.setAttribute('aria-expanded', 'false'); },
    render() {
      const todos = getItens(), fixos = todos.filter(i => i.destaque);          // opções fixas ficam sempre visíveis
      const achados = filtrarItens(todos.filter(i => !i.destaque), q.value), mostra = [...fixos, ...achados.slice(0, 200)];
      ul.innerHTML = mostra.map(i => `<li role="option" data-v="${esc(i.value)}" class="${i.destaque ? 'destaque' : ''}">${esc(i.label)}${i.sub ? `<small>${esc(i.sub)}</small>` : ''}</li>`).join('') || `<li class="vazio">${esc(vazio || 'Nada encontrado')}</li>`;
      if (!achados.length) ul.insertAdjacentHTML('beforeend', `<li class="vazio">${esc(vazio || 'Nada encontrado')}</li>`);
      if (achados.length > 200) ul.insertAdjacentHTML('beforeend', `<li class="vazio">Mostrando 200 de ${achados.length}. Digite para refinar.</li>`);
    },
    atualizarRotulo() { val.textContent = getLabel(); }
  };
  btn.onclick = () => (pop.hidden ? api.abrir() : api.fechar());
  q.oninput = api.render;
  q.onkeydown = e => {
    if (e.key === 'Enter') { e.preventDefault(); const f = $('li[data-v]:not(.destaque)', ul) || $('li[data-v]', ul); if (f) f.click(); }
    else if (e.key === 'Escape') api.fechar();
  };
  ul.onclick = e => { const li = e.target.closest('li[data-v]'); if (!li) return; api.fechar(); onPick(li.dataset.v); };
  document.addEventListener('click', e => { if (!pop.hidden && !root.contains(e.target)) api.fechar(); });
  return api;
}
let tipoCombo = null, descCombo = null;
const itensTipo = () => [...S.tipos.filter(t => t.ativo).sort((a, b) => a.nome.localeCompare(b.nome, 'pt-BR')).map(t => ({ value: t.nome, label: t.nome })), { value: OUTRO, label: OUTRO + ' (texto livre)' }];
// descrições do tipo escolhido; "Outro" (ou nenhum tipo) mostra todas
function itensDescricao() {
  const t = draft.tipo, todos = !t || t === OUTRO, tn = normSimples(t);
  const lista = S.descricoes.filter(d => d.ativo && (todos || d.tipo_norm === tn)).sort((a, b) => a.texto.localeCompare(b.texto, 'pt-BR'))
    .map(d => ({ value: d.id, label: d.texto, sub: [todos ? d.tipo : '', d.item_material && 'Item Material ' + d.item_material].filter(Boolean).join(' · ') }));
  return [{ value: '__livre__', label: 'Outra descrição (digitar)', destaque: true }, { value: '__nenhuma__', label: '— sem descrição —', destaque: true }, ...lista];
}
function setTipoSemUI(nome) {
  draft.tipo = nome;
  if (draft.descricao && !draft.descLivre && nome !== OUTRO && !S.descricoes.some(d => d.texto === draft.descricao && d.tipo_norm === normSimples(nome))) { draft.descricao = ''; draft.itemMaterial = ''; }
}
function pickTipo(nome) {
  draft.tipoManual = true;                    // a pessoa escolheu: a planilha não troca mais o tipo neste rascunho
  setTipoSemUI(nome);
  syncDraftUI();
}
function pickDescricao(v) {
  if (v === '__livre__') { draft.descLivre = true; draft.descricao = ''; draft.itemMaterial = ''; }
  else if (v === '__nenhuma__') { draft.descLivre = false; draft.descricao = ''; draft.itemMaterial = ''; }
  else {
    const d = S.descricoes.find(x => x.id === v); if (!d) return;
    draft.descLivre = false; draft.descricao = d.texto; draft.itemMaterial = d.item_material || '';
    if (!draft.tipo) { const t = S.tipos.find(x => x.ativo && normSimples(x.nome) === d.tipo_norm); if (t) draft.tipo = t.nome; }
  }
  syncDraftUI();
}
function renderDescricao() {
  if (!tipoCombo || !descCombo) return;
  tipoCombo.atualizarRotulo(); descCombo.atualizarRotulo();
  $('#inDescLivre').hidden = !draft.descLivre;
  if (draft.descLivre) $('#inDescLivre').value = draft.descricao;
  $('#descMat').textContent = draft.itemMaterial ? 'Item Material: ' + draft.itemMaterial : '';
  const n = itensDescricao().length - 2;
  $('#descInfo').textContent = !draft.tipo || draft.tipo === OUTRO ? `${n} descrições (todos os tipos)` : `${n} descrições para ${draft.tipo}`;
}

// ---------- descrições (lista editável; pares Item × Descrição × Item Material do catálogo legado, sem números patrimoniais) ----------
// Importa descricoes.json (no repositório de demonstração, um arquivo pequeno com itens fictícios). Só acrescenta o que falta:
// nunca apaga nem sobrescreve o que foi editado ou desativado no app.
async function importarDescricoes(url = 'descricoes.json', { force = false } = {}) {
  let j;
  try { const r = await fetch(url, { cache: 'no-cache' }); if (!r.ok) return -1; j = await r.json(); } catch { return -1; }
  const marca = String(j.gerado_em || j.versao || '');
  if (!force && marca && (await getMeta('descricoes_importadas')) === marca) return 0;
  const chave = d => `${d.tipo_norm}|${d.texto_norm}|${d.item_material || ''}`;
  const tem = new Set(S.descricoes.map(chave)), ents = [];
  for (const [item, lista] of Object.entries(j.itens || {})) for (const d of lista) {
    const texto = limpaEspacos(d.descricao);
    const nova = { id: uuid(), tipo: limpaEspacos(item), tipo_norm: normSimples(item), texto, texto_norm: normSimples(texto), item_material: String(d.item_material ?? '').trim(), ativo: true, origem: 'siads' };
    if (!texto || !nova.tipo_norm || tem.has(chave(nova))) continue;
    tem.add(chave(nova)); ents.push(['descricoes', nova]);
  }
  const novas = ents.length;
  ents.push(['meta', { k: 'descricoes_importadas', v: marca }]);
  await writeMany(ents); await reload();
  return novas;
}

// ---------- feedback (som, vibração, cor) ----------
let actx;
function unlockAudio() {
  try { actx ||= new (window.AudioContext || window.webkitAudioContext)(); if (actx.state === 'suspended') actx.resume(); } catch {}
}
function beep(freq, ms, delay = 0) {
  if (!actx) return;
  const o = actx.createOscillator(), g = actx.createGain();
  o.frequency.value = freq; o.connect(g); g.connect(actx.destination);
  const t0 = actx.currentTime + delay;
  g.gain.setValueAtTime(0.25, t0); g.gain.exponentialRampToValueAtTime(0.001, t0 + ms / 1000);
  o.start(t0); o.stop(t0 + ms / 1000 + 0.02);
}
const FB_TXT = { ok: '✔ LIDO', dup: '⚠ DUPLICADO', warn: '⚠ ATENÇÃO', err: '✖ ERRO' };
function feedback(kind, flashId = 'flash') {
  const pat = { ok: [60], dup: [80, 60, 80], warn: [80, 60, 80], err: [300] }[kind] || [60];
  try { navigator.vibrate && navigator.vibrate(pat); } catch {}
  if (kind === 'ok') beep(1000, 110);
  else if (kind === 'dup' || kind === 'warn') { beep(520, 140); beep(520, 140, 0.2); }
  else beep(220, 350);
  const f = $('#' + flashId); if (!f) return;
  f.textContent = IS_IOS ? FB_TXT[kind] || '' : '';     // iPhone: sem vibração, então o aviso visual é maior e dura mais
  f.className = 'flash ' + kind; void f.offsetWidth;
  setTimeout(() => { f.className = 'flash'; f.textContent = ''; }, IS_IOS ? 700 : 160);
}

// ---------- leitor de câmera (vídeo contínuo) ----------
const LINEAR = ['code_128', 'code_39', 'code_93', 'ean_13', 'ean_8', 'itf', 'upc_a', 'upc_e', 'codabar', 'qr_code', 'data_matrix'];
async function makeDetector(engine, formats) {
  const Native = window.BarcodeDetector, Wasm = window.BarcodeDetectionAPI && window.BarcodeDetectionAPI.BarcodeDetector;
  const useNative = engine === 'native' ? !!Native : engine === 'wasm' ? false : !!Native;
  const C = useNative ? Native : Wasm;
  if (!C) throw new Error('Nenhum motor de leitura disponível.');
  const supported = await C.getSupportedFormats();
  const f = formats ? formats.filter(x => supported.includes(x)) : supported.filter(x => x !== 'unknown');
  return { det: new C({ formats: f }), name: useNative ? 'nativo do navegador' : 'WASM (ZXing-C++)', formats: f };
}
class Scanner {
  constructor({ video, offEl, torchBtn, torchHint, zoomRow, zoomRange, onResult, formats, dedupMs, getEngine }) {
    Object.assign(this, { video, offEl, torchBtn, torchHint, zoomRow, zoomRange, onResult, formats, dedupMs, getEngine });
    this.running = false; this.stream = null; this.last = { v: '', t: 0 }; this.torchOn = false;
    torchBtn.onclick = () => this.setTorch(!this.torchOn);
    zoomRange.oninput = () => this.track && this.track.applyConstraints({ advanced: [{ zoom: +zoomRange.value }] }).catch(() => {});
  }
  async start() {
    if (this.running) return;
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) throw new Error('Câmera indisponível (é preciso HTTPS).');
    this.stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 } }, audio: false
    });
    this.video.srcObject = this.stream; await this.video.play();
    this.track = this.stream.getVideoTracks()[0];
    const caps = (this.track.getCapabilities && this.track.getCapabilities()) || {};
    S.torch = !!caps.torch; this.torchBtn.hidden = !S.torch; this.torchHint.hidden = S.torch;   // sem suporte declarado: só a dica
    if (caps.zoom) { this.zoomRange.min = caps.zoom.min; this.zoomRange.max = caps.zoom.max; this.zoomRange.step = caps.zoom.step || 0.1; this.zoomRange.value = caps.zoom.min; this.zoomRow.hidden = false; }
    this.engineInfo = await makeDetector(this.getEngine(), this.formats);
    this.running = true; this.offEl.classList.add('hide');
    this.tick();
  }
  async tick() {
    if (!this.running) return;
    try {
      if (this.video.readyState >= 2) {
        const r = await this.engineInfo.det.detect(this.video);
        const now = Date.now();
        for (const c of r) {
          if (this.dedupMs && c.rawValue === this.last.v && now - this.last.t < this.dedupMs) { this.last.t = now; continue; }
          this.last = { v: c.rawValue, t: now };
          this.onResult({ rawValue: c.rawValue, format: c.format, engine: this.engineInfo.name, w: this.video.videoWidth, h: this.video.videoHeight });
        }
      }
    } catch (e) { console.warn('detect', e); }
    if (this.running) this.timer = setTimeout(() => this.tick(), 110);
  }
  async setTorch(on) {
    try {
      await this.track.applyConstraints({ advanced: [{ torch: on }] });
      const st = this.track.getSettings ? this.track.getSettings() : {};
      if (on && 'torch' in st && !st.torch) throw new Error('torch não ligou');   // o navegador aceitou mas não ligou
      this.torchOn = on;
    } catch {
      this.torchOn = false; S.torch = false; this.torchBtn.hidden = true; this.torchHint.hidden = false;
      toast('Este aparelho não liga a lanterna pelo app.', 'err', 3500);
    }
  }
  stop() {
    this.running = false; clearTimeout(this.timer);
    if (this.stream) this.stream.getTracks().forEach(t => t.stop());
    this.stream = null; this.video.srcObject = null; this.torchOn = false;
    this.offEl.classList.remove('hide'); this.torchBtn.hidden = true; this.torchHint.hidden = true; this.zoomRow.hidden = true;
  }
}

// ---------- tela: registrar ----------
// modo: 'normal' (etiqueta lida/digitada) | 'campo' (etiquetado em campo) | 'sem' (código provisório)
let draft;
function newDraft(keepTipo, keepMF) {
  const old = draft;
  return { editId: null, numero: '', serie: 'outra', serieManual: false, origem: '', obs: '', modo: 'normal',
    tipo: keepTipo && old ? old.tipo : '', tipoOutro: keepTipo && old ? old.tipoOutro : '',
    descricao: keepTipo && old ? old.descricao : '', itemMaterial: keepTipo && old ? old.itemMaterial : '', descLivre: keepTipo && old ? old.descLivre : false,
    marca: keepMF && old ? old.marca : '', fornecedor: keepMF && old ? old.fornecedor : '',
    planilha: null, catalogo: null, catalogoRepetido: false, tipoManual: false, marcaManual: false };
}
let scanReg;
function renderSalaBanner() {
  const b = $('#salaBanner'), s = salaDe(S.salaId);
  if (!s) { b.className = 'sala-banner vazia'; b.innerHTML = 'Nenhuma sala escolhida — toque para escolher'; return; }
  const c = S.coords.find(c => c.id === s.coordenacao_id);
  b.className = 'sala-banner';
  b.innerHTML = `Sala: <b>${esc(s.nome)}</b> <small>${esc([c && c.nome, s.uorg && 'UORG ' + s.uorg, s.andar, s.localidade].filter(Boolean).join(' · '))} — toque para trocar</small>`;
}
function renderTipos() {
  const ativos = S.tipos.filter(t => t.ativo).sort((a, b) => a.nome.localeCompare(b.nome));
  const top = ativos.slice().sort((a, b) => (b.usos || 0) - (a.usos || 0)).filter(t => t.usos > 0).slice(0, 8);
  $('#chips').innerHTML = top.map(t => `<button type="button" class="chipbtn ${draft.tipo === t.nome ? 'on' : ''}" data-tipo="${esc(t.nome)}">${esc(t.nome)}</button>`).join('');
  $('#inTipoOutro').hidden = draft.tipo !== OUTRO;
}
let semSeqCache = {};
function syncDraftUI() {
  const sem = draft.modo === 'sem';
  $('#inNumero').value = draft.numero; $('#inNumero').disabled = sem; $('#selSerie').disabled = sem;
  $('#selSerie').value = draft.serie;
  $('#serieHint').textContent = draft.serieManual ? '(escolhida por você)' : '(sugerida pelo número)';
  $('#inObs').value = draft.obs; $('#inTipoOutro').value = draft.tipoOutro;
  $('#inMarca').value = draft.marca; $('#selFornec').value = draft.fornecedor;
  $$('input[name=modo]').forEach(r => (r.checked = r.value === draft.modo));
  $('#obsHint').textContent = sem ? '(obrigatória para bem sem etiqueta)' : '(opcional)';
  $('#codProv').textContent = sem ? `Será gerado: SEM-${S.sigla}-${String(((semSeqCache[S.sigla] || 0)) + 1).padStart(4, '0')}` : '';
  const eb = $('#editBanner');
  if (draft.editId) {
    const b = S.bens.find(x => x.id === draft.editId);
    eb.hidden = false;
    eb.innerHTML = `Adicionando etiqueta ao bem já salvo: <b>${esc(bemNumSerie(b))}</b>. Leia ou digite a outra etiqueta e salve.`;
  } else eb.hidden = true;
  validateFields(); renderTipos(); renderDescricao();
}
function validateFields() {
  const v = draft.numero.trim(), inp = $('#inNumero'), alt = $('#altNumero');
  const fmt = draft.modo === 'sem' ? '' : alertaNumero(v, draft.serie);
  const { forte, leve } = draft.modo === 'sem' ? { forte: [], leve: [] } : findDup(v, draft.serie, draft.editId);
  inp.classList.toggle('has-alert', !!fmt); inp.classList.toggle('has-dup', forte.length > 0);
  let h = '';
  if (fmt) h += `⚠ ${esc(fmt)} Pode salvar, será marcado.<br>`;
  if (forte.length) h += `<span class="dup">⛔ Já registrado nesta série em outro bem: ${esc(descreveBem(forte[0]))}</span><br>`;
  if (leve.length) { const e0 = etqs(leve[0]).find(e => normNumero(e.numero) === normNumero(v)); h += `ℹ O mesmo número existe em outra série (${esc(e0 ? e0.serie : '?')}): ${esc(descreveBem(leve[0]))}<br>`; }
  if (draft.planilha) h += `📋 Consta na planilha: <b>${esc(textoPlanilha(draft.planilha))}</b>. Tipo e marca preenchidos: confira.<br>`;
  if (draft.catalogo) h += `🏷 Consta no catálogo legado: nº <b>${esc(draft.catalogo.s)}</b> — ${esc(draft.catalogo.i)} · ${esc(draft.catalogo.d)}. Tipo, descrição e Item Material preenchidos: complete o que falta (marca, fornecedor) e salve.<br>`;
  if (draft.catalogoRepetido) h += `⚠ Esta plaqueta antiga aparece em MAIS DE UM bem no catálogo legado: o app não preencheu. Preencha à mão.<br>`;
  if (draft.modo !== 'sem' && ehPlaquetaOutroOrgao(v)) h += `🏛 Plaqueta de <b>outro órgão</b>.`;
  alt.className = 'alert' + (forte.length ? ' dup' : ''); alt.innerHTML = h;
}
function setNumero(v, origem, simbologia = '') {
  draft.numero = v; draft.origem = origem; draft.simbologia = simbologia;
  if (!draft.serieManual) draft.serie = sugereSerie(v);
  aplicarPlanilha(v);
}
// v0.7.4 — leitura pela CÂMERA (não vale para a digitação, que passa por números incompletos):
//   * número JÁ LIDO neste levantamento (mesmo número e série em bem ativo): NÃO registra de novo; o rascunho volta como estava e
//     aparece "É outro bem: registrar mesmo assim" (aí segue o caminho normal, com a confirmação "Salvar mesmo assim");
//   * número que CONSTA NA PLANILHA e ainda não foi lido, com a sala escolhida: salva sozinho (localizado) com tipo e marca da
//     planilha e deixa pronto para o próximo, com "Desfazer" (anula, não apaga);
//   * o resto segue como antes (mostra e espera "Salvar").
let autoSalvando = false, salvandoN = 0, repetidoPendente = null, ultimoAuto = null;
// não salva sozinho se a pessoa já começou a preencher ESTE item à mão (tipo/marca escolhidos ou observação digitada): aí segue o
// caminho normal (mostra e espera "Salvar"), para nada do que ela digitou se perder
// v0.8.0: o que consta no catálogo legado NÃO salva sozinho (a pessoa completa marca/fornecedor e salva); o automático fica só para o que
// consta apenas na planilha
const autoSalvavel = (v, origem, leve) => origem === 'camera' && draft.modo === 'normal' && !draft.editId && !!draft.planilha &&
  !draft.catalogo && !draft.catalogoRepetido &&
  !draft.tipoManual && !draft.marcaManual && !draft.obs.trim() &&
  !!tipoDaPlanilha(draft.planilha.tipo) && !leve.length && !alertaNumero(v, draft.serie) && !!S.salaId && !!salaDe(S.salaId);
function applyCode(v, origem, simbologia = '') {
  const antes = { ...draft };                                // só campos simples (draft.planilha é só lido): cópia rasa basta
  if (draft.modo === 'sem') draft.modo = 'normal';
  if (draft.editId) {
    const b = S.bens.find(x => x.id === draft.editId);
    if (etqs(b).some(e => normNumero(e.numero) === normNumero(v))) { feedback('err'); toast(`Este bem já tem a etiqueta ${v}. Leia a outra.`, 'err', 3500); return; }
  }
  setNumero(v, origem, simbologia);
  const { forte, leve } = findDup(v, draft.serie, draft.editId);
  if (origem === 'camera' && forte.length && !draft.editId) {
    const b0 = forte[0], agora = b0.id === lastSaved;          // o mesmo item que acabou de ser salvo, lido de novo
    repetidoPendente = { v, origem, simbologia };
    draft = antes; syncDraftUI();
    feedback(agora ? 'ok' : 'dup');
    $('#scanMsg').innerHTML = agora
      ? `<div class="banner info">✔ <b>${esc(v)}</b> já foi registrado agora há pouco (este mesmo item). Pode seguir para o próximo.${b0.id === ultimoAuto
          ? `<div class="row"><button class="btn small" data-desfazer-auto="${esc(b0.id)}" type="button">↩ Desfazer</button></div>` : ''}</div>`
      : `<div class="banner err">⚠ <b>${esc(v)}</b> JÁ FOI LIDO neste levantamento: ${esc(descreveBem(b0))}. <b>Não foi registrado de novo.</b> Pode seguir para o próximo.
         <div class="row">${S.salaId && salaDe(S.salaId) && b0.sala_id !== S.salaId ? `<button class="btn small ok" data-mover-aqui="${esc(b0.id)}" type="button">Está nesta sala: mover para ${esc(salaDe(S.salaId).nome)}</button>` : ''}<button class="btn small" data-registrar-repetido="1" type="button">É outro bem: registrar mesmo assim</button></div></div>`;
    return;
  }
  repetidoPendente = null;
  syncDraftUI();
  if (autoSalvavel(v, origem, leve)) { salvarBem(true); return; }
  feedback(forte.length ? 'dup' : (leve.length || alertaNumero(v, draft.serie)) ? 'warn' : 'ok');
  $('#scanMsg').innerHTML = `<div class="banner ${forte.length ? 'err' : 'info'}">Lido: <b>${esc(v)}</b> — série ${draft.serie}${forte.length ? ' — JÁ EXISTE em outro bem' : leve.length ? ' — mesmo número em outra série' : ''}${draft.catalogo ? ` — consta no catálogo legado (nº ${esc(draft.catalogo.s)}): complete e salve` : draft.catalogoRepetido ? ' — plaqueta repetida no catálogo legado: preencha à mão' : ''}${draft.planilha ? ' — consta na planilha (tipo e marca preenchidos)' : draft.modo === 'normal' && !draft.editId && planilha.size && !draft.catalogo ? ' — NÃO consta na planilha' : ''}${ehPlaquetaOutroOrgao(v) ? ' — plaqueta de outro órgão' : ''}</div>`;
}
// ignora a leitura enquanto salva (automático ou "Salvar") ou com uma janela aberta (ex.: "Confira o número"): senão a leitura trocaria
// o rascunho por baixo da confirmação, ou salvaria outro item sozinho no meio dela
const onScanRegistrar = r => { if (!autoSalvando && !salvandoN && $('#modal').hidden) applyCode(cleanCode(r.rawValue), 'camera', r.format || ''); };
// "É outro bem: registrar mesmo assim": volta o número para o rascunho; o salvar pede a confirmação de duplicidade
function registrarRepetido() {
  const r = repetidoPendente; if (!r) return;
  repetidoPendente = null; setNumero(r.v, r.origem, r.simbologia); syncDraftUI();
  $('#scanMsg').innerHTML = `<div class="banner err">Número <b>${esc(r.v)}</b> de volta no formulário. Confira o tipo e toque em Salvar: o app vai pedir para confirmar a duplicidade.</div>`;
}
async function desfazerAuto(id) {
  const b = S.bens.find(x => x.id === id);
  if (!b || b.situacao !== 'ativo') { $('#scanMsg').innerHTML = ''; return; }
  const ok = await anularBem(b, 'leitura automática desfeita');
  if (ok) { $('#scanMsg').innerHTML = `<div class="banner info">Desfeito: ${esc(bemNum(b))} anulado (pode ler de novo).</div>`; renderLast(); renderStatus(); }
}

async function proximoSem() {
  const k = 'sem_seq_' + S.sigla;
  const seq = ((await getMeta(k)) || 0) + 1;
  return { seq, k, codigo: `SEM-${S.sigla}-${String(seq).padStart(4, '0')}` };
}
// auto = true: leitura pela câmera de um número que consta na planilha (ver applyCode). Usa SÓ o que a planilha diz (tipo e marca),
// sem descrição/fornecedor/observação "fixados" do item anterior (seriam de outro bem), e não abre a tela de confirmação.
async function salvarBem(auto = false) {
  auto = auto === true;                                   // o clique do botão passa o evento: não é automático
  if (auto) { if (autoSalvando) return; autoSalvando = true; }
  salvandoN++;
  try { await salvarBemAgora(auto); } finally { salvandoN--; if (auto) autoSalvando = false; }
}
async function salvarBemAgora(auto) {
  if (!S.salaId || !salaDe(S.salaId)) { toast('Escolha a sala antes de salvar.', 'err'); feedback('err'); return; }
  const pl = auto ? draft.planilha : null;
  if (auto) { const t = tipoDaPlanilha(pl.tipo); draft.tipo = t.tipo; draft.tipoOutro = t.outro; }
  const num = draft.numero.trim(), obs = auto ? '' : draft.obs.trim(), modo = draft.modo;
  const marca = auto ? (pl.marca ? marcaCanon(pl.marca) : '') : marcaCanon(draft.marca), fornecedor = auto ? '' : draft.fornecedor;   // marca e fornecedor: sempre opcionais
  const descricao = auto ? '' : limpaEspacos(draft.descricao), itemMaterial = descricao ? draft.itemMaterial : '';
  const descOrigem = !descricao ? '' : draft.descLivre ? 'livre' : 'lista';
  const editando = draft.editId ? S.bens.find(b => b.id === draft.editId) : null;
  const falha = m => { toast(m, 'err', 3500); feedback('err'); };
  if (modo === 'sem' && editando) return falha('Para um bem já salvo, adicione uma etiqueta (normal ou etiquetado em campo).');
  if (modo === 'sem' && !obs) return falha('Bem sem etiqueta exige uma observação curta.');
  if (modo !== 'sem' && !num) return falha(modo === 'campo' ? 'Leia ou digite o número da etiqueta nova.' : 'Leia ou digite o número da etiqueta.');
  if (!draft.tipo) return falha('Escolha o tipo do bem.');
  if (draft.tipo === OUTRO && !draft.tipoOutro.trim()) return falha('Descreva o tipo em “Outro”.');

  // tela de confirmação com o número grande
  const { forte, leve } = modo === 'sem' ? { forte: [], leve: [] } : findDup(num, draft.serie, draft.editId);
  const fmt = modo === 'sem' ? '' : alertaNumero(num, draft.serie);
  let msg = `${modo === 'sem' ? 'Sem etiqueta — será gerado um código provisório.' : 'Série: ' + draft.serie}${modo === 'campo' ? ' · etiquetado em campo' : ''}\nTipo: ${draft.tipo === OUTRO ? 'Outro: ' + draft.tipoOutro.trim() : draft.tipo}`;
  if (descricao) msg += `\nDescrição: ${descricao}${itemMaterial ? ' (Item Material ' + itemMaterial + ')' : ''}`;
  if (marca || fornecedor) msg += `\nMarca: ${marca || '—'} · Fornecedor: ${fornecedor || '—'}`;
  msg += `\nSala: ${salaTexto(salaDe(S.salaId))}`;
  if (draft.catalogo) msg += `\nNº do catálogo legado: ${draft.catalogo.s}`;
  if (modo !== 'sem' && ehPlaquetaOutroOrgao(num)) msg += `\nPlaqueta de outro órgão`;
  if (modo === 'sem') msg += `\nObservação: ${obs}`;
  if (fmt) msg += `\n⚠ ${fmt}`;
  if (leve.length) msg += `\nℹ Mesmo número em outra série: ${descreveBem(leve[0])}`;
  if (forte.length) msg += `\n\n⛔ JÁ REGISTRADO nesta série em outro bem:\n${descreveBem(forte[0])}\nOs dois registros serão mantidos e marcados como duplicidade.`;
  if (auto && (forte.length || leve.length)) return;        // segurança: o automático nunca grava duplicidade
  const ok = auto || await modal({ title: editando ? 'Confirmar nova etiqueta' : 'Confira o número', big: modo === 'sem' ? 'SEM ETIQUETA' : num, msg, okLabel: forte.length ? 'Salvar mesmo assim' : 'Confirmar e salvar', danger: forte.length > 0 });
  if (!ok) return;

  const t = nowISO(), tipoRec = S.tipos.find(x => x.nome === draft.tipo);
  const entries = []; let bem;
  const etq = modo === 'sem' ? null : { id: uuid(), numero: num, serie: draft.serie, origem: draft.origem || 'manual', simbologia: draft.origem === 'camera' ? draft.simbologia || '' : '' };
  if (editando) {
    bem = editando; bem.etiquetas = [...etqs(bem), etq];
    if (modo === 'campo') bem.etiquetado_em_campo = true;
    bem.marca = marca; bem.fornecedor = fornecedor;
    bem.descricao = descricao; bem.item_material = itemMaterial; bem.descricao_origem = descOrigem;
    if (!bem.numero_siads && draft.catalogo) bem.numero_siads = draft.catalogo.s;       // numero_siads: nome histórico do esquema (catálogo legado)
    bem.atualizado_em = t; (bem.eventos ||= []).push({ em: t, usuario: S.user, acao: 'etiqueta_adicionada', numero: num });
  } else {
    let codProv = null;
    if (modo === 'sem') { const s = await proximoSem(); codProv = s.codigo; entries.push(['meta', { k: s.k, v: s.seq }]); semSeqCache[S.sigla] = s.seq; }
    bem = {
      id: uuid(), etiquetas: etq ? [etq] : [], codigo_provisorio: codProv, etiquetado_em_campo: modo === 'campo',
      tipo_bem: draft.tipo, tipo_bem_outro: draft.tipo === OUTRO ? draft.tipoOutro.trim() : '',
      marca, fornecedor, descricao, item_material: itemMaterial, descricao_origem: descOrigem,
      sala_id: S.salaId, observacao: obs, situacao: 'ativo', numero_siads: draft.catalogo ? draft.catalogo.s : '',
      criado_por: S.user, sigla: S.sigla, criado_em: t, atualizado_em: t, dispositivo: S.device, eventos: [],
      elegivel_sync: !!S.syncDono          // marca gravada na criação: quem decide o envio não é a hora do relógio
    };
  }
  entries.push(['bens', bem]);
  if (tipoRec && !editando) entries.push(['tipos', { ...tipoRec, usos: (tipoRec.usos || 0) + 1 }]);
  entries.push(audEntry(editando ? 'bem_etiqueta_adicionada' : 'bem_criado', { bem: bem.id, numero: num || null, serie: etq && etq.serie, codigo_provisorio: bem.codigo_provisorio, campo: modo === 'campo' }));
  try { await writeMany(entries); }
  catch (e) { feedback('err'); await modal({ title: 'NÃO FOI SALVO', msg: 'Falha ao gravar no aparelho: ' + (e && e.message) + '\nNão siga adiante sem resolver. Anote o número e tente de novo.', cancel: false }); return; }
  await reload(); // só depois da gravação confirmada: bip e confirmação
  feedback('ok'); lastSaved = bem.id;
  draft = newDraft($('#chkFixar').checked, $('#chkFixarMF').checked); $('#scanMsg').innerHTML = '';
  syncDraftUI(); renderLast(); renderStatus();
  ultimoAuto = auto ? bem.id : null;
  if (auto) {
    $('#scanMsg').innerHTML = `<div class="banner info">✔ <b>LOCALIZADO e salvo:</b> <b>${esc(num)}</b> — ${esc(tipoTxt(bem))}${bem.marca ? ' · ' + esc(bem.marca) : ''} (planilha${pl.coordenacao ? ' ' + esc(pl.coordenacao) : ''}). Pode ler o próximo.
      <div class="row"><button class="btn small" data-desfazer-auto="${esc(bem.id)}" type="button">↩ Desfazer</button></div></div>`;
    return;
  }
  toast('✔ Salvo no aparelho', 'ok', 1200);
}
let lastSaved = null;
function iniciarOutraEtiqueta(b) {
  draft = newDraft(false, false); draft.editId = b.id; draft.tipo = b.tipo_bem; draft.tipoOutro = b.tipo_bem_outro;
  draft.marca = b.marca || ''; draft.fornecedor = b.fornecedor || '';
  draft.descricao = b.descricao || ''; draft.itemMaterial = b.item_material || ''; draft.descLivre = b.descricao_origem === 'livre';
  syncDraftUI(); window.scrollTo({ top: 0, behavior: 'smooth' });
}
function renderLast() {
  const box = $('#lastBox'), b = S.bens.find(x => x.id === lastSaved);
  if (!b) { box.hidden = true; return; }
  box.hidden = false;
  box.innerHTML = `Último salvo: <b>${esc(bemNumSerie(b))}</b> — ${esc(tipoTxt(b))}${b.etiquetado_em_campo ? ' · etiquetado em campo' : ''}${b.situacao === 'anulado' ? ' (anulado)' : ''}` +
    (b.situacao === 'ativo' ? `<div class="row"><button class="btn small" id="btnOutraEtq" type="button">＋ Adicionar outra etiqueta a este bem</button></div>` : '');
  const bt = $('#btnOutraEtq'); if (bt) bt.onclick = () => iniciarOutraEtiqueta(b);
}
async function anularBem(b, motivo) {
  b.situacao = 'anulado'; b.anulado_por = S.user; b.anulado_em = nowISO(); b.motivo_anulacao = motivo; b.atualizado_em = b.anulado_em;
  (b.eventos ||= []).push({ em: b.anulado_em, usuario: S.user, acao: 'anulado', motivo });
  const ok = await gravarOuAvisar([['bens', b], audEntry('bem_anulado', { bem: b.id, motivo })]);
  await reload();          // se falhou, recarrega do banco: descarta a alteração só em memória
  return ok;
}
async function desfazerUltimo() {
  const b = S.bens.find(x => x.criado_por === S.user && x.situacao === 'ativo');
  if (!b) { toast('Nenhum registro seu para desfazer.', 'err'); return; }
  if (!(await confirmBox('Desfazer último registro', `Anular ${bemNum(b)} (${tipoTxt(b)})?\nO registro não é apagado: fica marcado como anulado.`, 'Anular'))) return;
  const ok = await anularBem(b, 'desfeito pelo próprio usuário'); renderLast(); renderStatus();
  if (ok) toast('Registro anulado.');
}

// ---------- tela: bens ----------
function renderFiltroBar() {
  const bar = $('#filtroBar'), s = salaDe(S.filtroSala), cp = S.filtroCoord ? coordenacoesPlanilha().find(c => c.chave === S.filtroCoord) : null;
  bar.hidden = !s && !cp;
  bar.innerHTML = cp ? `<span class="chipbtn on">Planilha: ${esc(cp.nome)} <a href="#" id="limparFiltro" aria-label="Limpar filtro">✕</a></span>`
    : s ? `<span class="chipbtn on">Sala ${esc(s.nome)} <a href="#" id="limparFiltro" aria-label="Limpar filtro">✕</a></span> <button class="btn small ok" id="btnUsarFiltro" type="button">Usar esta sala para registrar</button>` : '';
}
// ---- coordenações da planilha de patrimônio: aparecem na aba Salas e abrem a lista dos itens (sem criar bem nem tela nova) ----
// número já lido = existe um bem ATIVO (deste ou de outro aparelho) com essa etiqueta
function numerosLidos() {
  const m = new Map();
  for (const b of S.bens) if (b.situacao === 'ativo') for (const e of etqs(b)) { const k = normNumero(e.numero); if (k && !m.has(k)) m.set(k, b); }
  return m;
}
function coordenacoesPlanilha() {
  const por = new Map();
  for (const p of planilha.values()) {
    const chave = chaveCoord(p.coordenacao); if (!chave) continue;
    if (!por.has(chave)) por.set(chave, { chave, nome: limpaEspacos(p.coordenacao), itens: [] });
    por.get(chave).itens.push(p);
  }
  return [...por.values()].sort((a, b) => a.nome.localeCompare(b.nome, 'pt-BR'));
}
function abrirItensDaPlanilha(chave) { S.filtroSala = null; S.filtroCoord = chave; $('#qBens').value = ''; showTab('bens'); }
// itens da planilha de uma coordenação, com o bem que já os leu (se houver); os que faltam ler vêm primeiro
function itensPlanilhaDe(cp, q) {
  const lidos = numerosLidos();
  const tudo = cp.itens.map(p => ({ p, bem: lidos.get(normNumero(p.numero)) }));
  const lista = tudo.filter(x => !q || normSimples([x.p.numero, x.p.tipo, x.p.marca].join(' ')).includes(q))
    .sort((a, b) => (!!a.bem - !!b.bem) || a.p.numero.localeCompare(b.p.numero));
  return { tudo, lista, nLidos: tudo.filter(x => x.bem).length };
}
const cartaoPlanilha = ({ p, bem }) => `<div class="card">
      <div class="num">${esc(p.numero)}</div>
      <div>${esc(p.tipo)}${p.marca ? ' — ' + esc(p.marca) : ''}</div>
      <div class="small">${esc([p.coordenacao && 'coordenação ' + p.coordenacao, p.andar, p.localidade].filter(Boolean).join(' · '))}</div>
      <div class="small">${bem ? `✔ já lido: ${esc(salaTexto(salaDe(bem.sala_id)))} · ${esc(bem.criado_por || '')}` : 'ainda não lido: leia a etiqueta na aba Registrar'}</div></div>`;
// coordenação da planilha a que uma sala pertence (pelo nome da coordenação da sala), ou undefined
const planilhaDaSala = s => (s ? coordenacoesPlanilha().find(c => c.chave === chaveCoord(((S.coords.find(x => x.id === s.coordenacao_id)) || {}).nome)) : undefined);
function renderItensPlanilha() {
  const cp = coordenacoesPlanilha().find(c => c.chave === S.filtroCoord);
  if (!cp) { S.filtroCoord = null; return renderBens(); }
  const r = itensPlanilhaDe(cp, normSimples($('#qBens').value));
  $('#countBens').textContent = `${r.tudo.length} itens da planilha · ${r.nLidos} já lidos · faltam ${r.tudo.length - r.nLidos} · mostrando ${Math.min(r.lista.length, 100)} de ${r.lista.length}`;
  $('#listBens').innerHTML = r.lista.slice(0, 100).map(cartaoPlanilha).join('') || '<p class="small">Nenhum item.</p>';
}
function renderBens() {
  if (S.filtroSala && !salaDe(S.filtroSala)) S.filtroSala = null;
  renderFiltroBar();
  if (S.filtroCoord) { renderItensPlanilha(); return; }
  const q = normSimples($('#qBens').value), idx = dupIndex();
  const list = S.bens.filter(b => (!S.filtroSala || b.sala_id === S.filtroSala) && (!q || normSimples([bemNum(b), b.codigo_provisorio, tipoTxt(b), b.descricao, b.item_material, b.marca, b.fornecedor, b.observacao, salaTexto(salaDe(b.sala_id)), b.criado_por].join(' ')).includes(q)));
  const ativos = list.filter(b => b.situacao === 'ativo').length;
  $('#countBens').textContent = `${ativos} ativos · ${list.length - ativos} anulados · mostrando ${Math.min(list.length, 100)} de ${list.length}`;
  const bensHtml = list.slice(0, 100).map(b => {
    const tags = [], di = dupInfo(b, idx);
    if (di.f.length) tags.push(`<span class="dup">DUPLICIDADE: ${esc(di.f.join(', '))}</span>`);
    if (di.l.length) tags.push(`<span>mesmo número em outra série: ${esc(di.l.join(', '))}</span>`);
    if (b.etiquetado_em_campo) tags.push('<span>etiquetado em campo</span>');
    { const ns = b.numero_siads || catalogoDoBem(b); if (ns) tags.push(`<span>Catálogo legado ${esc(ns)}</span>`); }
    if (etqs(b).some(e => ehPlaquetaOutroOrgao(e.numero))) tags.push('<span>outro órgão</span>');
    for (const e of etqs(b)) { const a = alertaNumero(e.numero, e.serie); if (a) tags.push(`<span>${esc(e.numero)}: ${esc(a)}</span>`); }
    const mf = [b.marca, b.fornecedor].filter(Boolean).join(' · ');
    return `<div class="card ${b.situacao === 'anulado' ? 'anulado' : ''}">
      <div class="num">${esc(bemNum(b))}</div>
      <div class="small">${esc(etqs(b).map(e => e.serie).join(' + '))}</div>
      <div>${esc(tipoTxt(b))}${mf ? ' — ' + esc(mf) : ''}</div>
      ${b.descricao ? `<div class="small">${esc(b.descricao)}${b.item_material ? ' · Item Material ' + esc(b.item_material) : ''}</div>` : ''}
      <div>${esc(salaTexto(salaDe(b.sala_id)))}</div>
      <div class="small">${esc(fmtBR(b.criado_em))} · ${esc(b.criado_por)}${b.observacao ? ' · ' + esc(b.observacao) : ''}</div>
      <div class="tags">${tags.join('')}</div>
      <div class="acts">${b.situacao === 'ativo'
        ? `<button class="btn small" data-mover="${b.id}" type="button">Mover</button><button class="btn small" data-anular="${b.id}" type="button">Anular</button><button class="btn small" data-outra="${b.id}" type="button">＋ outra etiqueta</button>`
        : (Engine.ligado ? '<span class="small">Restaurar: só o administrador</span>' : `<button class="btn small" data-restaurar="${b.id}" type="button">Restaurar</button>`)}</div></div>`;
  }).join('');
  // sala de uma coordenação da planilha: depois dos bens da sala, a lista dos itens da planilha dessa coordenação (os que faltam ler primeiro)
  let extra = '';
  const cpSala = S.filtroSala ? planilhaDaSala(salaDe(S.filtroSala)) : undefined;
  if (cpSala) {
    const r = itensPlanilhaDe(cpSala, q);
    extra = `<h3>Planilha · ${esc(cpSala.nome)}</h3><p class="small">${r.tudo.length} itens da planilha · ${r.nLidos} já lidos · faltam ${r.tudo.length - r.nLidos}${r.lista.length > 100 ? ' · mostrando 100' : ''}</p>` +
      (r.lista.slice(0, 100).map(cartaoPlanilha).join('') || '<p class="small">Nenhum item.</p>');
  }
  $('#listBens').innerHTML = (bensHtml || `<p class="small">${extra ? 'Nenhum bem registrado nesta sala ainda.' : 'Nenhum bem.'}</p>`) + extra;
}
async function onBensClick(e) {
  const a = e.target.closest('button'); if (!a) return;
  if (a.dataset.mover) { const bm = S.bens.find(x => x.id === a.dataset.mover); if (bm) await moverBemEscolhendo(bm); return; }
  const id = a.dataset.anular || a.dataset.restaurar || a.dataset.outra; const b = S.bens.find(x => x.id === id); if (!b) return;
  // bem que veio do servidor (registrado em outro aparelho): alterá-lo aqui não chegaria ao servidor e geraria divergência
  if ((a.dataset.anular || a.dataset.outra) && b.servidor) { toast('Este bem foi registrado em outro aparelho' + (b.criado_por ? ' (por ' + b.criado_por + ')' : '') + '. Anular ou acrescentar etiqueta só no aparelho que o registrou, ou pela administração.', 'err', 5000); return; }
  if (a.dataset.anular) {
    const m = await askText('Anular bem', 'Motivo (o registro não é apagado):'); if (m === null) return;
    await anularBem(b, m); renderBens(); renderStatus(); renderLast();
  } else if (a.dataset.restaurar) {
    b.situacao = 'ativo'; b.atualizado_em = nowISO(); (b.eventos ||= []).push({ em: b.atualizado_em, usuario: S.user, acao: 'restaurado' });
    await gravarOuAvisar([['bens', b], audEntry('bem_restaurado', { bem: b.id })]); await reload(); renderBens(); renderStatus();
  } else if (a.dataset.outra) {
    lastSaved = b.id; renderLast(); showTab('registrar'); iniciarOutraEtiqueta(b);
  }
}
// ---------- mover UM bem de sala (v0.8.0; coletor e administrador) ----------
// Bem que ainda não foi enviado (só existe neste aparelho): muda aqui mesmo e vai ao servidor já na sala nova.
// Bem que já está no servidor (meu ou de outro aparelho): vai ao servidor (mover_bem, migração 010; precisa de internet), que
// registra quem moveu e permite ao administrador desfazer em "Movimentos recentes". Depois o pull traz a sala nova.
async function moverBem(b, destino) {
  const sd = salaDe(destino);
  if (!b || !sd || sd.status === 'mesclada') { toast('Escolha uma sala válida.', 'err'); return false; }
  if (b.sala_id === destino) { toast('O bem já está nessa sala.', 'err'); return false; }
  const noServidor = !!(b.servidor || b.remoto || (Engine.ligado && Engine.itemOk('bens', b.id)));
  // bem deste aparelho sendo enviado AGORA: o envio em andamento leva a sala antiga e, confirmado, a mudança local não iria mais
  // ao servidor (o bem só é enviado uma vez). Espera o envio terminar.
  if (!noServidor && Engine.ligado && b.elegivel_sync && Engine.rodando) { toast('Sincronizando agora: tente mover de novo em alguns segundos.', 'err', 4000); return false; }
  if (!noServidor) {
    const de = b.sala_id, t = nowISO();
    b.sala_id = destino; b.atualizado_em = t; (b.eventos ||= []).push({ em: t, usuario: S.user, acao: 'movido', de, para: destino });
    const ok = await gravarOuAvisar([['bens', b], audEntry('bem_movido', { bem: b.id, de, para: destino })]);
    await reload(); refreshUI();
    if (ok) toast(`Movido para ${sd.nome}.`, 'ok', 2500);
    return ok;
  }
  if (!Engine.ligado || !Engine.logado) { toast('Entre na conta: este bem já está no servidor.', 'err', 4000); return false; }
  try {
    const r = await Remote.moverBem(b.id, destino);
    if (!r || !r.ok) {
      const m = { sala_mesclada: 'essa sala foi mesclada', sala_inexistente: 'a sala ainda não chegou ao servidor (sincronize)', bem_inexistente: 'o bem ainda não chegou ao servidor (sincronize)' }[r && r.erro];
      toast('O servidor não aceitou' + (m ? ': ' + m : ' (' + ((r && r.erro) || 'erro') + ')') + '.', 'err', 5000); return false;
    }
    toast(`Movido para ${sd.nome}.`, 'ok', 2500);
    await depoisDeAdmin();
    return true;
  } catch (e) {
    toast(e && e.http === 404 ? 'O servidor ainda não tem a migração 010 (mover bem). Avise quem cuida do Supabase.'
      : e && e.permissao ? 'Sem permissão: sua conta precisa estar ativa (aprovada pelo administrador).' : msgErroAdmin(e), 'err', 5000);
    return false;
  }
}
async function moverBemEscolhendo(b) {
  const opcoes = salasVisiveis().filter(s => s.id !== b.sala_id).map(s => ({ v: s.id, t: salaTexto(s) }));
  if (!opcoes.length) { toast('Não há outra sala cadastrada.', 'err'); return; }
  const dest = await modal({ title: 'Mover bem', msg: `${bemNum(b)} — ${tipoTxt(b)}\nEstá em: ${salaTexto(salaDe(b.sala_id))}\nPara qual sala?`, opcoes, value: S.salaId !== b.sala_id ? S.salaId : '', okLabel: 'Mover' });
  if (dest) await moverBem(b, dest);
}
// ---------- administração (só admin; vai direto ao servidor e precisa de internet): mover bens, mesclar salas, desfazer ----------
// A conferência de permissão é do SERVIDOR (funções eh_admin); esconder a seção aqui é só para não confundir quem não é admin.
const admMarcados = new Set();
let admMovs = [];
const salasVisiveis = () => S.salas.filter(s => s.status !== 'mesclada').sort((a, b) => salaTexto(a).localeCompare(salaTexto(b), 'pt-BR', { numeric: true }));
const admOpcoes = (vazio, sel) => `<option value="">${esc(vazio)}</option>` + salasVisiveis().map(s => `<option value="${esc(s.id)}" ${s.id === sel ? 'selected' : ''}>${esc(salaTexto(s))}</option>`).join('');
function msgErroAdmin(e) {
  if (e && e.rede) return 'Sem conexão: esta operação só funciona com internet.';
  if (e && e.http === 404) return 'O servidor ainda não tem a migração 007 (administração). Avise quem cuida do Supabase.';
  if (e && e.permissao) return 'Sem permissão: só o administrador pode fazer isso.';
  return 'Erro: ' + ((e && e.message) || e);
}
function admBensFiltrados() {
  const origem = $('#admOrigem').value, q = normSimples($('#admBusca').value);
  return S.bens.filter(b => (!origem || b.sala_id === origem) && (!q || normSimples([bemNum(b), tipoTxt(b), b.marca, b.descricao].join(' ')).includes(q)));
}
function renderAdmLista() {
  const lista = admBensFiltrados(), mostra = lista.slice(0, 200);
  $('#admListaBens').innerHTML = (mostra.map(b => `<label class="check"><input type="checkbox" data-adm-bem="${esc(b.id)}" ${admMarcados.has(b.id) ? 'checked' : ''}> <b>${esc(bemNum(b))}</b> — ${esc(tipoTxt(b))}${b.marca ? ' · ' + esc(b.marca) : ''}${b.situacao === 'anulado' ? ' (anulado)' : ''} <small>· ${esc(salaTexto(salaDe(b.sala_id)))}</small></label>`).join('') || 'Nenhum bem.')
    + (lista.length > 200 ? `<p>Mostrando 200 de ${lista.length}. Use a busca para refinar.</p>` : '');
  $('#admMover').textContent = `Mover marcados (${admMarcados.size})`;
}
function renderMovimentos() {
  $('#admMovimentos').innerHTML = admMovs.map(m => `<div class="card"><div class="small">${esc(fmtBR(m.feito_em))} · ${esc(m.feito_por)}</div>
    <div>${m.tipo === 'mesclar_salas' ? `Mesclou ${esc(m.origem || '?')} em ${esc(m.destino || '?')}` : `Moveu para ${esc(m.destino || '?')}`} · ${m.quantidade} bem(ns)</div>
    ${m.desfeito_em ? `<div class="small">↩ desfeito em ${esc(fmtBR(m.desfeito_em))}</div>` : `<button class="btn small" data-adm-desfazer="${esc(m.id)}" type="button">↩ Desfazer</button>`}</div>`).join('') || 'Nenhum movimento ainda.';
}
async function carregarMovimentos() {
  try { admMovs = (await Remote.listarMovimentos()) || []; renderMovimentos(); }
  catch (e) { $('#admMovimentos').textContent = msgErroAdmin(e); }
}
function renderAdmin() {
  const box = $('#adminBox'); if (!box) return;
  const ver = Engine.ligado && Engine.logado && Engine.admin;
  box.hidden = !ver; if (!ver) return;
  const o = $('#admOrigem').value, d = $('#admDestino').value, mo = $('#admMescOrigem').value, md = $('#admMescDestino').value;
  $('#admOrigem').innerHTML = admOpcoes('Todas as salas', o); $('#admDestino').innerHTML = admOpcoes('— escolha a sala de destino —', d);
  $('#admMescOrigem').innerHTML = admOpcoes('— escolha —', mo); $('#admMescDestino').innerHTML = admOpcoes('— escolha —', md);
  renderAdmLista(); carregarMovimentos(); carregarUsuarios();
}
async function depoisDeAdmin() {                 // traz do servidor o que mudou (os bens já movidos) e redesenha
  try { await Engine.sincronizar({ forcar: true, puxar: true }); } catch { /* o servidor já fez a operação; o próximo ciclo sincroniza */ }
  await reload(); refreshUI(); renderAdmin();
}
async function admMover() {
  const ids = [...admMarcados], dest = $('#admDestino').value, sd = salaDe(dest);
  if (!ids.length) { toast('Marque pelo menos um bem.', 'err'); return; }
  if (!sd) { toast('Escolha a sala de destino.', 'err'); return; }
  const fora = ids.filter(id => (S.bens.find(b => b.id === id) || {}).sala_id !== dest).length;
  if (!fora) { toast('Os bens marcados já estão nessa sala.', 'err'); return; }
  if (!(await confirmBox('Mover bens', `Mover ${fora} bem(ns) para a sala ${sd.nome}?\nDepois você pode desfazer em “Movimentos recentes”.`, 'Mover'))) return;
  const btn = $('#admMover'); btn.disabled = true;
  try {
    const r = await Remote.moverBens(ids, dest);
    if (!r || !r.ok) { toast('O servidor não aceitou (' + ((r && r.erro) || 'erro') + ').', 'err', 4500); return; }
    admMarcados.clear(); toast(`${r.movidos} bem(ns) movido(s).`, 'ok', 3000);
    await depoisDeAdmin();
  } catch (e) { toast(msgErroAdmin(e), 'err', 5000); } finally { btn.disabled = false; }
}
async function admMesclar() {
  const o = $('#admMescOrigem').value, d = $('#admMescDestino').value, so = salaDe(o), sd = salaDe(d);
  if (!so || !sd) { toast('Escolha as duas salas.', 'err'); return; }
  if (o === d) { toast('Escolha salas diferentes.', 'err'); return; }
  const n = S.bens.filter(b => b.sala_id === o).length;
  if (!(await confirmBox('Mesclar salas', `A sala ${so.nome} vai deixar de aparecer e seus ${n} bem(ns) vão para a sala ${sd.nome}. Nada é apagado.\nDepois você pode desfazer em “Movimentos recentes”.`, 'Mesclar'))) return;
  const btn = $('#admMesclar'); btn.disabled = true;
  try {
    const r = await Remote.mesclarSalas(o, d);
    if (!r || !r.ok) { toast('O servidor não aceitou (' + ((r && r.erro) || 'erro') + ').', 'err', 4500); return; }
    toast(`Salas mescladas: ${r.movidos} bem(ns) movido(s).`, 'ok', 3000);
    await depoisDeAdmin();
  } catch (e) { toast(msgErroAdmin(e), 'err', 5000); } finally { btn.disabled = false; }
}
async function admDesfazer(id) {
  const m = admMovs.find(x => x.id === id); if (!m) return;
  if (!(await confirmBox('Desfazer', `Desfazer: ${m.tipo === 'mesclar_salas' ? 'mesclagem de ' + (m.origem || '?') + ' em ' + (m.destino || '?') : 'bens movidos para ' + (m.destino || '?')} (${m.quantidade} bem(ns))?\nSó voltam os bens que ainda estão onde o movimento os deixou.`, 'Desfazer'))) return;
  try {
    const r = await Remote.desfazerMovimento(id);
    if (!r || !r.ok) { toast(r && r.erro === 'estado_mudou' ? 'Não dá para desfazer: a sala foi alterada depois da mesclagem.' : 'O servidor não aceitou (' + ((r && r.erro) || 'erro') + ').', 'err', 5000); return; }
    toast(`Desfeito: ${r.restaurados} bem(ns) voltaram${r.pulados ? ` (${r.pulados} já tinham sido movidos de novo)` : ''}.`, 'ok', 4000);
    await depoisDeAdmin();
  } catch (e) { toast(msgErroAdmin(e), 'err', 5000); }
}
// ---------- usuários (só admin): aprovar, ativar/desativar, coletor ↔ administrador, exigir troca de senha ----------
// As regras (não se desativar/rebaixar, sempre sobrar um admin) são do SERVIDOR (alterar_usuario); a tela só esconde o que não faz sentido.
let admUsers = [];
const textoUsuario = u => !u.ativo ? (u.aprovado_em ? 'Desativado' : 'Aguardando aprovação') : (u.deve_trocar_senha ? 'Ativo (ainda vai trocar a senha)' : 'Ativo');
function msgErroUsuarios(e) {
  return e && e.http === 404 ? 'O servidor ainda não tem a migração 009 (usuários). Avise quem cuida do Supabase.' : msgErroAdmin(e);
}
function renderUsuarios(eu = Engine.perfil && Engine.perfil.id) {
  $('#admUsuarios').innerHTML = admUsers.map(u => {
    const sou = u.id === eu, pend = !u.ativo && !u.aprovado_em;
    const bt = (acao, txt, cls) => `<button class="btn small ${cls || ''}" data-adm-user="${esc(u.id)}" data-adm-acao="${acao}" type="button">${txt}</button>`;
    const bts = [];
    if (!u.ativo) bts.push(bt('ativar', pend ? 'Aprovar' : 'Reativar', 'primary'));
    else {
      if (u.papel === 'coletor') bts.push(bt('tornar_admin', 'Tornar administrador'));
      else if (!sou) bts.push(bt('tornar_coletor', 'Tornar coletor'));
      if (!sou) bts.push(bt('desativar', 'Desativar', 'danger'));
    }
    if (!sou && !u.deve_trocar_senha) bts.push(bt('exigir_troca_senha', 'Exigir troca de senha'));
    return `<div class="card"><div><b>${esc(u.nome)}</b> (${esc(u.sigla)})${sou ? ' · você' : ''} · ${u.papel === 'admin' ? 'administrador' : 'coletor'}</div>
      <div class="small">${esc(u.email || 'sem e-mail')} · ${esc(textoUsuario(u))}</div><div class="row wrap">${bts.join('')}</div></div>`;
  }).join('') || 'Nenhum usuário.';
}
async function carregarUsuarios() {
  try { admUsers = (await Remote.listarUsuarios()) || []; renderUsuarios(); }
  catch (e) { $('#admUsuarios').textContent = msgErroUsuarios(e); }
}
const MSG_ACAO_USUARIO = {
  ativar: u => (u.aprovado_em ? 'Reativar ' : 'Aprovar ') + u.nome + ` (${u.sigla})? A pessoa passa a acessar o inventário${u.aprovado_em ? '.' : ' e precisa trocar a senha provisória no primeiro acesso.'}`,
  desativar: u => `Desativar ${u.nome} (${u.sigla})? Ela perde o acesso na hora. Os registros dela ficam e você pode reativar depois.`,
  tornar_admin: u => `Tornar ${u.nome} (${u.sigla}) ADMINISTRADOR? Ela poderá mover bens, mesclar salas, ver CPF e matrícula, exportar pelo servidor e gerenciar usuários.`,
  tornar_coletor: u => `Tornar ${u.nome} (${u.sigla}) apenas coletor? Ela perde as funções de administração.`,
  exigir_troca_senha: u => `Exigir que ${u.nome} (${u.sigla}) troque a senha no próximo login?\nFaça isso depois de redefinir a senha no painel do Supabase.`
};
const ERRO_ACAO_USUARIO = {
  nao_em_si_mesmo: 'Você não pode fazer isso com a sua própria conta.',
  ultimo_admin: 'Precisa sobrar pelo menos um administrador ativo.',
  usuario_inativo: 'Ative o usuário antes de torná-lo administrador.',
  usuario_inexistente: 'Esse usuário não existe mais. Atualize a lista.'
};
async function admUsuario(id, acao) {
  const u = admUsers.find(x => x.id === id), msg = MSG_ACAO_USUARIO[acao]; if (!u || !msg) return;
  if (!(await confirmBox('Usuários', msg(u), 'Confirmar'))) return;
  try {
    const r = await Remote.alterarUsuario(id, acao);
    if (!r || !r.ok) { toast(ERRO_ACAO_USUARIO[r && r.erro] || 'O servidor não aceitou (' + ((r && r.erro) || 'erro') + ').', 'err', 5000); await carregarUsuarios(); return; }
    toast('Usuário atualizado.', 'ok', 3000);
    await carregarUsuarios();
  } catch (e) { toast(msgErroUsuarios(e), 'err', 5000); }
}
// exportar CSV direto do SERVIDOR (só admin): baixa os bens em páginas e gera o CSV com as mesmas colunas do CSV normal
async function exportarServidor(modo) {
  const pess = $('#admChkPessoais').checked, info = $('#admExportInfo');
  if (pess && !(await confirmBox('Incluir dados pessoais?', 'O arquivo vai conter nome, matrícula e CPF completo dos responsáveis pelas salas.\nGuarde e compartilhe com cuidado (LGPD). Esta exportação será registrada na auditoria do servidor.', 'Incluir e exportar'))) return false;
  const itens = []; let apos = null;
  $('#admCsvExcel').disabled = $('#admCsvDados').disabled = true;
  try {
    for (let i = 0; i < 500; i++) {                                   // trava: 500 páginas de 1.000
      info.textContent = `Baixando do servidor… ${itens.length} bens`;
      const r = await Remote.exportarBensPagina(apos, 1000, pess);
      itens.push(...((r && r.itens) || []));
      if (!r || !r.mais) break;
      apos = r.ultimo;
    }
    if (!itens.length) { info.textContent = ''; toast('O servidor não tem bens para exportar.', 'err'); return false; }
    const blob = new Blob([csvDeServidor(itens, modo, pess)], { type: 'text/csv;charset=utf-8' }), name = `patrimonio_servidor_${modo}_${stamp()}.csv`;
    if (!(await saveFile(name, blob))) { info.textContent = ''; return false; }
    info.textContent = `Exportado: ${name} — ${itens.length} bens no servidor (este aparelho tem ${S.bens.length}${S.bens.length < itens.length ? ': falta sincronizar' : ''}).`;
    await gravarOuAvisar([audEntry('exportacao', { tipo: 'servidor_' + modo, arquivo: name, bens: itens.length, dados_pessoais: pess })], { oQue: 'O arquivo FOI gerado, mas o registro local dessa exportação não foi guardado (o servidor registrou).' });
    if (pess) $('#admChkPessoais').checked = false;
    toast('Exportado: ' + name, 'ok');
    return true;
  } catch (e) { info.textContent = ''; toast(e && e.http === 404 ? 'O servidor ainda não tem a migração 008 (exportação).' : msgErroAdmin(e), 'err', 5000); return false; }
  finally { $('#admCsvExcel').disabled = $('#admCsvDados').disabled = false; }
}
// redesenha o que depende de dados que acabaram de chegar do servidor (pull)
function refreshUI() {
  renderSalaBanner(); renderTipos(); renderDescricao(); validateFields(); renderStatus();
  const aba = $$('.tab').find(s => !s.hidden);
  if (aba && aba.id === 'tab-bens') renderBens();
  if (aba && aba.id === 'tab-salas') renderSalas();
  if (aba && aba.id === 'tab-mais') { renderTiposMais(); renderDescricoesMais(); renderLocalidadesMais(); }
}
// tocar numa sala: se a aba Salas foi aberta pelo banner "toque para trocar", SELECIONA a sala para registrar; senão mostra os bens dela
function tocarSala(id) { if (escolhendoSala) usarSala(id); else abrirBensDaSala(id); }
// tocar numa coordenação da planilha: em modo escolha (veio do "toque para trocar") abre o cadastro da sala dessa coordenação, que ao ser
// salvo já seleciona a sala e leva para Registrar; senão mostra os itens da planilha daquela coordenação
function tocarCoordenacao(chave) { if (escolhendoSala) abrirSalaDaCoordenacao(chave); else abrirItensDaPlanilha(chave); }
function abrirBensDaSala(id) { S.filtroSala = id; S.filtroCoord = null; $('#qBens').value = ''; showTab('bens'); }

// ---------- localidades ----------
async function criarLocalidade(txt) {
  const nome = limpaEspacos(txt), nn = normSimples(nome);
  if (!nn) return null;
  const ex = S.localidades.find(l => l.nome_norm === nn);            // evita duplicata (anexo = Anexo)
  if (ex) {
    if (!ex.ativo) {
      ex.ativo = true;
      const ok = await gravarOuAvisar([['localidades', ex], audEntry('localidade_reativada', { nome: ex.nome })]);
      await reload(); if (!ok) return null;
    }
    return S.localidades.find(l => l.nome_norm === nn);
  }
  if (!(await gravarOuAvisar([['localidades', { id: uuid(), nome, nome_norm: nn, ativo: true }], audEntry('localidade_criada', { nome })]))) return null;
  await reload();
  return S.localidades.find(l => l.nome_norm === nn);
}
let localPrev = '';
function renderLocalSelect(sel) {
  const ns = normSimples(sel);
  const itens = S.localidades.filter(l => l.ativo || l.nome_norm === ns).sort((a, b) => a.nome.localeCompare(b.nome, 'pt-BR'));
  $('#sLocal').innerHTML = `<option value="">— sem localidade —</option>` +
    itens.map(l => `<option value="${esc(l.nome)}" ${l.nome_norm === ns ? 'selected' : ''}>${esc(l.nome)}</option>`).join('') +
    `<option value="__nova__">＋ Nova localidade…</option>`;
  localPrev = ns ? (itens.find(l => l.nome_norm === ns) || {}).nome || '' : '';
  $('#sLocal').value = localPrev;
}
async function onLocalChange() {
  const v = $('#sLocal').value;
  if (v !== '__nova__') { localPrev = v; renderSalaSug(); return; }
  const n = await askText('Nova localidade', 'Nome da localidade (ex.: Prédio Central, Anexo):');
  if (!n) { $('#sLocal').value = localPrev; return; }
  const l = await criarLocalidade(n);
  renderLocalSelect(l ? l.nome : localPrev); renderSalaSug();
}
function renderLocalidadesMais() {
  $('#listLocais').innerHTML = S.localidades.slice().sort((a, b) => a.nome.localeCompare(b.nome, 'pt-BR')).map(l => `<span class="chipbtn" style="${l.ativo ? '' : 'opacity:.55'}">${esc(l.nome)} <a href="#" data-lg="${l.id}" aria-label="${l.ativo ? 'Desativar' : 'Reativar'}">${l.ativo ? '✕' : '↺'}</a></span> `).join('');
}

// ---------- tela: salas ----------
let salaEditId = null, cpfAtual = '';
const respDe = s => s.responsavel || {};
// com servidor, sala já sincronizada é editável por qualquer usuário logado e ativo (a edição vai direto ao servidor: ver
// salvarSala); CPF e matrícula do responsável só o administrador lê e altera
const salaNoServidor = s => Engine.ligado && !!(s.servidor || Engine.itemOk('salas', s.id));
const podeEditarSalaServidor = () => Engine.logado && !!(Engine.perfil && Engine.perfil.ativo && !Engine.perfil.deve_trocar_senha);
const salaBloqueada = s => salaNoServidor(s) && !podeEditarSalaServidor();
let escolhendoSala = false;     // true quando a aba Salas foi aberta pelo banner "toque para trocar": tocar numa sala a SELECIONA para registrar
let salaPessoalOk = false;      // CPF/matrícula do servidor já foram lidos para o formulário (admin editando sala do servidor)
function respTxt(s) {
  const r = respDe(s);
  return [r.nome, r.matricula && 'mat. ' + r.matricula, r.siorg && 'SIORG ' + r.siorg, r.uorg && 'UORG resp. ' + r.uorg, r.cpf && 'CPF ' + cpfMask(cpfDigits(r.cpf))].filter(Boolean).join(' · ');
}
function renderSalas() {
  const q = normSimples($('#qSalas').value);
  const cnt = new Map(); S.bens.forEach(b => b.situacao === 'ativo' && cnt.set(b.sala_id, (cnt.get(b.sala_id) || 0) + 1));
  const list = S.salas.filter(s => s.status !== 'mesclada' && (!q || normSimples(salaTexto(s) + ' ' + (respDe(s).nome || '')).includes(q))).sort((a, b) => salaTexto(a).localeCompare(salaTexto(b), 'pt-BR', { numeric: true }));
  const lidos = numerosLidos();
  // coordenação que JÁ tem sala cadastrada não aparece mais como cartão "(planilha)": só a(s) sala(s) dela
  const comSala = new Set(S.salas.filter(s => s.status !== 'mesclada').map(s => chaveCoord(((S.coords.find(x => x.id === s.coordenacao_id)) || {}).nome)).filter(Boolean));
  const coordsHtml = coordenacoesPlanilha().filter(c => !comSala.has(c.chave) && (!q || normSimples(c.nome + ' planilha').includes(q))).map(c => {
    const nl = c.itens.filter(p => lidos.has(normNumero(p.numero))).length, ref = c.itens[0];
    return `<div class="card tap" data-coord="${esc(c.chave)}" role="button" tabindex="0"><div class="num">${esc(c.nome)} <small>(planilha)</small></div><div class="small">${esc([ref.andar, ref.localidade].filter(Boolean).join(' · '))}</div><div class="small">${c.itens.length} itens da planilha · ${nl} já lidos · toque para ver</div><div class="acts"><button class="btn small" data-novasala="${esc(c.chave)}" type="button">Editar</button></div></div>`;
  }).join('');
  const dica = escolhendoSala ? '<div class="banner info">Toque na <b>sala</b> em que vai registrar. Se a sala ainda não existe, toque na <b>coordenação</b> dela (cartão “planilha”) para cadastrá-la e já começar a registrar.</div>' : '';
  $('#listSalas').innerHTML = dica + coordsHtml + list.map(s => {
    const r = respTxt(s);
    return `<div class="card tap" data-ver="${s.id}" role="button" tabindex="0"><div class="num">${esc(s.nome)}${s.id === S.salaId ? ' ✔' : ''}</div><div class="small">${esc(salaTexto(s))}</div>${r ? `<div class="small">Resp.: ${esc(r)}</div>` : ''}<div class="small">${cnt.get(s.id) || 0} bens · toque para ver os bens</div>${(cp => (cp ? `<div class="small">Planilha ${esc(cp.nome)}: ${cp.itens.length} itens · ${cp.itens.filter(p => lidos.has(normNumero(p.numero))).length} já lidos</div>` : ''))(planilhaDaSala(s))}<div class="acts">${salaBloqueada(s) ? '<span class="small">Já sincronizada: entre na conta para editar</span>' : `<button class="btn small" data-edit="${s.id}" type="button">Editar</button>`}</div></div>`;
  }).join('') || (coordsHtml ? '' : '<p class="small">Nenhuma sala cadastrada. Use “Cadastrar sala nova”.</p>');
}
// "＋ Cadastrar sala desta coordenação": abre o formulário de sala NOVA já com coordenação, andar e localidade da planilha
// (e, se a tabela de unidades tiver, UORG e responsável). Depois de salva, a sala aparece como as demais (com Editar e seus bens).
function abrirSalaDaCoordenacao(chave) {
  const c = coordenacoesPlanilha().find(x => x.chave === chave); if (!c) return;
  const ref = c.itens[0];
  abrirSalaPanel(null);
  $('#sCoord').value = c.nome; $('#sAndar').value = ref.andar || ''; renderLocalSelect(ref.localidade || '');
  preencherPelaUnidade(); renderSalaSug();
}
function similaresSala() {
  const n = norm($('#sNome').value); if (!n) return [];
  const and = normSimples($('#sAndar').value), loc = normSimples($('#sLocal').value === '__nova__' ? '' : $('#sLocal').value);
  return S.salas.filter(s => {
    if (s.id === salaEditId || s.status === 'mesclada') return false;
    // "parecida" = igual, ou com 1 letra de diferença (Copa x Copas). Se o nome tem NÚMERO, os números precisam ser iguais:
    // 701 e 702 são salas diferentes, mesmo diferindo em um só dígito.
    const m = norm(s.nome), dig = t => String(t).replace(/\D/g, '');
    if (!(m === n || (n.length > 2 && lev(m, n) <= 1 && dig(m) === dig(n)))) return false;
    return (!and || !s.andar || normSimples(s.andar) === and) && (!loc || !s.localidade || normSimples(s.localidade) === loc);
  });
}
function renderSalaSug() {
  const sim = similaresSala(), coord = chaveCoord($('#sCoord').value);
  $('#sSug').innerHTML = sim.map(s => {
    const c = S.coords.find(c => c.id === s.coordenacao_id);
    const outra = coord && c && chaveCoord(c.nome) !== coord ? ' ⚠ outra coordenação' : '';
    return `Já existe: <b>${esc(salaTexto(s))}</b>${outra} <button class="btn small" data-usar="${s.id}" type="button">Usar esta</button>`;
  }).join('<br>');
}
function abrirSalaPanel(s) {
  salaEditId = s ? s.id : null;
  $('#salaPanelTitulo').textContent = s ? 'Editar sala' : 'Cadastrar sala nova';
  const r = s ? respDe(s) : {};
  $('#sNome').value = s ? s.nome : ''; $('#sCoord').value = s ? ((S.coords.find(c => c.id === s.coordenacao_id) || {}).nome || '') : '';
  $('#sUorg').value = s ? s.uorg || '' : ''; $('#sAndar').value = s ? s.andar || '' : '';
  $('#rNome').value = r.nome || ''; $('#rSiorg').value = r.siorg || ''; $('#rUorg').value = r.uorg || ''; $('#rMat').value = r.matricula || '';
  cpfAtual = cpfDigits(r.cpf); $('#rCpf').value = cpfAtual.length === 11 ? cpfMask(cpfAtual) : cpfAtual; $('#rCpfAlt').textContent = cpfAviso(cpfAtual);
  // sugestões de coordenação: as das salas que já existem + as da planilha de patrimônio e as da tabela de unidades, para
  // elas aparecerem mesmo antes de existir qualquer sala (a primeira grafia vence: salas, depois unidades, depois planilha)
  const coordSug = new Map();
  for (const n of [...S.coords.map(c => c.nome), ...[...unidades.values()].map(u => u.sigla), ...[...planilha.values()].map(p => p.coordenacao)]) {
    const k = normSimples(n); if (k && !coordSug.has(k)) coordSug.set(k, limpaEspacos(n));
  }
  $('#dlCoord').innerHTML = [...coordSug.values()].sort((a, b) => a.localeCompare(b, 'pt-BR')).map(n => `<option value="${esc(n)}">`).join('');
  $('#dlAndar').innerHTML = [...new Set(S.salas.map(x => x.andar).filter(Boolean))].sort().map(v => `<option value="${esc(v)}">`).join('');
  renderLocalSelect(s ? s.localidade || '' : ''); $('#sSug').innerHTML = '';
  salaPessoalOk = false; autoSala = {};
  const pessoalTravado = !!(s && salaNoServidor(s) && !Engine.admin);       // coletor edita a sala do servidor, mas não CPF/matrícula
  $('#rCpf').disabled = pessoalTravado; $('#rMat').disabled = pessoalTravado;
  if (pessoalTravado) $('#rCpfAlt').textContent = 'CPF e matrícula só o administrador vê e altera.';
  if (s && Engine.admin && salaNoServidor(s)) {          // CPF/matrícula só existem no servidor (o pull não os traz): o admin os lê para editar
    $('#rCpfAlt').textContent = 'Carregando CPF e matrícula do servidor…';
    Remote.lerResponsavelPessoal(s.id).then(p => {
      if (salaEditId !== s.id) return;
      p = p || {};
      cpfAtual = cpfDigits(p.cpf); $('#rCpf').value = cpfAtual.length === 11 ? cpfMask(cpfAtual) : cpfAtual; $('#rMat').value = p.matricula || '';
      $('#rCpfAlt').textContent = cpfAviso(cpfAtual); salaPessoalOk = true;
    }).catch(() => { if (salaEditId === s.id) $('#rCpfAlt').textContent = 'Sem conexão: CPF e matrícula não foram carregados e NÃO serão alterados.'; });
  }
  $('#salaPanel').hidden = false; $('#salaPanel').scrollTop = 0;
  setTimeout(() => $('#sNome').focus(), 50);
}
const fecharSalaPanel = () => { $('#salaPanel').hidden = true; salaEditId = null; };
// Tempo máximo esperando o servidor ao editar uma sala já sincronizada. Sem isto, uma conexão que "pendura" deixava a pessoa sem
// resposta nenhuma e o botão travado. (let: o teste headless encurta o prazo.)
let salaTimeoutMs = 20000;
const comTimeout = (promessa, ms) => new Promise((resolve, reject) => {
  const t = setTimeout(() => { const e = new Error('tempo esgotado'); e.rede = true; reject(e); }, ms);
  promessa.then(v => { clearTimeout(t); resolve(v); }, e => { clearTimeout(t); reject(e); });
});
// Trava contra TOQUE DUPLO em "Salvar sala": sem ela, o segundo toque (durante a gravação/recarga, quando o painel ainda está aberto e
// a sala nova ainda não está em S.salas, então nem o aviso de "sala parecida" aparece) criava uma SEGUNDA sala e uma SEGUNDA coordenação.
let salvandoSala = false;
const MSG_SALVANDO_SALA = 'Salvando no servidor…';
async function salvarSala() {
  if (salvandoSala) return;
  const btn = $('#btnSalvarSala'), rotulo = btn.textContent;
  salvandoSala = true;
  btn.disabled = true; btn.textContent = 'Salvando…';
  try { await salvarSalaAgora(); }
  finally { salvandoSala = false; btn.disabled = false; btn.textContent = rotulo; if ($('#toast').textContent === MSG_SALVANDO_SALA) $('#toast').hidden = true; }
}
async function salvarSalaAgora() {
  // a sala em edição é guardada AGORA: depois do await do servidor a pessoa pode ter tocado em Cancelar/"Usar esta" (que zeram salaEditId), e
  // aí a edição era tratada como sala NOVA: o servidor aceitava a edição e o aparelho criava e enviava uma sala duplicada
  const editId = salaEditId;
  const nome = limpaEspacos($('#sNome').value), cn = limpaEspacos($('#sCoord').value);
  // uorg e andar também são lidos AGORA: depois do await do servidor o painel pode ter sido fechado/reaberto com outra sala
  const uorg = $('#sUorg').value.trim(), andar = limpaEspacos($('#sAndar').value);
  if (!nome || !cn) { toast('Informe o nome da sala e a coordenação.', 'err'); return; }
  const sim = similaresSala();
  if (sim.length) {
    const outra = sim.filter(s => { const c = S.coords.find(c => c.id === s.coordenacao_id); return c && chaveCoord(c.nome) !== chaveCoord(cn); });
    if (!(await confirmBox('Sala parecida já existe', sim.map(s => '• ' + salaTexto(s)).join('\n') + (outra.length ? '\n\n⚠ Existe com OUTRA coordenação.' : '') + `\n\n${editId ? 'Salvar' : 'Criar uma sala nova'} mesmo assim?`, editId ? 'Salvar mesmo assim' : 'Criar mesmo assim'))) return;
  }
  const loc = $('#sLocal').value === '__nova__' ? '' : $('#sLocal').value;
  const resp = { nome: limpaEspacos($('#rNome').value), siorg: $('#rSiorg').value.trim(), uorg: $('#rUorg').value.trim(), cpf: cpfAtual, matricula: $('#rMat').value.trim() };
  // sala que já está no servidor: a alteração vai ANTES ao servidor (sem conexão, não salva: evita divergir do que os outros veem)
  const salaAtual = editId ? salaDe(editId) : null;
  if (salaAtual && salaNoServidor(salaAtual)) {
    if (!podeEditarSalaServidor()) { toast('Entre na conta para editar uma sala já sincronizada.', 'err', 3500); return; }
    if (!Engine.admin || !salaPessoalOk) { const a = respDe(salaAtual); resp.cpf = a.cpf || ''; resp.matricula = a.matricula || ''; }   // coletor, ou admin que não leu: não altera
    try {
      toast(MSG_SALVANDO_SALA, '', salaTimeoutMs + 1000);
      const pay = { id: editId, nome, coordenacao: cn, uorg, andar, localidade: loc,
        responsavel_nome: resp.nome, responsavel_siorg: resp.siorg, responsavel_uorg: resp.uorg };
      if (Engine.admin && salaPessoalOk) { pay.responsavel_cpf = resp.cpf; pay.responsavel_matricula = resp.matricula; }
      const r = await comTimeout(Promise.resolve(Remote.atualizarSala(pay)), salaTimeoutMs);
      if (!r || !r.ok) { toast('O servidor não aceitou a edição (' + ((r && r.erro) || 'erro') + ').', 'err', 4500); return; }
    } catch (e) {
      const semFuncao = e && e.http === 404;
      toast(e && e.rede ? 'Sem conexão: sala do servidor só pode ser editada com internet.' : semFuncao ? 'O servidor ainda não tem a migração 004 (edição de sala). Avise o administrador.' : e && e.permissao ? 'Sem permissão no servidor: conta sem perfil ativo.' : 'Erro ao editar no servidor: ' + (e && e.message), 'err', 4500);
      return;
    }
  }
  const entries = []; let coord = S.coords.find(c => normSimples(c.nome) === normSimples(cn));
  if (!coord) { coord = { id: uuid(), nome: cn, nome_norm: normSimples(cn), criado_em: nowISO(), criado_por: S.user }; entries.push(['coordenacoes', coord]); }
  const novos = { nome, nome_norm: norm(nome), coordenacao_id: coord.id, uorg, andar, localidade: loc, responsavel: resp };
  let sala;
  if (editId) {
    sala = salaDe(editId);
    const antes = { ...sala, coordenacao_id: sala.coordenacao_id }, ar = respDe(sala);
    const campos = ['nome', 'coordenacao_id', 'uorg', 'andar', 'localidade'].filter(k => (antes[k] || '') !== (novos[k] || ''));
    ['nome', 'siorg', 'uorg', 'cpf', 'matricula'].forEach(k => { if ((ar[k] || '') !== (resp[k] || '')) campos.push('responsavel_' + k); });
    Object.assign(sala, novos, { atualizado_em: nowISO() });
    entries.push(['salas', sala], audEntry('sala_editada', { sala: sala.id, campos }));   // nunca grava CPF na auditoria
  } else {
    sala = { id: uuid(), ...novos, criado_em: nowISO(), criado_por: S.user, dispositivo: S.device, elegivel_sync: !!S.syncDono };
    entries.push(['salas', sala], ['meta', { k: 'sala_atual', v: sala.id }], audEntry('sala_criada', { sala: sala.id, nome }));
  }
  if (!(await gravarOuAvisar(entries))) { await reload(); return; }          // falhou: o formulário continua aberto para tentar de novo
  if (!editId) S.salaId = sala.id; await reload();
  const novaSala = !editId; if (salaEditId === editId) fecharSalaPanel();
  toast(novaSala ? 'Sala criada e selecionada.' : 'Sala atualizada.', 'ok'); renderSalas(); renderSalaBanner();
  if (novaSala) showTab('registrar');
}
async function usarSala(id) {
  if (!(await gravarOuAvisar([['meta', { k: 'sala_atual', v: id }]]))) return;
  S.salaId = id; fecharSalaPanel(); renderSalaBanner(); renderSalas(); showTab('registrar'); toast('Sala selecionada.', 'ok', 1200);
}

// ---------- tela: diagnóstico ----------
let scanDiag; const diagRows = new Map();
function onScanDiag(r) {
  const key = r.format + '|' + r.rawValue; let row = diagRows.get(key);
  if (!row) { row = { ...r, n: 0, first: new Date() }; diagRows.set(key, row); feedback('ok', 'flashD'); }
  row.n++; row.last = new Date(); renderDiag();
}
function renderDiag() {
  const rows = [...diagRows.values()].sort((a, b) => b.last - a.last);
  $('#diagLog').innerHTML = rows.map(r => `<div class="card"><div class="small">simbologia</div><b>${esc(r.format)}</b>
    <div class="small">conteúdo lido (entre aspas)</div><div class="raw">"${esc(r.rawValue)}"</div>
    <div class="small">${r.rawValue.length} caracteres · lido ${r.n}× · motor: ${esc(r.engine)} · vídeo ${r.w}×${r.h}</div>
    <div class="small">códigos: ${[...r.rawValue].map(c => c.charCodeAt(0)).join(' ')}</div></div>`).join('') || '<p class="small">Nenhuma leitura ainda.</p>';
}
function diagText() {
  return [`Diagnóstico — ${fmtBR(nowISO())} — app ${VERSION}`, navigator.userAgent, ''].concat(
    [...diagRows.values()].map(r => `${r.format}\t"${r.rawValue}"\t${r.rawValue.length} car.\t${r.n}x\t${r.engine}\t${r.w}x${r.h}`)).join('\n');
}

// ---------- exportação ----------
const CSV_COLS = ['id_bem', 'patrimonio_curto', 'patrimonio_longo', 'patrimonio_outro', 'codigo_provisorio', 'etiquetado_em_campo', 'tipo_bem', 'descricao', 'item_material', 'marca', 'fornecedor', 'coordenacao', 'uorg_sala', 'andar', 'localidade', 'sala', 'legado_niveis_org', 'responsavel_siorg', 'responsavel_uorg', 'observacao', 'origem_leitura', 'alerta_formato', 'duplicidade', 'situacao', 'registrado_por', 'sigla_usuario', 'registrado_em', 'atualizado_em', 'numero_catalogo_legado', 'plaqueta_outro_orgao'];
const CSV_COLS_PESSOAIS = ['responsavel_nome', 'responsavel_matricula', 'responsavel_cpf'];
function csvText(v) { // texto livre: neutraliza fórmulas e escapa aspas
  let s = String(v ?? ''); if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;
  return '"' + s.replace(/"/g, '""') + '"';
}
const alertasDe = et => et.map(e => alertaNumero(e.numero, e.serie) && `${e.numero}: ${alertaNumero(e.numero, e.serie)}`).filter(Boolean).join(' | ');
const duplicidadeDe = (b, idx) => { const di = dupInfo(b, idx); return [di.f.length && 'repetido: ' + di.f.join(', '), di.l.length && 'outra série: ' + di.l.join(', ')].filter(Boolean).join(' | '); };
// Uma linha do CSV a partir de um registro NORMALIZADO (serve ao CSV deste aparelho e ao CSV baixado do servidor: mesmas colunas).
// `="..."` (para o Excel não tirar o zero à esquerda) SÓ para valores que são apenas dígitos. Qualquer outro texto
// (inclusive o que vem de um código de barras) passa por csvText, que escapa aspas e neutraliza = + - @ (auditoria A-3).
function linhaCSV(modo, pessoais, r) {
  const soDigitos = v => /^\d+$/.test(v);
  const textoCol = v => (!v ? '' : modo === 'excel' && soDigitos(v) ? `="${v}"` : csvText(v));
  const serieCol = serie => {
    const v = etqs(r).filter(e => e.serie === serie).map(e => e.numero);
    if (!v.length) return '';
    return modo === 'excel' && v.length === 1 && soDigitos(v[0]) ? `="${v[0]}"` : csvText(v.join(' | '));
  };
  const cols = [csvText(r.id), serieCol('curto'), serieCol('longo'), serieCol('outra'), csvText(r.codigo_provisorio), csvText(r.etiquetado_em_campo ? 'sim' : 'não'),
    csvText(r.tipo_bem === OUTRO ? 'OUTRO: ' + r.tipo_bem_outro : r.tipo_bem), csvText(r.descricao), textoCol(r.item_material), csvText(r.marca), csvText(r.fornecedor),
    csvText(r.coordenacao), csvText(r.uorg_sala), csvText(r.andar), csvText(r.localidade), csvText(r.sala),
    csvText(r.legado), csvText(r.responsavel_siorg), csvText(r.responsavel_uorg),
    csvText(r.observacao), csvText(etqs(r).map(e => `${e.numero}:${e.origem}`).join(' | ')),
    csvText(r.alertas), csvText(r.duplicidade), csvText(r.situacao), csvText(r.registrado_por), csvText(r.sigla), csvText(r.registrado_em), csvText(r.atualizado_em),
    textoCol(r.numero_siads || catalogoDoBem(r)), csvText(etqs(r).some(e => ehPlaquetaOutroOrgao(e.numero)) ? 'sim' : '')];   // v0.8.0: catálogo legado pela plaqueta antiga (r.numero_siads = nome histórico do esquema); outro órgão = plaqueta "A..."
  if (pessoais) cols.push(csvText(r.responsavel_nome), textoCol(r.responsavel_matricula), textoCol(r.responsavel_cpf));
  return cols.join(';');
}
// pessoais = incluir nome, matrícula e CPF do responsável (só quando o usuário marcar e confirmar)
function buildCSV(modo, pessoais = false) {
  const idx = dupIndex(), lines = [(pessoais ? [...CSV_COLS, ...CSV_COLS_PESSOAIS] : CSV_COLS).join(';')];
  for (const b of S.bens.slice().sort((a, c) => (a.criado_em > c.criado_em ? 1 : -1))) {
    const s = salaDe(b.sala_id), c = s && S.coords.find(c => c.id === s.coordenacao_id), r = s ? respDe(s) : {}, lg = (s && s.legado) || {};
    lines.push(linhaCSV(modo, pessoais, {
      id: b.id, etiquetas: etqs(b), codigo_provisorio: b.codigo_provisorio, etiquetado_em_campo: b.etiquetado_em_campo, tipo_bem: b.tipo_bem, tipo_bem_outro: b.tipo_bem_outro,
      descricao: b.descricao, item_material: b.item_material, marca: b.marca, fornecedor: b.fornecedor,
      coordenacao: c && c.nome, uorg_sala: s && s.uorg, andar: s && s.andar, localidade: s && s.localidade, sala: s && s.nome,
      legado: [lg.nivel_org_1, lg.nivel_org_2, lg.nivel_org_3].filter(Boolean).join(' / '), responsavel_siorg: r.siorg, responsavel_uorg: r.uorg,
      observacao: b.observacao, alertas: alertasDe(etqs(b)), duplicidade: duplicidadeDe(b, idx), situacao: b.situacao, registrado_por: b.criado_por, sigla: b.sigla,
      registrado_em: fmtBR(b.criado_em), atualizado_em: fmtBR(b.atualizado_em), numero_siads: b.numero_siads,
      responsavel_nome: r.nome, responsavel_matricula: r.matricula, responsavel_cpf: cpfDigits(r.cpf) }));
  }
  return '﻿' + lines.join('\r\n') + '\r\n';
}
// CSV a partir dos bens baixados do SERVIDOR (exportar_bens_pagina): mesmas colunas e regras do CSV deste aparelho
function csvDeServidor(itens, modo, pessoais = false) {
  const idx = dupIndex(itens.map(i => ({ id: i.id, situacao: i.situacao, etiquetas: i.etiquetas || [] })));
  const lines = [(pessoais ? [...CSV_COLS, ...CSV_COLS_PESSOAIS] : CSV_COLS).join(';')];
  const quando = i => i.registrado_em || i.recebido_em || '';
  for (const i of itens.slice().sort((a, c) => (quando(a) > quando(c) ? 1 : -1))) {
    const et = i.etiquetas || [], lg = i.legado || {};
    lines.push(linhaCSV(modo, pessoais, { ...i, etiquetas: et,
      legado: [lg.nivel_org_1, lg.nivel_org_2, lg.nivel_org_3].filter(Boolean).join(' / '),
      alertas: alertasDe(et), duplicidade: duplicidadeDe({ id: i.id, situacao: i.situacao, etiquetas: et }, idx),
      registrado_em: fmtBR(quando(i)), atualizado_em: fmtBR(i.atualizado_em), responsavel_cpf: cpfDigits(i.responsavel_cpf) }));
  }
  return '﻿' + lines.join('\r\n') + '\r\n';
}
async function saveFile(name, blob) {
  const file = new File([blob], name, { type: blob.type });
  if (IS_IOS && navigator.canShare && navigator.canShare({ files: [file] })) {
    try { await navigator.share({ files: [file], title: name }); return true; } catch (e) { if (e.name === 'AbortError') return false; }
  }
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name;
  document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 30000); return true;
}
const stamp = () => { const p = fmtBR(nowISO()); return `${p.slice(6, 10)}${p.slice(3, 5)}${p.slice(0, 2)}_${p.slice(11, 13)}${p.slice(14, 16)}${p.slice(17, 19)}`; };
// v0.7.4: situação de cada item da PLANILHA (para o abatimento). "Localizado" = existe bem ATIVO com esse número (deste ou de outro
// aparelho, até a última sincronização). Sem dados pessoais. Para Excel (número como ="01888").
const CSV_COLS_PLANILHA = ['numero', 'tipo_planilha', 'marca_planilha', 'coordenacao_planilha', 'andar_planilha', 'localidade_planilha',
  'situacao', 'outra_coordenacao', 'sala_onde_foi_lido', 'coordenacao_da_sala', 'tipo_registrado', 'lido_por', 'lido_em'];
function csvPlanilha() {
  const lidos = numerosLidos(), num = v => (/^\d+$/.test(String(v)) ? `="${v}"` : csvText(v));
  const itens = [...planilha.values()].sort((a, b) => (chaveCoord(a.coordenacao)).localeCompare(chaveCoord(b.coordenacao)) || String(a.numero).localeCompare(String(b.numero)));
  const linhas = itens.map(p => {
    const b = lidos.get(normNumero(p.numero)), s = b ? salaDe(b.sala_id) : null;
    const cs = s ? ((S.coords.find(c => c.id === s.coordenacao_id)) || {}).nome || '' : '';
    const outra = !!(b && cs && chaveCoord(p.coordenacao) && chaveCoord(cs) !== chaveCoord(p.coordenacao));
    return [num(p.numero), csvText(p.tipo), csvText(p.marca), csvText(p.coordenacao), csvText(p.andar), csvText(p.localidade),
      csvText(b ? 'localizado' : 'nao localizado'), csvText(outra ? 'sim' : ''), csvText(s ? salaTexto(s) : ''), csvText(cs),
      csvText(b ? tipoTxt(b) : ''), csvText(b ? b.criado_por || '' : ''), csvText(b ? fmtBR(b.criado_em) : '')].join(';');
  });
  return '﻿' + [CSV_COLS_PLANILHA.join(';'), ...linhas].join('\r\n') + '\r\n';
}
async function exportarPlanilha() {
  if (!planilha.size) { toast('A planilha de consulta ainda não foi baixada (sincronize).', 'err', 3500); return false; }
  const lidos = numerosLidos(), n = [...planilha.values()].filter(p => lidos.has(normNumero(p.numero))).length;
  const name = `planilha_localizados_${stamp()}.csv`;
  if (!(await saveFile(name, new Blob([csvPlanilha()], { type: 'text/csv;charset=utf-8' })))) return false;
  await gravarOuAvisar([audEntry('exportacao', { tipo: 'planilha', arquivo: name, itens: planilha.size, localizados: n })], { oQue: 'O arquivo FOI gerado, mas o registro dessa exportação na auditoria NÃO foi guardado.' });
  toast(`Exportado: ${name} — ${n} de ${planilha.size} localizados (até a última sincronização)`, 'ok', 4500);
  return true;
}
// devolve true só se o arquivo foi entregue ao navegador/compartilhamento (false = cancelou ou nada a exportar)
async function exportar(tipo) {
  if (!S.bens.length) { toast('Nada para exportar ainda.', 'err'); return false; }
  const temPessoais = S.salas.some(s => { const r = respDe(s); return !!(r.cpf || r.matricula); });
  const pess = tipo !== 'json' && $('#chkPessoais').checked;
  const contemPessoais = tipo === 'json' ? temPessoais : pess;              // o JSON leva TUDO, inclusive CPF e matrícula
  if (contemPessoais && !(await confirmBox('Incluir dados pessoais?',
    tipo === 'json' ? 'A cópia completa (JSON) contém TUDO, inclusive CPF e matrícula completos dos responsáveis pelas salas, em texto aberto.\nGuarde em local seguro (LGPD). Esta exportação será registrada na auditoria.'
                    : 'O arquivo vai conter nome, matrícula e CPF completo dos responsáveis pelas salas.\nGuarde e compartilhe com cuidado (LGPD). Esta exportação será registrada na auditoria.', 'Incluir e exportar'))) return false;
  let blob, name;
  if (tipo === 'json') {
    blob = new Blob([JSON.stringify({ versao_app: VERSION, exportado_em: nowISO(), usuario: S.user, sigla: S.sigla, dispositivo: S.device, coordenacoes: S.coords, salas: S.salas, localidades: S.localidades, tipos: S.tipos, descricoes: S.descricoes, bens: S.bens, auditoria: S.aud }, null, 1)], { type: 'application/json' });
    name = `patrimonio_backup_${stamp()}.json`;
  } else {
    blob = new Blob([buildCSV(tipo, pess)], { type: 'text/csv;charset=utf-8' });
    name = `patrimonio_${tipo}_${stamp()}.csv`;
  }
  if (await saveFile(name, blob)) {
    await gravarOuAvisar([audEntry('exportacao', { tipo, arquivo: name, bens: S.bens.length, dados_pessoais: contemPessoais })], { oQue: 'O arquivo FOI gerado, mas o registro dessa exportação na auditoria NÃO foi guardado.' }); await reload(); renderAud();
    if (pess) $('#chkPessoais').checked = false;
    toast('Exportado: ' + name, 'ok');
    return true;
  }
  return false;
}

// ---------- tela: mais ----------
function renderTiposMais() {
  $('#listTipos').innerHTML = S.tipos.slice().sort((a, b) => a.nome.localeCompare(b.nome)).map(t => `<span class="chipbtn" style="${t.ativo ? '' : 'opacity:.55'}">${esc(t.nome)} <a href="#" data-tg="${t.id}">${t.ativo ? '✕' : '↺'}</a></span> `).join('');
}
function renderDescricoesMais() {
  const sel = $('#dTipo'), atual = sel.value, q = normSimples($('#dBusca').value);
  sel.innerHTML = '<option value="">(todos os tipos)</option>' + S.tipos.slice().sort((a, b) => a.nome.localeCompare(b.nome, 'pt-BR')).map(t => `<option value="${esc(t.nome)}">${esc(t.nome)}</option>`).join('');
  sel.value = atual;
  const nomesTipos = new Set(S.tipos.map(t => normSimples(t.nome))), orfas = S.descricoes.filter(d => !nomesTipos.has(d.tipo_norm)).length;
  $('#infoDesc').textContent = S.descricoes.length
    ? `${S.descricoes.length} descrições (${S.descricoes.filter(d => d.ativo).length} ativas)${orfas ? ` · ${orfas} de tipo que não está na lista de tipos` : ''}`
    : 'Nenhuma descrição ainda. Coloque um descricoes.json na raiz do app ou adicione abaixo.';
  const tn = normSimples(sel.value);
  const lista = S.descricoes.filter(d => (!tn || d.tipo_norm === tn) && (!q || normSimples(d.texto + ' ' + d.item_material + ' ' + d.tipo).includes(q)))
    .sort((a, b) => a.texto.localeCompare(b.texto, 'pt-BR'));
  $('#listDesc').innerHTML = lista.slice(0, 100).map(d => `<div class="card ${d.ativo ? '' : 'anulado'}"><div>${esc(d.texto)}</div><div class="small">${esc(d.tipo)}${d.item_material ? ' · Item Material ' + esc(d.item_material) : ''} · ${d.origem === 'siads' ? 'catálogo legado' : 'cadastrada no app'}</div><div class="acts"><button class="btn small" data-dedit="${d.id}" type="button">Editar</button><button class="btn small" data-dtog="${d.id}" type="button">${d.ativo ? 'Desativar' : 'Reativar'}</button></div></div>`).join('')
    + (lista.length > 100 ? `<p class="small">Mostrando 100 de ${lista.length}. Use a busca ou o filtro de tipo.</p>` : '')
    || '<p class="small">Nenhuma descrição neste filtro.</p>';
}
// com servidor, tipos, descrições e localidades são do administrador (fase 2b); aqui só leitura
function listasSoAdmin() {
  if (!Engine.ligado) return false;
  toast('Com servidor, as listas só o administrador edita (fase 2b).', 'err', 3500); return true;
}
async function onDescricoesClick(e) {
  const a = e.target.closest('button'); if (!a || listasSoAdmin()) return;
  const d = S.descricoes.find(x => x.id === (a.dataset.dedit || a.dataset.dtog)); if (!d) return;
  if (a.dataset.dtog) {
    d.ativo = !d.ativo;
    if (!(await gravarOuAvisar([['descricoes', d], audEntry(d.ativo ? 'descricao_reativada' : 'descricao_desativada', { descricao: d.texto })]))) { await reload(); renderDescricoesMais(); return; }
  } else {
    const t = await askText('Editar descrição', 'Texto da descrição (bens já salvos não mudam):', { value: d.texto }); if (!t) return;
    const m = await askText('Item Material', 'Código Item Material (opcional):', { required: false, value: d.item_material }); if (m === null) return;
    const antes = d.texto; d.texto = limpaEspacos(t); d.texto_norm = normSimples(d.texto); d.item_material = m.trim();
    if (!(await gravarOuAvisar([['descricoes', d], audEntry('descricao_editada', { de: antes, para: d.texto })]))) { await reload(); renderDescricoesMais(); return; }
  }
  await reload(); renderDescricoesMais();
}
async function adicionarDescricao() {
  if (listasSoAdmin()) return;
  const tipo = $('#dTipo').value, texto = limpaEspacos($('#dNova').value), mat = $('#dMat').value.trim();
  if (!tipo) { toast('Escolha o tipo no filtro acima antes de adicionar.', 'err'); return; }
  if (!texto) { toast('Digite a descrição.', 'err'); return; }
  const tn = normSimples(tipo), kn = normSimples(texto);
  if (S.descricoes.some(d => d.tipo_norm === tn && d.texto_norm === kn && (d.item_material || '') === mat)) { toast('Essa descrição já existe neste tipo.', 'err'); return; }
  if (!(await gravarOuAvisar([['descricoes', { id: uuid(), tipo, tipo_norm: tn, texto, texto_norm: kn, item_material: mat, ativo: true, origem: 'app' }], audEntry('descricao_criada', { tipo, descricao: texto })]))) return;
  $('#dNova').value = ''; $('#dMat').value = ''; await reload(); renderDescricoesMais(); toast('Descrição adicionada.', 'ok');
}
function renderAud() {
  $('#listAud').innerHTML = S.aud.slice(0, 40).map(a => `${esc(fmtBR(a.em))} · ${esc(a.usuario)} · <b>${esc(a.acao)}</b>`).join('<br>') || 'Sem eventos.';
}
// Uma única leitura de estado e uma única escrita no DOM: faixa do topo e aba Mais sempre mostram o mesmo valor.
// (Na v0.2 as duas partes eram escritas em momentos diferentes e uma chamada antiga podia sobrescrever a nova.)
let storageSeq = 0;
async function renderStorage() {
  const my = ++storageSeq;
  const standalone = window.matchMedia('(display-mode: standalone)').matches || navigator.standalone;
  const persisted = navigator.storage && navigator.storage.persisted ? await navigator.storage.persisted() : null;
  let est = null; try { est = navigator.storage && navigator.storage.estimate ? await navigator.storage.estimate() : null; } catch {}
  if (my !== storageSeq) return;                       // chegou uma chamada mais nova: descarta esta
  const st = $('#statusStorage');
  st.textContent = persisted ? 'armazenamento: protegido' : persisted === false ? 'armazenamento: NÃO garantido' : 'armazenamento: ?';
  st.className = 'chip ' + (persisted ? 'good' : 'bad');
  let h = `Armazenamento persistente: <b>${persisted === null ? 'não suportado' : persisted ? 'sim (protegido)' : 'não (NÃO garantido)'}</b><br>App instalado na tela inicial: <b>${standalone ? 'sim' : 'não'}</b><br>`;
  if (est) h += `Uso: ${(est.usage / 1048576).toFixed(1)} MB de ${(est.quota / 1048576).toFixed(0)} MB<br>`;
  h += `Duração das gravações: <b>${'durability' in IDBTransaction.prototype ? 'estrita (suportado)' : 'padrão do navegador'}</b><br>Servidor: <b>${esc(Remote.nome)}</b>${Remote.configurado() ? '' : ' (somente neste aparelho)'}`;
  $('#infoStorage').innerHTML = h;
  const w = $('#installWarn');
  if (!standalone && IS_IOS) { w.hidden = false; w.textContent = 'iPhone: instale o app na tela inicial (Compartilhar → Adicionar à Tela de Início) ANTES de registrar. Dados feitos no Safari não passam para o app instalado.'; } else w.hidden = true;
  renderCompat(standalone);
}
function renderCompat(standalone) {
  const box = $('#infoIOS'); box.hidden = !IS_IOS; if (!IS_IOS) return;
  if (standalone === undefined) standalone = window.matchMedia('(display-mode: standalone)').matches || navigator.standalone;
  const lanterna = S.torch === null ? 'será detectada quando a câmera ligar (costuma ser indisponível no iPhone)' : S.torch ? 'disponível' : 'indisponível';
  box.innerHTML = `<b>Compatibilidade no iPhone/iPad:</b> vibração ${'vibrate' in navigator ? 'disponível' : 'indisponível (o aviso é só visual)'} · o som pode ficar mudo com a chave de silêncio · lanterna ${lanterna} · ${standalone ? 'rodando pela tela inicial ✔' : '⚠ rodando fora da tela inicial (Safari)'}.`;
}
function renderStatus() {
  $('#statusSaved').textContent = `💾 ${S.bens.filter(b => b.situacao === 'ativo' && !b.servidor).length} salvos neste aparelho`;
  $('#infoUser').innerHTML = `Usuário: <b>${esc(S.user)}</b> · Sigla: <b>${esc(S.sigla)}</b> · Aparelho: <code>${esc(S.device.slice(0, 8))}</code>`;
}
async function apagarTudo() {
  if (!S.bens.length && !S.salas.length) { toast('Nada para apagar.'); return; }
  if (Engine.ligado) {                                   // com servidor: nunca limpar com pendências
    const p = await Engine.pendentes();
    if (p > 0) {
      await modal({ title: 'Não dá para limpar agora', msg: `Há ${p} registro(s) ainda não confirmados no servidor.\nConecte-se, use “Sincronizar agora” e espere zerar os pendentes. Nada foi apagado.`, okLabel: 'Entendi', cancel: false });
      return;
    }
  }
  await modal({ title: 'Antes de apagar', msg: `Vou baixar uma cópia completa (JSON) com ${S.bens.length} bens. Guarde o arquivo.`, okLabel: 'Baixar cópia', cancel: false });
  const salvo = await exportar('json');
  if (!salvo) { toast('A cópia não foi salva. Nada foi apagado.', 'err', 5000); return; }
  if (!(await confirmBox('O arquivo foi salvo?', 'Confira nos Downloads (ou onde você escolheu salvar) se o arquivo patrimonio_backup_….json existe.\nSem ele, o que for apagado NÃO pode ser recuperado.', 'Sim, o arquivo está salvo'))) { toast('Cancelado. Nada foi apagado.'); return; }
  const t = await askText('Confirmar exclusão', `Isto APAGA ${S.bens.length} bens, ${S.salas.length} salas e a auditoria deste aparelho. Digite APAGAR para confirmar.`);
  if (t !== 'APAGAR') { toast('Cancelado.'); return; }
  const tx = T([...STORES, 'meta'], true);
  [...STORES, 'meta'].forEach(n => tx.objectStore(n).clear()); await txDone(tx);
  location.reload();
}

// ---------- navegação ----------
function showTab(name) {
  $$('.tab').forEach(s => (s.hidden = s.id !== 'tab-' + name));
  $$('#nav button').forEach(b => b.classList.toggle('on', b.dataset.tab === name));
  if (name !== 'registrar' && scanReg) scanReg.stop(), ($('#btnScan').textContent = '📷 Ligar câmera');
  if (name !== 'diag' && scanDiag) scanDiag.stop(), ($('#btnScanD').textContent = '📷 Ligar câmera');
  if (name !== 'salas') escolhendoSala = false;               // o modo "escolher a sala para registrar" só vale enquanto a aba Salas está aberta
  if (name === 'bens') renderBens();
  if (name === 'salas') renderSalas();
  if (name === 'mais') { Engine.renderMais(); renderAdmin(); renderTiposMais(); renderDescricoesMais(); renderLocalidadesMais(); renderAud(); renderStorage(); aplicarTema(temaAtual(), false); }
  window.scrollTo(0, 0);
}
async function toggleScanner(sc, btn) {
  unlockAudio();
  if (sc.running) { sc.stop(); btn.textContent = '📷 Ligar câmera'; return; }
  btn.disabled = true;
  try { await sc.start(); btn.textContent = '⏹ Desligar câmera'; renderCompat(); }
  catch (e) { toast('Câmera: ' + (e.name === 'NotAllowedError' ? 'permissão negada. Libere a câmera nas configurações do navegador.' : e.message), 'err', 5000); sc.stop(); }
  btn.disabled = false;
}

// ---------- service worker: instalação e atualização (M-5) ----------
// Cada versão do app vive num cache só (sw.js). Uma versão nova é instalada por inteiro, em segundo plano, e FICA ESPERANDO:
// o app só troca quando a pessoa toca em "Atualizar agora". Assim ninguém perde o que está digitando e nunca se mistura
// HTML novo com JS velho. Se a instalação falhar (arquivo ausente, sem rede), o app avisa e continua na versão atual.
function iniciarSW() {
  if (!('serviceWorker' in navigator) || !(location.protocol === 'https:' || location.hostname === 'localhost')) return;
  const sw = navigator.serviceWorker, tinhaControle = !!sw.controller;
  let recarregando = false;
  sw.addEventListener('controllerchange', () => { if (tinhaControle && !recarregando) { recarregando = true; location.reload(); } });
  const oferecer = worker => {
    const b = $('#updateBanner'); if (!b) return;
    b.hidden = false;
    b.innerHTML = 'Há uma versão nova do app. Termine o que está fazendo e toque em <button class="btn small primary" id="btnAtualizar" type="button">Atualizar agora</button>';
    $('#btnAtualizar').onclick = () => { $('#btnAtualizar').disabled = true; worker.postMessage('pular-espera'); };
  };
  sw.register('sw.js').then(reg => {
    if (reg.waiting && sw.controller) oferecer(reg.waiting);
    reg.addEventListener('updatefound', () => {
      const w = reg.installing; if (!w) return;
      w.addEventListener('statechange', () => {
        if (w.state === 'installed' && sw.controller) oferecer(w);
        else if (w.state === 'redundant' && !reg.waiting && !reg.installing) {
          toast(sw.controller ? 'Não foi possível baixar a versão nova por completo (sem rede ou arquivo ausente). O app continua na versão atual.'
            : 'ATENÇÃO: o uso sem internet NÃO foi preparado (falha ao baixar os arquivos do app). Abra o app de novo com internet.', 'err', 9000);
        }
      });
    });
    const checar = () => reg.update().catch(() => {});
    document.addEventListener('visibilitychange', () => { if (!document.hidden) checar(); });
    setInterval(checar, 30 * 60 * 1000);
  }).catch(e => toast('Não consegui registrar o service worker: ' + ((e && e.message) || e) + '. O app funciona, mas não abre sem internet.', 'err', 8000));
}

// ---------- inicialização ----------
async function init() {
  aplicarTema(temaAtual(), false);
  if (window.matchMedia) { const mq = matchMedia('(prefers-color-scheme: dark)'); (mq.addEventListener ? mq.addEventListener.bind(mq, 'change') : mq.addListener.bind(mq))(() => aplicarTema(temaAtual(), false)); }
  if (IS_IOS) document.body.classList.add('ios');
  db = await openDB();
  S.device = (await getMeta('device_id')) || uuid(); await setMeta('device_id', S.device);
  if (!(await getAll('tipos')).length) await writeMany(TIPOS_INICIAIS.map(n => ['tipos', { id: uuid(), nome: n, ativo: true, usos: 0 }]));
  await reload(); await migrar(); await carregarPlanilha(); await carregarUnidades(); await carregarCatalogoLegado();
  importarDescricoes().catch(() => {});             // em segundo plano; sem o arquivo, o app segue normal
  S.salaId = (await getMeta('sala_atual')) || null;
  S.user = (await getMeta('usuario')) || '';
  S.sigla = (await getMeta('sigla')) || '';
  S.syncDono = (await getMeta('sync_user_id')) || null;
  if (!Remote.configurado()) {                         // com servidor, nome e sigla vêm do perfil (primeiro login)
    if (!S.user) { S.user = await askText('Bem-vindo', 'Seu nome (vai constar em “quem registrou”):', { cancel: false }); await setMeta('usuario', S.user); }
    if (!S.sigla) { S.sigla = await askSigla(S.user); await setMeta('sigla', S.sigla); }
  }
  semSeqCache[S.sigla] = (await getMeta('sem_seq_' + S.sigla)) || 0;
  draft = newDraft(false, false);

  $$('#nav button').forEach(b => (b.onclick = () => showTab(b.dataset.tab)));
  $('#salaBanner').onclick = () => { showTab('salas'); escolhendoSala = true; renderSalas(); };

  // registrar
  scanReg = new Scanner({ video: $('#video'), offEl: $('#scanOff'), torchBtn: $('#btnTorch'), torchHint: $('#torchHint'), zoomRow: $('#zoomRow'), zoomRange: $('#zoomRange'), onResult: onScanRegistrar, formats: LINEAR, dedupMs: 2500, getEngine: () => 'auto' });
  $('#btnScan').onclick = () => toggleScanner(scanReg, $('#btnScan'));
  $('#inNumero').oninput = e => { const tinhaCatalogo = !!draft.catalogoAuto; setNumero(cleanCode(e.target.value), 'manual'); if (draft.planilha || draft.catalogoAuto || tinhaCatalogo) refletirPlanilhaNaTela(); $('#selSerie').value = draft.serie; $('#serieHint').textContent = draft.serieManual ? '(escolhida por você)' : '(sugerida pelo número)'; validateFields(); };
  $('#selSerie').onchange = e => { draft.serie = e.target.value; draft.serieManual = true; syncDraftUI(); };
  $$('input[name=modo]').forEach(r => (r.onchange = () => { draft.modo = r.value; syncDraftUI(); }));
  $('#inObs').oninput = e => (draft.obs = e.target.value);
  $('#inMarca').oninput = e => { draft.marca = e.target.value; draft.marcaManual = true; };
  $('#selFornec').onchange = e => (draft.fornecedor = e.target.value);
  $('#inTipoOutro').oninput = e => (draft.tipoOutro = e.target.value);
  tipoCombo = makeCombo($('#cmbTipo'), { getItens: itensTipo, getLabel: () => (draft.tipo === OUTRO ? OUTRO + ' (texto livre)' : draft.tipo || '— escolha o tipo —'), onPick: pickTipo, vazio: 'Nenhum tipo encontrado' });
  descCombo = makeCombo($('#cmbDesc'), { getItens: itensDescricao, getLabel: () => (draft.descLivre ? 'Outra descrição (digitar)' : draft.descricao || '— sem descrição —'), onPick: pickDescricao, vazio: 'Nenhuma descrição encontrada' });
  $('#inDescLivre').oninput = e => (draft.descricao = e.target.value);
  $('#chips').onclick = e => { const b = e.target.closest('[data-tipo]'); if (b) pickTipo(b.dataset.tipo); };
  $('#btnSalvar').onclick = () => salvarBem();
  $('#scanMsg').onclick = e => {
    const d = e.target.closest('[data-desfazer-auto]'); if (d) { d.disabled = true; desfazerAuto(d.dataset.desfazerAuto); return; }
    if (e.target.closest('[data-registrar-repetido]')) registrarRepetido();
    const mv = e.target.closest('[data-mover-aqui]');
    if (mv) {
      // o bem lido pode ser de OUTRO aparelho que ainda só está no índice (S.remotos): esse vai direto ao servidor
      const b = S.bens.find(x => x.id === mv.dataset.moverAqui) || S.remotos.find(x => x.id === mv.dataset.moverAqui), dest = S.salaId;
      if (!b || !dest) toast('Não encontrei o bem ou a sala. Atualize e tente de novo.', 'err');
      else { mv.disabled = true; moverBem(b, dest).then(ok => { if (ok) $('#scanMsg').innerHTML = `<div class="banner info">✔ ${esc(bemNum(b))} agora está nesta sala. Pode ler o próximo.</div>`; else mv.disabled = false; }); }
    }
  };
  $('#btnLimpar').onclick = () => { draft = newDraft(false, false); $('#scanMsg').innerHTML = ''; syncDraftUI(); };
  $('#btnDesfazer').onclick = desfazerUltimo;
  // administração
  $('#admOrigem').onchange = () => { admMarcados.clear(); renderAdmLista(); };
  $('#admBusca').oninput = renderAdmLista;
  $('#admListaBens').onchange = e => {
    const i = e.target.closest('[data-adm-bem]'); if (!i) return;
    if (i.checked) admMarcados.add(i.dataset.admBem); else admMarcados.delete(i.dataset.admBem);
    $('#admMover').textContent = `Mover marcados (${admMarcados.size})`;
  };
  $('#admMarcarTodos').onclick = () => { admBensFiltrados().slice(0, 200).forEach(b => admMarcados.add(b.id)); renderAdmLista(); };
  $('#admLimparMarcas').onclick = () => { admMarcados.clear(); renderAdmLista(); };
  $('#admMover').onclick = admMover; $('#admMesclar').onclick = admMesclar;
  $('#admAtualizarMov').onclick = carregarMovimentos;
  $('#admAtualizarUsuarios').onclick = carregarUsuarios;
  $('#admUsuarios').onclick = e => { const b = e.target.closest('[data-adm-user]'); if (b) admUsuario(b.dataset.admUser, b.dataset.admAcao); };
  $('#admCsvExcel').onclick = () => exportarServidor('excel'); $('#admCsvDados').onclick = () => exportarServidor('dados');
  $('#admMovimentos').onclick = e => { const b = e.target.closest('[data-adm-desfazer]'); if (b) admDesfazer(b.dataset.admDesfazer); };

  // bens
  $('#qBens').oninput = renderBens; $('#listBens').onclick = onBensClick;
  $('#filtroBar').onclick = e => {
    if (e.target.closest('#limparFiltro')) { e.preventDefault(); S.filtroSala = null; S.filtroCoord = null; renderBens(); }
    else if (e.target.closest('#btnUsarFiltro')) { const id = S.filtroSala; S.filtroSala = null; usarSala(id); }
  };

  // salas
  $('#qSalas').oninput = renderSalas;
  $('#btnNovaSala').onclick = () => abrirSalaPanel(null);
  $('#listSalas').onclick = e => {
    const ed = e.target.closest('[data-edit]');
    if (ed) {
      const s = salaDe(ed.dataset.edit);
      if (s && salaBloqueada(s)) { toast('Sala já sincronizada: entre na conta para editar.', 'err', 3500); return; }
      abrirSalaPanel(s); return;
    }
    const ns = e.target.closest('[data-novasala]'); if (ns) { abrirSalaDaCoordenacao(ns.dataset.novasala); return; }
    const cc = e.target.closest('[data-coord]'); if (cc) { tocarCoordenacao(cc.dataset.coord); return; }
    const c = e.target.closest('[data-ver]'); if (c) tocarSala(c.dataset.ver);
  };
  $('#listSalas').onkeydown = e => {
    if (e.key !== 'Enter' || !e.target.dataset) return;
    if (e.target.dataset.coord) tocarCoordenacao(e.target.dataset.coord); else if (e.target.dataset.ver) tocarSala(e.target.dataset.ver);
  };
  $('#salaPanel').addEventListener('click', e => { const b = e.target.closest('[data-usar]'); if (b) usarSala(b.dataset.usar); });
  ['sNome', 'sCoord', 'sAndar'].forEach(i => ($('#' + i).oninput = renderSalaSug));
  $('#sCoord').oninput = () => { renderSalaSug(); preencherPelaUnidade(); };
  $('#sLocal').onchange = onLocalChange;
  $('#btnSalvarSala').onclick = salvarSala; $('#btnCancelarSala').onclick = fecharSalaPanel;
  $('#rCpf').onfocus = () => { $('#rCpf').value = cpfFmt(cpfAtual); };
  $('#rCpf').oninput = e => { cpfAtual = cpfDigits(e.target.value).slice(0, 11); $('#rCpfAlt').textContent = cpfAviso(cpfAtual); };
  $('#rCpf').onblur = () => { $('#rCpf').value = cpfAtual.length === 11 ? cpfMask(cpfAtual) : cpfAtual; };

  // diagnóstico
  scanDiag = new Scanner({ video: $('#videoD'), offEl: $('#scanOffD'), torchBtn: $('#btnTorchD'), torchHint: $('#torchHintD'), zoomRow: $('#zoomRowD'), zoomRange: $('#zoomRangeD'), onResult: onScanDiag, formats: null, dedupMs: 0, getEngine: () => $('#selEngine').value });
  $('#btnScanD').onclick = async () => { await toggleScanner(scanDiag, $('#btnScanD')); if (scanDiag.engineInfo) $('#diagInfo').textContent = `Motor: ${scanDiag.engineInfo.name} · formatos habilitados: ${scanDiag.engineInfo.formats.join(', ')}`; };
  $('#selEngine').onchange = () => { if (scanDiag.running) { scanDiag.stop(); $('#btnScanD').textContent = '📷 Ligar câmera'; toast('Ligue a câmera de novo para usar o novo motor.'); } };
  $('#btnClearDiag').onclick = () => { diagRows.clear(); renderDiag(); };
  $('#btnCopyDiag').onclick = async () => { try { await navigator.clipboard.writeText(diagText()); toast('Log copiado.', 'ok'); } catch { await modal({ title: 'Copie o texto', msg: diagText(), cancel: false }); } };
  $('#diagInfo').textContent = `Motor nativo disponível: ${window.BarcodeDetector ? 'sim' : 'não'} · WASM incluso: ${window.BarcodeDetectionAPI ? 'sim' : 'não'}`;
  renderDiag();

  // mais
  $('#temaBtns').onclick = e => { const b = e.target.closest('button'); if (b) aplicarTema(b.dataset.t, true); };
  $('#btnCsvExcel').onclick = () => exportar('excel'); $('#btnCsvDados').onclick = () => exportar('dados'); $('#btnJson').onclick = () => exportar('json');
  $('#btnCsvPlanilha').onclick = () => exportarPlanilha();
  $('#btnTrocarUser').onclick = async () => {
    const n = await askText('Trocar usuário', 'Novo nome:', { value: S.user }); if (!n) return;
    const sg = await askSigla(n, n === S.user ? S.sigla : '', true); if (!sg) return;
    if (!(await gravarOuAvisar([['meta', { k: 'usuario', v: n }], ['meta', { k: 'sigla', v: sg }]]))) return;
    S.user = n; S.sigla = sg;
    semSeqCache[sg] = (await getMeta('sem_seq_' + sg)) || 0; renderStatus(); syncDraftUI();
  };
  $('#btnPersist').onclick = async () => {
    if (navigator.storage && navigator.storage.persist) { const ok = await navigator.storage.persist(); toast(ok ? 'Armazenamento protegido.' : 'O navegador não concedeu. Instale o app na tela inicial e use bastante.', ok ? 'ok' : 'err', 4000); } else toast('Não suportado neste navegador.', 'err');
    renderStorage();
  };
  $('#btnAddLocal').onclick = async () => {
    if (listasSoAdmin()) return;
    const n = $('#novoLocal').value; if (!limpaEspacos(n)) return;
    const antes = S.localidades.length; const l = await criarLocalidade(n);
    if (!l) { renderLocalidadesMais(); return; }                  // a gravação falhou (o aviso já foi mostrado)
    toast(l && S.localidades.length === antes ? 'Essa localidade já existe.' : 'Localidade adicionada.', l && S.localidades.length === antes ? 'err' : 'ok');
    $('#novoLocal').value = ''; renderLocalidadesMais();
  };
  $('#listLocais').onclick = async e => {
    const a = e.target.closest('[data-lg]'); if (!a) return; e.preventDefault(); if (listasSoAdmin()) return;
    const l = S.localidades.find(x => x.id === a.dataset.lg); l.ativo = !l.ativo;
    await gravarOuAvisar([['localidades', l], audEntry(l.ativo ? 'localidade_reativada' : 'localidade_desativada', { nome: l.nome })]); await reload(); renderLocalidadesMais();
  };
  $('#dTipo').onchange = renderDescricoesMais; $('#dBusca').oninput = renderDescricoesMais;
  $('#listDesc').onclick = onDescricoesClick; $('#btnAddDesc').onclick = adicionarDescricao;
  $('#btnAddTipo').onclick = async () => {
    if (listasSoAdmin()) return;
    const n = $('#novoTipo').value.trim().toUpperCase(); if (!n) return;
    if (S.tipos.some(t => normSimples(t.nome) === normSimples(n))) { toast('Esse tipo já existe.', 'err'); return; }
    if (!(await gravarOuAvisar([['tipos', { id: uuid(), nome: n, ativo: true, usos: 0 }], audEntry('tipo_criado', { nome: n })]))) return;
    $('#novoTipo').value = ''; await reload(); renderTiposMais(); renderTipos();
  };
  $('#listTipos').onclick = async e => {
    const a = e.target.closest('[data-tg]'); if (!a) return; e.preventDefault(); if (listasSoAdmin()) return;
    const t = S.tipos.find(x => x.id === a.dataset.tg); t.ativo = !t.ativo;
    await gravarOuAvisar([['tipos', t], audEntry(t.ativo ? 'tipo_reativado' : 'tipo_desativado', { nome: t.nome })]); await reload(); renderTiposMais(); renderTipos();
  };
  $('#btnApagar').onclick = apagarTudo;
  $('#verInfo').textContent = `Versão ${VERSION}`;

  syncDraftUI(); renderSalaBanner(); renderLast(); renderStatus(); renderStorage();
  // pede armazenamento persistente (o navegador decide se concede)
  if (navigator.storage && navigator.storage.persist) navigator.storage.persist().then(renderStorage).catch(() => {});
  document.addEventListener('visibilitychange', () => { if (document.hidden) { scanReg.stop(); scanDiag.stop(); $('#btnScan').textContent = $('#btnScanD').textContent = '📷 Ligar câmera'; } });
  iniciarSW();
  // login e sincronização (só se houver config.js). Uma falha aqui NÃO pode derrubar o registro local (auditoria M-4).
  try { await Engine.iniciar(); }
  catch (e) { console.error('Engine.iniciar', e); toast('A sincronização não iniciou: ' + (e && e.message) + '. Você pode registrar normalmente; os dados ficam salvos no aparelho.', 'err', 9000); }
}
init().catch(e => { document.body.innerHTML = `<div class="banner err" style="margin:16px"><b>Erro ao iniciar:</b> ${esc(e && e.message)}<br>Se estiver em aba anônima, o navegador pode bloquear o armazenamento local.</div>`; });
