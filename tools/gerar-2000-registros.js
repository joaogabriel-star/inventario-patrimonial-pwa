/* TESTE DE VOLUME (2.000 registros offline). Cole no Console do navegador (F12) do app JÁ LOGADO,
   num computador (não no celular). Ele cria 2.000 bens de teste no IndexedDB, como se tivessem sido
   registrados offline, e a fila de sincronização os envia quando a rede voltar.

   Roteiro:
     1. Entre no app, escolha uma sala (aba Salas -> “Usar esta sala”).
     2. DevTools -> aba Network -> marque “Offline”.
     3. Cole este script no Console e dê Enter (leva alguns segundos).
     4. Confira na faixa do topo: ~2000 pendentes (⏳).
     5. Desmarque “Offline”. Os pendentes devem cair de 50 em 50 até zerar. Rode
        `select count(*) from public.bens;` no SQL Editor para conferir.
   Depois apague esses dados de teste do servidor (só em projeto de teste) e use "Exportar JSON e limpar dados locais". */
(async () => {
  if (!S.salaId) { alert('Escolha uma sala antes.'); return; }
  const N = 2000, t0 = Date.now(), entradas = [];
  for (let i = 0; i < N; i++) {
    const agora = new Date(t0 + i).toISOString();
    const numero = String(1000000 + i);                                  // 7 dígitos: série “longo”
    entradas.push(['bens', {
      id: uuid(), etiquetas: [{ id: uuid(), numero, serie: 'longo', origem: 'manual', simbologia: '' }],
      codigo_provisorio: null, etiquetado_em_campo: false, tipo_bem: 'MESA', tipo_bem_outro: '', marca: '', fornecedor: '',
      descricao: '', item_material: '', descricao_origem: '', sala_id: S.salaId, observacao: 'TESTE DE VOLUME', situacao: 'ativo',
      criado_por: S.user, sigla: S.sigla, criado_em: agora, atualizado_em: agora, dispositivo: S.device, eventos: []
    }]);
  }
  for (let i = 0; i < entradas.length; i += 500) await writeMany(entradas.slice(i, i + 500));
  await reload(); renderStatus();
  console.log(N + ' bens de teste gravados localmente.');
})();
