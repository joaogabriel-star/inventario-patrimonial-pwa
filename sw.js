// Service worker: abre o app sem internet.
// Atualização ATÔMICA (auditoria M-5): todos os arquivos do app ficam em UM cache, nomeado por VERSION + BUILD. Uma versão
// nova é instalada por inteiro (tudo ou nada) e fica esperando; o app avisa "Atualizar agora" e só então ela assume.
// Nunca se serve HTML novo com JS velho, e nenhum arquivo é atualizado "por conta própria" em segundo plano.
//   VERSION: troque a cada publicação (também aparece em Mais).
//   BUILD:   no Vercel, o buildCommand (vercel.json) troca 'dev' pelo SHA do commit. Assim, mesmo que alguém esqueça de
//            trocar VERSION, cada deploy vira uma versão nova. Localmente fica 'dev'.
const VERSION = 'v0.8.0';
const BUILD = 'dev';
const CACHE = 'inventario-' + VERSION + '-' + BUILD;
const ASSETS = [
  './', 'index.html', 'style.css', 'tema-inicial.js', 'app.js', 'remote-adapter.js', 'sync.js', 'manifest.webmanifest',
  'icons/icon-192.png', 'icons/icon-512.png', 'icons/apple-touch-icon.png',
  'vendor/barcode-detector.js', 'vendor/zxing_reader.wasm'
];

self.addEventListener('install', e => {
  e.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    try {
      await cache.addAll(ASSETS.map(a => new Request(a, { cache: 'reload' })));       // tudo ou nada; ignora o cache HTTP
    } catch (err) {
      await caches.delete(CACHE);                                                      // instalação incompleta: descarta e falha (a versão atual continua)
      throw err;
    }
    // config.js é gerado no build do Vercel e não existe no desenvolvimento local: tenta, sem falhar a instalação
    try { await cache.add(new Request('config.js', { cache: 'reload' })); } catch {}
    // não assume sozinha: a versão nova espera o aviso "Atualizar agora" (mensagem abaixo)
  })());
});

self.addEventListener('message', e => { if (e.data === 'pular-espera') self.skipWaiting(); });

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))   // apaga versões antigas (inclusive os nomes do formato antigo)
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET' || new URL(req.url).origin !== location.origin) return;
  e.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const cached = await cache.match(req, { ignoreSearch: true });
    if (cached) return cached;                         // cache primeiro, SEM atualizar arquivo por arquivo
    try {
      const res = await fetch(req);
      if (res.ok && res.type === 'basic') cache.put(req, res.clone());                // arquivos fora da lista (ex.: descricoes.json) entram no cache desta versão
      return res;
    } catch {
      if (req.mode === 'navigate') { const idx = await cache.match('index.html'); if (idx) return idx; }
      return Response.error();
    }
  })());
});
