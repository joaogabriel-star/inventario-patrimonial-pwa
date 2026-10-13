// Copie este arquivo para config.js e preencha. config.js NÃO vai para o Git (está no .gitignore).
// Só URL e chave PUBLISHABLE (sb_publishable_...). NUNCA coloque aqui a chave secreta (sb_secret_...):
// o app recusa a chave secreta e avisa.
// No Vercel, o config.js é gerado no build a partir das variáveis de ambiente (veja vercel.json e docs/CONFIGURACAO-SUPABASE.md).
window.APP_CONFIG = {
  SUPABASE_URL: 'COLE_AQUI_A_URL_DO_PROJETO',                  // ex.: https://abcdefghijkl.supabase.co
  SUPABASE_PUBLISHABLE_KEY: 'COLE_AQUI_A_CHAVE_PUBLISHABLE'    // ex.: sb_publishable_...
};
