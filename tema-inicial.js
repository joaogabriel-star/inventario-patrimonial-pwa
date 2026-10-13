// Aplica o tema salvo antes de a página ser desenhada (evita o "flash" claro/escuro).
// Fica em arquivo próprio, e não inline no index.html, para a Content-Security-Policy poder proibir scripts inline (M-9).
try { document.documentElement.dataset.tema = localStorage.getItem('tema') || 'auto'; } catch (e) {}
