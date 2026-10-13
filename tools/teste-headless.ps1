# Teste automatizado (headless) do app: migração v0.2 -> v0.3 e roteiro de funcionalidades.
# Uso (na raiz do projeto):  powershell -ExecutionPolicy Bypass -File tools\teste-headless.ps1
# Precisa de Python (py ou python) e Microsoft Edge ou Google Chrome. Não altera nenhum arquivo do projeto
# (cria _t.html, _td.html e _seed.html temporários e os apaga no fim; todos estão no .gitignore).
#
# Parâmetros:
#   -Diagnostico          só imprime dados do ambiente e testa a conexão com o navegador; não roda os testes
#   -Modo auto|cdp|dom    auto (padrão): tenta depuração remota (CDP) e, se falhar, cai no modo --dump-dom
#   -Navegador auto|edge|chrome   auto tenta o Edge e depois o Chrome
#   -Porta, -PortaDebug   0 (padrão) = escolhe uma porta livre
# Código de saída: 0 = tudo passou; 1 = alguma verificação falhou OU o teste não conseguiu rodar.
param(
  [int]$Porta = 0,
  [int]$PortaDebug = 0,
  [switch]$Diagnostico,
  [ValidateSet('auto', 'cdp', 'dom')][string]$Modo = 'auto',
  [ValidateSet('auto', 'edge', 'chrome')][string]$Navegador = 'auto'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
# sem proxy corporativo para conexões locais (PowerShell 5.1)
try { [Net.WebRequest]::DefaultWebProxy = $null } catch {}
# lê o próprio arquivo como UTF-8: o PowerShell 5.1 lê arquivo sem BOM como ANSI e estragaria os acentos do roteiro
$fonte = [IO.File]::ReadAllText($PSCommandPath, [Text.Encoding]::UTF8)
function Bloco($nome) {
  $m = [regex]::Match($fonte, '(?s)\$' + $nome + " = @'\r?\n(.*?)\r?\n'@")
  if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}

# ---------------------------------------------------------------- funções de apoio (mensagens novas sem acento de propósito)
function Escrever($t, $cor) { if ($cor) { Write-Host $t -ForegroundColor $cor } else { Write-Host $t } }

function Porta-Livre {
  $l = New-Object Net.Sockets.TcpListener -ArgumentList @([Net.IPAddress]::Loopback, 0)
  $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop()
  return $p
}

# mostra a cadeia completa de InnerException (a AggregateException crua nao diz nada)
function Texto-Excecao($e) {
  $t = @(); $n = 0
  while ($e -and $n -lt 8) { $t += ('    [' + $e.GetType().Name + '] ' + $e.Message); $e = $e.InnerException; $n++ }
  return ($t -join "`n")
}

# encerra SOMENTE o processo que este script iniciou (e os filhos dele)
function Encerrar($p) {
  if (-not $p) { return }
  $velho = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
  try { if (-not $p.HasExited) { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } } catch {}
  $ErrorActionPreference = $velho
}

function Remover-Perfil($dir) {
  for ($i = 0; $i -lt 6; $i++) {
    if (-not (Test-Path -LiteralPath $dir)) { return }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $dir)) { return }
    Start-Sleep -Milliseconds 500
  }
}

# handshake WebSocket "na mao": mostra o codigo HTTP real (101 = ok, 403 = origem/politica recusada)
function Handshake-Bruto($porta, $caminho) {
  $tcp = New-Object Net.Sockets.TcpClient
  try {
    $tcp.Connect('127.0.0.1', $porta); $tcp.ReceiveTimeout = 5000
    $s = $tcp.GetStream()
    $req = "GET $caminho HTTP/1.1`r`nHost: 127.0.0.1:$porta`r`nUpgrade: websocket`r`nConnection: Upgrade`r`nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==`r`nSec-WebSocket-Version: 13`r`n`r`n"
    $b = [Text.Encoding]::ASCII.GetBytes($req); $s.Write($b, 0, $b.Length)
    $buf = New-Object byte[] 2048; $n = $s.Read($buf, 0, $buf.Length)
    $linhas = [Text.Encoding]::UTF8.GetString($buf, 0, $n) -split "`r`n"
    return ($linhas[0] + '  |  ' + (($linhas | Select-Object -Skip 1 -First 3) -join ' | '))
  } catch { return ('falhou: ' + $_.Exception.Message) } finally { $tcp.Close() }
}

function Achar-Navegadores {
  $lista = @()
  $edge = @('C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe', 'C:\Program Files\Microsoft\Edge\Application\msedge.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
  $chrome = @('C:\Program Files\Google\Chrome\Application\chrome.exe', 'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe', (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($edge -and $Navegador -in 'auto', 'edge') { $lista += [pscustomobject]@{ Nome = 'Edge'; Caminho = $edge; Versao = (Get-Item $edge).VersionInfo.ProductVersion } }
  if ($chrome -and $Navegador -in 'auto', 'chrome') { $lista += [pscustomobject]@{ Nome = 'Chrome'; Caminho = $chrome; Versao = (Get-Item $chrome).VersionInfo.ProductVersion } }
  return $lista
}

# argumentos comuns do navegador (perfil temporario e sem extensoes: agentes do computador nao interferem)
function Args-Base($perfil) {
  return ('--headless=new --disable-gpu --disable-extensions --no-first-run --no-default-browser-check --disable-background-networking --disable-sync --no-proxy-server --user-data-dir="' + $perfil + '"')
}
function Novo-Perfil { return (Join-Path $env:TEMP ('inventario-teste-' +[guid]::NewGuid().ToString('N'))) }

# espera o navegador listar um alvo do tipo "page"; devolve o alvo
function Esperar-Alvo($proc, $dbg, [int]$seg) {
  $fim = (Get-Date).AddSeconds($seg); $ult = ''
  while ((Get-Date) -lt $fim) {
    if ($proc.HasExited) { throw ('O navegador fechou sozinho (codigo ' + $proc.ExitCode + '). Pode ser politica corporativa bloqueando depuracao remota.') }
    try {
      # no PowerShell 5.1 o JSON do /json chega como um array dentro de outro array: achata antes de filtrar.
      # ignora paginas de extensao e do proprio navegador (politicas corporativas instalam extensoes mesmo com --disable-extensions)
      $todos = @()
      foreach ($x in @(Invoke-RestMethod "http://127.0.0.1:$dbg/json" -TimeoutSec 3)) { foreach ($y in $x) { $todos += $y } }
      $a = $todos | Where-Object { $_.type -eq 'page' -and ([string]$_.url) -notmatch '^(chrome-extension|chrome|edge|devtools|chrome-untrusted)://' } | Select-Object -First 1
      if ($a) { return $a }
    } catch { $ult = $_.Exception.Message }
    Start-Sleep -Milliseconds 500
  }
  throw ('Nenhuma aba (page) apareceu em http://127.0.0.1:' + $dbg + '/json em ' + $seg + ' s. Ultimo erro: ' + $ult)
}

# página que grava dados no formato antigo (v0.2: banco versão 1, sala com níveis org., sem store de localidades)
$seed = @'
<!doctype html><meta charset="utf-8"><body><pre id="semeado">AGUARDANDO</pre><script>
// Escreve SEMEADO-OK no <pre> quando termina; em qualquer problema escreve SEMEADO-ERRO: <motivo> e define window.__erro.
window.__done = false; window.__erro = null;
function falha(m) { if (window.__done || window.__erro) return; window.__erro = m; document.getElementById('semeado').textContent = 'SEMEADO-ERRO: ' + m; }
window.onerror = function (m, s, l, c) { falha('excecao JS: ' + m + ' @' + l + ':' + c); };
window.addEventListener('unhandledrejection', function (e) { falha('promise rejeitada: ' + (e.reason && e.reason.message || e.reason)); });
setTimeout(function () { falha('tempo interno esgotado (__TEMPO__ ms): o IndexedDB nao concluiu (abertura bloqueada, upgrade parado ou transacao sem fim). origem=' + location.origin); }, __TEMPO__);
if (!window.indexedDB) falha('indexedDB indisponivel neste contexto (origem ' + location.origin + ')');
const r = window.indexedDB ? indexedDB.open('patrimonio-v1', 1) : null;
if (r) {
r.onblocked = () => falha('abertura do banco bloqueada por outra conexao aberta');
r.onerror = () => falha('erro ao abrir o banco: ' + (r.error && r.error.message));
r.onupgradeneeded = () => { const d = r.result; d.createObjectStore('meta', { keyPath: 'k' }); ['coordenacoes','salas','tipos','bens','auditoria'].forEach(n => d.createObjectStore(n, { keyPath: 'id' })); };
r.onsuccess = () => {
  const d = r.result, t = d.transaction(['meta','coordenacoes','salas','tipos','bens'], 'readwrite'), agora = new Date().toISOString();
  t.onerror = () => falha('erro na transacao: ' + (t.error && t.error.message));
  t.onabort = () => falha('transacao abortada: ' + (t.error && t.error.message));
  t.objectStore('meta').put({ k: 'usuario', v: 'Teste' }); t.objectStore('meta').put({ k: 'sigla', v: 'TS' }); t.objectStore('meta').put({ k: 'device_id', v: 'dev-antigo' });
  t.objectStore('coordenacoes').put({ id: 'c1', nome: 'COORD-DEMO', nome_norm: 'coord-demo' });
  t.objectStore('salas').put({ id: 's1', nome: '803', nome_norm: '803', coordenacao_id: 'c1', nivel_org_1: 'N1', nivel_org_2: 'N2', nivel_org_3: '', andar: '8', localidade: 'prédio central' });
  t.objectStore('tipos').put({ id: 't1', nome: 'MESA', ativo: true, usos: 1 });
  t.objectStore('bens').put({ id: 'b1', etiquetas: [{ numero: '01888', serie: 'curto', origem: 'camera' }], codigo_provisorio: null, etiquetado_em_campo: false, tipo_bem: 'MESA', tipo_bem_outro: '', sala_id: 's1', observacao: '', situacao: 'ativo', criado_por: 'Teste', criado_em: agora, atualizado_em: agora, eventos: [] });
  t.oncomplete = () => { d.close(); window.__done = true; document.getElementById('semeado').textContent = 'SEMEADO-OK'; };
};
}
</script>
'@
$roteiro = @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), c = {};
  const okLater = () => setTimeout(() => { if (!$('#modal').hidden) $('#mOk').click(); }, 400);
  await sleep(1500);
  c.faixa_modo_local = $('#statusModo').textContent === 'Modo local (sem servidor)' && !document.body.textContent.includes('PROTÓTIPO');
  c.versao_0_8_0 = VERSION === '0.8.0' && db.version === 4 && db.objectStoreNames.contains('outbox') && db.objectStoreNames.contains('indice');
  c.sem_config_modo_local = Engine.ligado === false && $('#statusSync').hidden && Remote.nome === 'nenhum';
  // aviso de duplicidade com bem de OUTRO aparelho (índice vindo do servidor)
  await writeMany([['indice', { id: 'e-remoto-1', bem_id: 'bem-remoto-1', numero: '999', numero_normalizado: '999', serie: 'outra', sala_id: 'sala-x', sala_nome: 'Sala X', tipo_bem: 'MESA', ativo: true, sigla: 'ZZ', registrado_em: nowISO() }]], { silencioso: true });
  S.indiceCarregado = false; await reload();
  { const d = findDup('999', 'outra', null); c.duplicidade_com_outro_aparelho = d.forte.length === 1 && descreveBem(d.forte[0]).includes('outro aparelho') && findDup('999', 'curto', null).leve.length === 1; }
  // --- migração v0.2 -> v0.3 (nada pode se perder) ---
  const s1 = S.salas.find(s => s.id === 's1');
  c.mig_sala_preservada = !!s1 && s1.nome === '803' && s1.andar === '8' && s1.localidade === 'prédio central';
  c.mig_legado_guardado = !!s1 && !!s1.legado && s1.legado.nivel_org_1 === 'N1' && s1.legado.nivel_org_2 === 'N2';
  c.mig_niveis_fora_da_sala = !!s1 && !('nivel_org_1' in s1) && !('nivel_org_2' in s1);
  c.mig_bem_preservado = S.bens.length === 1 && S.bens[0].etiquetas[0].numero === '01888';
  c.mig_tipos_coord_preservados = S.tipos.some(t => t.nome === 'MESA') && S.coords.some(x => x.nome === 'COORD-DEMO');
  c.mig_localidades = S.localidades.filter(l => l.nome_norm === 'predio central').length === 1 && S.localidades.some(l => l.nome_norm === 'anexo');
  c.mig_sem_modal_de_boas_vindas = $('#modal').hidden;
  // --- localidades: sem duplicata ---
  const n0 = S.localidades.length;
  await criarLocalidade('  anexo   ');
  c.local_sem_duplicata = S.localidades.length === n0;
  c.local_nova = !!(await criarLocalidade('Prédio Norte')) && S.localidades.length === n0 + 1;
  // --- CPF ---
  // CPF sintético de teste (nenhum CPF deste arquivo pertence a uma pessoa real; 52998224725 só passa no dígito verificador)
  c.cpf_mascara = cpfMask('11122233396') === '***.222.333-**';
  c.cpf_valido = cpfValido('52998224725') && cpfAviso('52998224725') === '';
  c.cpf_invalido_so_avisa = cpfAviso('11122233344') !== '' && cpfAviso('123') !== '';
  // --- cadastrar sala com responsável pelo formulário ---
  abrirSalaPanel(null);
  c.painel_sala_abre = !$('#salaPanel').hidden && !document.getElementById('sN1') && !document.getElementById('sN2') && !document.getElementById('sN3');
  $('#sNome').value = 'Sala 910'; $('#sCoord').value = 'COORD-DEMO'; $('#sUorg').value = 'U-1'; $('#sAndar').value = '9';
  renderLocalSelect(''); $('#sLocal').value = 'Prédio Central';
  $('#rNome').value = 'Maria Teste'; $('#rSiorg').value = '123'; $('#rUorg').value = 'U-2'; $('#rMat').value = '0042'; cpfAtual = '52998224725';
  await salvarSala(); await sleep(200);
  const s2 = S.salas.find(s => s.nome === 'Sala 910');
  c.sala_campos = !!s2 && s2.uorg === 'U-1' && s2.localidade === 'Prédio Central' && s2.responsavel.cpf === '52998224725' && s2.responsavel.uorg === 'U-2' && s2.responsavel.matricula === '0042';
  c.sala_selecionada = S.salaId === (s2 && s2.id);
  c.cpf_fora_da_auditoria = !JSON.stringify(S.aud).includes('52998224725');
  c.cpf_mascarado_no_card = (renderSalas(), $('#listSalas').textContent.includes('***.982.247-**') && !$('#listSalas').textContent.includes('52998224725'));
  // --- bem com marca e fornecedor ---
  draft = newDraft(false, false); setNumero('123', 'manual'); draft.tipo = 'MESA'; draft.marca = 'DELL'; draft.fornecedor = 'Órgão A';
  okLater(); await salvarBem(); await sleep(250);
  draft = newDraft(false, false); setNumero('124', 'manual'); draft.tipo = 'MESA'; draft.marca = ' dell '; draft.fornecedor = 'Órgão B';
  $('#chkFixarMF').checked = true; okLater(); await salvarBem(); await sleep(250);
  c.marca_unica = S.bens.filter(b => b.marca === 'DELL').length === 2;
  c.fornecedores = S.bens.some(b => b.fornecedor === 'Órgão A') && S.bens.some(b => b.fornecedor === 'Órgão B');
  c.manter_marca_fornecedor = normSimples(draft.marca) === 'dell' && draft.fornecedor === 'Órgão B';
  $('#chkFixarMF').checked = false;
  // --- CSV: sem dados pessoais por padrão ---
  const csv = buildCSV('excel', false), csvP = buildCSV('excel', true), cab = csv.split('\r\n')[0];
  c.csv_colunas_novas = cab.includes('marca;fornecedor') && cab.includes('uorg_sala') && !cab.includes('nivel_org_1') && cab.includes('legado_niveis_org');
  c.csv_sem_pessoais = !csv.includes('52998224725') && !cab.includes('responsavel_cpf') && !csv.includes('Maria Teste') && !csv.includes('0042');
  c.csv_com_pessoais = csvP.includes('responsavel_cpf') && csvP.includes('="52998224725"') && csvP.includes('Maria Teste') && csvP.includes('="0042"');
  c.csv_legado_visivel = csv.includes('N1 / N2');
  c.csv_zero_preservado = csv.includes('="01888"') || csv.includes('="0') ;
  // --- exportação com dados pessoais fica na auditoria ---
  $('#chkPessoais').checked = true; okLater(); await exportar('dados'); await sleep(300);
  c.auditoria_pessoais = S.aud.some(a => a.acao === 'exportacao' && a.detalhe && a.detalhe.dados_pessoais === true);
  // --- tela de salas -> bens filtrados ---
  abrirBensDaSala('s1'); await sleep(150);
  c.filtro_chip = !$('#filtroBar').hidden && $('#filtroBar').textContent.includes('803') && !$('#tab-bens').hidden;
  c.filtro_aplica = $$('#listBens .card').length === 1;
  $('#limparFiltro').click(); await sleep(100);
  c.filtro_limpa = S.filtroSala === null && $('#filtroBar').hidden && $$('#listBens .card').length === 3;
  abrirBensDaSala('s1'); await sleep(100); $('#btnUsarFiltro').click(); await sleep(250);
  c.usar_sala_do_filtro = S.salaId === 's1' && !$('#tab-registrar').hidden && S.filtroSala === null;
  // --- tema ---
  aplicarTema('dark', true);
  c.tema_escuro = document.documentElement.dataset.tema === 'dark' && localStorage.getItem('tema') === 'dark' && getComputedStyle(document.documentElement).getPropertyValue('--card').trim() === '#16232f';
  aplicarTema('light', true);
  c.tema_claro = getComputedStyle(document.documentElement).getPropertyValue('--card').trim() === '#ffffff';
  aplicarTema('auto', true);
  c.titulo = document.title === 'Inventário Patrimonial' && $('.brand').textContent === 'Inventário Patrimonial demonstração';
  // --- v0.4: busca sem acento/maiúscula ---
  const itensT = [{ value: 'a', label: 'AR CONDICIONADO' }, { value: 'b', label: 'CÂMERA' }, { value: 'c', label: 'SOFÁ' }];
  c.busca_sem_acento_e_maiuscula = filtrarItens(itensT, 'camera').length === 1 && filtrarItens(itensT, 'CÂMERA').length === 1 && filtrarItens(itensT, 'sofá')[0].value === 'c' && filtrarItens(itensT, 'ar cond').length === 1 && filtrarItens(itensT, '').length === 3;
  // --- v0.4: importação de descrições (arquivo de teste em memória; idempotente; nunca sobrescreve) ---
  // (o teste só mexe no banco temporário dele: limpa as descrições que o app possa ter importado de um descricoes.json real)
  await sleep(1500);
  { const tx = T(['descricoes'], true); tx.objectStore('descricoes').clear(); await txDone(tx); }
  for (const n of ['MONITOR', 'CADEIRA']) if (!S.tipos.some(t => t.nome === n)) await writeMany([['tipos', { id: uuid(), nome: n, ativo: true, usos: 0 }]]);
  await reload();
  const json = JSON.stringify({ gerado_em: 't1', itens: { MONITOR: [{ descricao: 'MONITOR LED 24 POL', item_material: '0012' }, { descricao: 'MONITOR LCD 19 POL', item_material: '' }], CADEIRA: [{ descricao: 'CADEIRA GIRATORIA', item_material: '0034' }], 'ITEM NOVO': [{ descricao: 'X', item_material: '' }] } });
  const url = URL.createObjectURL(new Blob([json], { type: 'application/json' }));
  const n1 = await importarDescricoes(url), n2 = await importarDescricoes(url, { force: true }), n3 = await importarDescricoes(url);
  c.desc_importa = n1 === 4 && S.descricoes.length === 4 && S.descricoes.every(d => d.origem === 'siads' && d.ativo);
  c.desc_importa_idempotente = n2 === 0 && n3 === 0 && S.descricoes.length === 4;
  c.desc_sem_numeros_patrimoniais = !JSON.stringify(S.descricoes).match(/patrimonio|valor|data/i);
  // --- v0.4: filtro da descrição pelo tipo, combobox sem abrir teclado ---
  draft = newDraft(false, false); draft.tipo = 'MONITOR'; syncDraftUI();
  c.desc_filtra_por_tipo = itensDescricao().length - 2 === 2;
  draft.tipo = 'Outro'; c.desc_outro_mostra_todas = itensDescricao().length - 2 === 4;
  draft.tipo = 'MONITOR'; syncDraftUI();
  $('#cmbDesc .combo-btn').click();
  c.combo_abre_sem_teclado = !$('#cmbDesc .combo-pop').hidden && document.activeElement !== $('#cmbDesc .combo-q') && $$('#cmbDesc li[data-v]').length === 4;
  $('#cmbDesc .combo-q').value = 'LCD'; $('#cmbDesc .combo-q').dispatchEvent(new Event('input'));
  c.combo_busca_filtra_e_mantem_fixos = $$('#cmbDesc li[data-v]:not(.destaque)').length === 1 && $$('#cmbDesc li.destaque').length === 2;
  $('#cmbDesc li[data-v]:not(.destaque)').click();
  c.desc_escolhida = draft.descricao === 'MONITOR LCD 19 POL' && $('#cmbDesc .combo-pop').hidden;
  pickDescricao(S.descricoes.find(d => d.texto === 'MONITOR LED 24 POL').id);
  c.desc_item_material = draft.itemMaterial === '0012' && $('#descMat').textContent.includes('0012');
  pickTipo('CADEIRA');
  c.trocar_tipo_limpa_descricao = draft.descricao === '' && draft.itemMaterial === '';
  // --- v0.4: salvar com descrição da lista, com texto livre e sem marca (marca é opcional) ---
  const n_antes = S.bens.length;
  draft = newDraft(false, false); setNumero('126', 'manual'); draft.tipo = 'MONITOR'; pickDescricao(S.descricoes.find(d => d.texto === 'MONITOR LED 24 POL').id);
  okLater(); await salvarBem(); await sleep(250);
  draft = newDraft(false, false); setNumero('125', 'manual'); draft.tipo = 'CADEIRA'; pickDescricao('__livre__'); $('#inDescLivre').value = 'Cadeira especial'; draft.descricao = 'Cadeira especial';
  okLater(); await salvarBem(); await sleep(250);
  const bl = S.bens.find(b => b.descricao_origem === 'lista'), bf = S.bens.find(b => b.descricao_origem === 'livre');
  c.etiqueta_com_id_para_sincronizar = !!bl && !!bl.etiquetas[0].id;
  c.salva_descricao_lista =!!bl && bl.descricao === 'MONITOR LED 24 POL' && bl.item_material === '0012';
  c.salva_descricao_livre = !!bf && bf.descricao === 'Cadeira especial' && bf.item_material === '';
  c.marca_opcional = S.bens.length === n_antes + 2 && bl.marca === '' && bf.marca === '';
  const csv4 = buildCSV('excel', false);
  c.csv_descricao = csv4.split('\r\n')[0].includes('tipo_bem;descricao;item_material;marca;fornecedor') && csv4.includes('"MONITOR LED 24 POL";="0012"');
  // --- v0.4: administração das descrições (editável) ---
  showTab('mais'); $('#dTipo').value = 'MONITOR'; renderDescricoesMais();
  c.admin_lista_por_tipo = $$('#listDesc .card').length === 2;
  $('#dNova').value = 'MONITOR NOVO'; $('#dMat').value = '9'; await adicionarDescricao();
  const nova = S.descricoes.find(d => d.texto === 'MONITOR NOVO');
  c.admin_adiciona = !!nova && nova.origem === 'app' && nova.item_material === '9' && S.descricoes.length === 5;
  document.querySelector('[data-dtog="' + nova.id + '"]').click(); await sleep(250);
  c.admin_desativa = S.descricoes.find(d => d.id === nova.id).ativo === false && !itensDescricao().some(i => i.value === nova.id);
  // --- v0.4: lanterna (sem suporte: botão escondido + dica; falha ao ligar também esconde) ---
  showTab('registrar');
  c.lanterna_dica_oculta_sem_camera = $('#torchHint').hidden && $('#btnTorch').hidden && $('#torchHint').textContent.includes('Central de Controle');
  scanReg.track = { applyConstraints: () => Promise.reject(new Error('sem suporte')) }; $('#btnTorch').hidden = false; $('#torchHint').hidden = true;
  await scanReg.setTorch(true);
  c.lanterna_falha_esconde_botao = $('#btnTorch').hidden && !$('#torchHint').hidden && S.torch === false;
  scanReg.stop();
  // --- Lote 1 da auditoria ---
  // A-3: CSV do Excel não interpreta texto de código de barras como fórmula
  draft = newDraft(false, false); setNumero('1"&1+1&"', 'camera'); draft.tipo = 'MESA'; okLater(); await salvarBem(); await sleep(250);
  draft = newDraft(false, false); setNumero('=1+1', 'manual'); draft.tipo = 'MESA'; okLater(); await salvarBem(); await sleep(250);
  const csvX = buildCSV('excel', false);
  c.csv_sem_formula_injetada = !csvX.includes('="1"&1+1') && csvX.includes('"1""&1+1&"""') && csvX.includes('"\'=1+1"');
  c.csv_digitos_continuam_texto = csvX.includes('="01888"');
  // A-1: bens e salas novos nascem com a marca de elegibilidade (falsa em modo local, sem vínculo com servidor)
  c.marca_elegibilidade_na_criacao = S.bens.filter(b => b.criado_por === S.user && b.id !== 'b1' && b.id !== 'old1').every(b => b.elegivel_sync === false);
  // M-3 / M-2: exportar informa se salvou; JSON com CPF pede confirmação e é auditado como dados pessoais
  setTimeout(() => $('#mCancel').click(), 400);
  c.exportar_cancelado_devolve_false = (await exportar('json')) === false;
  okLater(); const rj = await exportar('json'); await sleep(200);
  c.json_confirma_e_audita = rj === true && S.aud.some(a => a.acao === 'exportacao' && a.detalhe.tipo === 'json' && a.detalhe.dados_pessoais === true);
  // A-2 (lado do app): aparelho já vinculado a um servidor, mas o app abriu sem config.js -> bloqueia o registro
  c.local_sem_painel_de_acesso = $('#authPanel').hidden;
  await setMeta('sync_user_id', 'usuario-de-teste'); await Engine.iniciar();
  c.sem_config_bloqueia = !$('#authPanel').hidden && $('#authTitulo').textContent === 'Servidor não configurado' && $('#authFechar').hidden;
  $('#authPanel').hidden = true; await writeMany([['meta', { k: 'sync_user_id', v: null }]]);
  // A-6 / M-12: telas de aguardando aprovação e de senha obrigatória não podem ser fechadas
  Engine.abrirAuth('aprovacao');
  c.tela_aprovacao = $('#authTitulo').textContent === 'Aguardando aprovação' && !$('#authAprovacao').hidden && $('#authFechar').hidden;
  Engine.abrirAuth('senhaobrig');
  c.tela_senha_obrigatoria = !$('#authSenha').hidden && !$('#authSenhaAviso').hidden && $('#authFechar').hidden;
  Engine.abrirAuth('senha');
  c.tela_senha_voluntaria_fecha = $('#authSenhaAviso').hidden && !$('#authFechar').hidden;
  $('#authPanel').hidden = true;
  // A-5: o descricoes.json não traz sequências de 6+ dígitos nem trechos de série
  { const jd = await (await fetch('descricoes.json')).json(); let ruim = 0;
    for (const lista of Object.values(jd.itens)) for (const d of lista) if (/\d{6,}|S[ÉE]RIE|\bNS\b|S\/N/i.test(d.descricao)) ruim++;
    c.descricoes_json_limpo = ruim === 0 && Object.keys(jd.itens).length > 0; }
  // --- Lote 2 da auditoria ---
  // M-14: o número é normalizado como no servidor (norm_numero), dos dois lados
  c.norm_numero_igual_ao_servidor = normNumero(' a-12 . ') === 'A12' && normNumero('01888') === '01888' && normNumero('0-18.88') === '01888' && normNumero('---') === '';
  await writeMany([['indice', { id: 'e-remoto-2', bem_id: 'bem-remoto-2', numero: 'A-12', numero_normalizado: 'A12', serie: 'outra', sala_id: 'sala-x', sala_nome: 'Sala X', tipo_bem: 'MESA', ativo: true, sigla: 'ZZ', registrado_em: nowISO() }]], { silencioso: true });
  S.indiceCarregado = false; await reload();
  { S.bens.push({ id: 'tmp-m14', situacao: 'ativo', tipo_bem: 'MESA', sala_id: 's1', criado_por: 'X', criado_em: nowISO(), etiquetas: [{ numero: 'B-7', serie: 'outra' }] });
    const dRemoto = findDup('a 12', 'outra', null), dLocal = findDup('b7', 'outra', null), dVazio = findDup('---', 'outra', null), idx = dupIndex();
    c.duplicidade_normalizada = dRemoto.forte.length === 1 && dLocal.forte.length === 1 && dVazio.forte.length === 0 && dVazio.leve.length === 0 && idx.forte.has('outra|B7');
    S.bens.pop(); }
  // M-11: falha de gravação local fora de "salvar bem" avisa (em vez de passar em silêncio) e não marca nada como feito
  { const orig = writeMany; let titulo = '', texto = '';
    writeMany = async () => { throw new Error('cota cheia (simulada)'); };
    setTimeout(() => { titulo = $('#mTitle').textContent; texto = $('#mMsg').textContent; $('#mOk').click(); }, 300);
    const okG = await gravarOuAvisar([['meta', { k: 'x', v: 1 }]]);
    const bT = S.bens.find(b => b.situacao === 'ativo');
    setTimeout(() => $('#mOk').click(), 300);
    const okA = await anularBem(bT, 'teste de falha');
    writeMany = orig;
    c.falha_de_gravacao_avisa = okG === false && titulo === 'NÃO FOI SALVO' && texto.includes('cota cheia');
    c.anular_com_falha_nao_marca_anulado = okA === false && S.bens.find(b => b.id === bT.id).situacao === 'ativo'; }
  // M-5: todos os arquivos do service worker existem e nenhum está no .vercelignore (senão a versão nova nunca instala)
  { const sw = await (await fetch('sw.js')).text();
    const lista = [...(((sw.match(/const ASSETS = \[([\s\S]*?)\];/) || [])[1]) || '').matchAll(/'([^']+)'/g)].map(m => m[1]);
    const faltando = [];
    for (const a of lista) { try { const r = await fetch(a, { cache: 'no-store' }); if (!r.ok) faltando.push(a); } catch { faltando.push(a); } }
    let ign = []; try { ign = (await (await fetch('.vercelignore')).text()).split(/\r?\n/).map(s => s.trim()).filter(s => s && !s.startsWith('#')); } catch {}
    const ignorado = a => ign.some(p => p === a || (p.endsWith('/') && a.startsWith(p)) || (p.startsWith('*.') && a.endsWith(p.slice(1))));
    const instalacao = (sw.split("'install'")[1] || '').split("'message'")[0];
    c.sw_arquivos_existem_e_nao_ignorados = lista.length >= 10 && faltando.length === 0 && lista.filter(a => a !== './' && ignorado(a)).length === 0;
    c.sw_atualizacao_atomica = /const CACHE = 'inventario-' \+ VERSION \+ '-' \+ BUILD;/.test(sw) && instalacao.includes('addAll') && !instalacao.includes('skipWaiting') && sw.includes("'pular-espera'"); }
  // M-9: com CSP "script-src 'self'" o app não pode ter script inline nem atributo de evento; os cabeçalhos estão no vercel.json
  { const idxHtml = await (await fetch('index.html')).text(), vj = JSON.parse(await (await fetch('vercel.json')).text());
    const hs = ((vj.headers || [])[0] || {}).headers || [], h = k => (hs.find(x => x.key === k) || {}).value || '', csp = h('Content-Security-Policy');
    c.csp_html_sem_script_inline = !/<script(?![^>]*\bsrc=)[^>]*>/i.test(idxHtml) && !/\son[a-z]+\s*=/i.test(idxHtml);
    c.cabecalhos_de_seguranca = /default-src 'self'/.test(csp) && /script-src 'self'/.test(csp) && !/script-src[^;]*unsafe-inline/.test(csp) && /wasm-unsafe-eval/.test(csp) && /frame-ancestors 'none'/.test(csp) && /camera=\(self\)/.test(h('Permissions-Policy')) && h('X-Content-Type-Options') === 'nosniff' && h('Referrer-Policy') === 'no-referrer'; }
  // M-6: o pull vem em páginas, retoma de onde parou depois de uma queda, só avança o cursor no fim e cai para a função antiga
  { const orig = Remote.baixarPagina, chamadas = [], mk = i => ({ id: 'p' + i, bem_id: 'bp' + i, numero: 'PG' + i, numero_normalizado: 'PG' + i, serie: 'outra', sala_id: 'sala-x', sala_nome: 'Sala X', tipo_bem: 'MESA', ativo: true, sigla: 'ZZ', registrado_em: nowISO() });
    const todos = [0, 1, 2, 3, 4].map(mk); let falhar = true;
    Remote.baixarPagina = async (tabela, desde, apos) => {
      chamadas.push(tabela + ':' + (apos || ''));
      if (tabela === 'meta') return { agora: 'AGORA-1', sem_max: 0 };
      if (tabela !== 'indice') return { agora: 'AGORA-1', itens: [], mais: false, ultimo: null };
      const ini = apos ? todos.findIndex(x => x.id === apos) + 1 : 0, pag = todos.slice(ini, ini + 2);
      if (falhar && ini === 2) { falhar = false; const e = new Error('sem conexão'); e.rede = true; throw e; }       // cai na 2a página
      return { agora: 'AGORA-1', itens: pag, mais: ini + pag.length < todos.length, ultimo: pag.length ? pag[pag.length - 1].id : null };
    };
    await setMeta('pull_cursor', null); await setMeta('pull_progresso', null);
    let erro1 = null; try { await Engine.puxar(); } catch (e) { erro1 = e; }
    const cursor1 = await getMeta('pull_cursor'), prog = await getMeta('pull_progresso');
    await Engine.puxar();
    const ids = (await getAll('indice')).map(e => e.id);
    c.pull_falha_no_meio_nao_avanca_cursor = !!erro1 && !cursor1 && !!prog && prog.tabela === 'indice' && prog.apos === 'p1';
    c.pull_retoma_e_aplica_tudo = todos.every(x => ids.includes(x.id)) && (await getMeta('pull_cursor')) === 'AGORA-1' && (await getMeta('pull_progresso')) === null;
    c.pull_nao_repete_o_que_ja_baixou = chamadas.filter(x => x === 'tipos:').length === 1 && chamadas.filter(x => x === 'indice:p1').length === 2;
    Remote.baixarPagina = async () => { const e = new Error('nao existe'); e.http = 404; throw e; };
    let legado = true; try { await Engine.puxar(); } catch { legado = false; }
    c.pull_sem_migracao_003_usa_funcao_antiga = legado;
    Remote.baixarPagina = orig; }
  // v0.6.1: o pull traz os bens de OUTROS usuários (nunca reenviados), não os deixa alterar aqui e tolera servidor sem a migração 004
  { const orig = Remote.baixarPagina, sid = S.salas[0].id;
    const bem = est => ({ id: 'bem-outro-1', sala_id: sid, tipo_bem: 'MESA', descricao: 'MESA X', item_material: '1', marca: '', fornecedor: '', observacao: '', situacao: est, motivo_anulacao: est === 'anulado' ? 'teste' : null, anulado_em: est === 'anulado' ? nowISO() : null, registrado_em: nowISO(), recebido_em: nowISO(), usuario_nome: 'Colega', usuario_sigla: 'CO', etiquetas: [{ id: 'etq-outro-1', numero: '777', serie: 'outra', origem: 'manual', simbologia: '' }] });
    await Engine.aplicarPull({ bens: [bem('ativo')] });
    let bo = S.bens.find(b => b.id === 'bem-outro-1');
    c.pull_traz_bem_de_outro = !!bo && bo.servidor === true && bo.criado_por === 'Colega' && bo.situacao === 'ativo' && bo.etiquetas.length === 1 && bo.etiquetas[0].numero === '777' && bo.etiquetas[0].servidor === true;
    c.pull_bem_de_outro_nunca_e_reenviado = !!bo && !bo.elegivel_sync;
    showTab('bens'); renderBens();
    c.pull_bem_de_outro_aparece_na_lista = $('#listBens').textContent.includes('777') && $('#listBens').textContent.includes('Colega');
    await onBensClick({ target: { closest: () => ({ dataset: { anular: 'bem-outro-1' } }) } });
    c.bem_de_outro_nao_anula_aqui = S.bens.find(b => b.id === 'bem-outro-1').situacao === 'ativo';
    await Engine.aplicarPull({ bens: [bem('ativo')] });
    c.pull_bens_idempotente = S.bens.filter(b => b.id === 'bem-outro-1').length === 1 && S.bens.find(b => b.id === 'bem-outro-1').etiquetas.length === 1;
    await Engine.aplicarPull({ bens: [bem('anulado')] }); bo = S.bens.find(b => b.id === 'bem-outro-1');
    c.pull_aplica_anulacao_feita_por_outro = bo.situacao === 'anulado' && bo.motivo_anulacao === 'teste';
    Remote.baixarPagina = async tabela => {
      if (tabela === 'bens') { const e = new Error('tabela_invalida'); e.http = 400; throw e; }
      if (tabela === 'meta') return { agora: 'AGORA-004', sem_max: 0 };
      return { agora: 'AGORA-004', itens: [], mais: false, ultimo: null };
    };
    await setMeta('pull_cursor', null); await setMeta('pull_progresso', null);
    let seguiu = true; try { await Engine.puxar(); } catch { seguiu = false; }
    c.pull_sem_migracao_004_segue_sem_bens = seguiu && (await getMeta('pull_cursor')) === 'AGORA-004';
    Remote.baixarPagina = orig; showTab('registrar'); }
  // v0.6.2: lista de consulta da planilha. Número que consta preenche tipo e marca e avisa; NÃO é duplicidade nem vira bem
  { await writeMany([['meta', { k: 'planilha', v: [{ numero: '01234', tipo: 'CADEIRA', marca: 'PLAXMETAL', coordenacao: 'GAB', andar: '7º andar', localidade: 'Prédio Central' }, { numero: '01235', tipo: 'APARELHO DE TELEFONE', marca: 'AVAYA', coordenacao: 'ADM', andar: '7º andar', localidade: 'Prédio Central' }] }]], { silencioso: true });
    await carregarPlanilha();
    draft = newDraft(false, false); applyCode('01234', 'manual');
    c.planilha_preenche_tipo_e_marca = draft.tipo === 'CADEIRA' && draft.marca === 'PLAXMETAL' && !!draft.planilha;
    c.planilha_avisa_na_tela = $('#altNumero').textContent.includes('Consta na planilha') && $('#altNumero').textContent.includes('GAB') && $('#scanMsg').textContent.includes('consta na planilha');
    c.planilha_nao_e_duplicidade = findDup('01234', 'curto', null).forte.length === 0 && findDup('01234', 'curto', null).leve.length === 0;
    draft = newDraft(false, false); applyCode('01235', 'manual');
    c.planilha_tipo_sem_correspondencia_vira_outro = draft.tipo === OUTRO && draft.tipoOutro === 'APARELHO DE TELEFONE' && draft.marca === 'AVAYA';
    draft = newDraft(false, false); pickTipo('MONITOR'); $('#inMarca').value = 'DELL'; $('#inMarca').dispatchEvent(new Event('input')); applyCode('01234', 'manual');
    c.planilha_nao_sobrescreve_escolha_da_pessoa = draft.tipo === 'MONITOR' && draft.marca === 'DELL' && !!draft.planilha;
    draft = newDraft(false, false); applyCode('09999', 'manual');
    c.planilha_numero_fora_da_lista_nao_preenche = !draft.planilha && draft.tipo === '' && !$('#altNumero').textContent.includes('planilha');
    c.planilha_nao_cria_bem = !S.bens.some(b => etqs(b).some(e => e.numero === '01234'));
    // v0.7.4: leitura pela CÂMERA. Consta na planilha + sala escolhida + ainda não lido = salva sozinho (localizado), com Desfazer.
    // Já lido = não registra de novo. Digitação continua manual.
    { const salaAntes = S.salaId, nAntes = S.bens.length; S.salaId = S.salas.find(s => s.status !== 'mesclada').id;
      draft = newDraft(false, false); applyCode('01234', 'camera', 'code_128'); await sleep(600);
      const auto = S.bens.find(b => b.situacao === 'ativo' && etqs(b).some(e => e.numero === '01234'));
      c.camera_planilha_salva_sozinho = S.bens.length === nAntes + 1 && !!auto && auto.tipo_bem === 'CADEIRA' && auto.marca === 'PLAXMETAL' && auto.sala_id === S.salaId && auto.descricao === '' && draft.numero === '';
      c.camera_planilha_mostra_localizado_e_desfazer = $('#scanMsg').textContent.includes('LOCALIZADO') && !!$('#scanMsg [data-desfazer-auto]');
      // o mesmo item lido de novo logo depois: não grava, avisa com calma
      applyCode('01234', 'camera', 'code_128'); await sleep(300);
      c.camera_mesmo_item_de_novo_nao_grava = S.bens.length === nAntes + 1 && $('#scanMsg').textContent.includes('agora há pouco');
      // lido de novo depois de outro registro: NÃO registra; oferece "registrar mesmo assim", que só volta o número ao formulário
      lastSaved = null; draft = newDraft(false, false); pickTipo('MESA'); applyCode('01234', 'camera', 'code_128'); await sleep(300);
      c.camera_ja_lido_nao_registra_de_novo = S.bens.length === nAntes + 1 && $('#scanMsg').textContent.includes('JÁ FOI LIDO') && draft.numero === '' && draft.tipo === 'MESA';
      $('#scanMsg [data-registrar-repetido]').click();
      c.camera_ja_lido_registrar_mesmo_assim_volta_o_numero = draft.numero === '01234' && S.bens.length === nAntes + 1;
      // desfazer anula (não apaga) e libera o número
      draft = newDraft(false, false); $('#scanMsg').innerHTML = `<div><button data-desfazer-auto="${auto.id}" type="button">x</button></div>`;
      $('#scanMsg [data-desfazer-auto]').click(); await sleep(600);
      c.camera_desfazer_anula_o_automatico = S.bens.find(b => b.id === auto.id).situacao === 'anulado' && !numerosLidos().has(normNumero('01234'));
      // sem sala escolhida, ou número fora da planilha: não salva sozinho
      S.salaId = null; draft = newDraft(false, false); applyCode('01235', 'camera', 'code_128'); await sleep(300);
      c.camera_sem_sala_nao_salva_sozinho = S.bens.length === nAntes + 1 && draft.numero === '01235';
      S.salaId = salaAntes || S.salas[0].id; draft = newDraft(false, false); applyCode('09998', 'camera', 'code_128'); await sleep(300);
      c.camera_fora_da_planilha_nao_salva_sozinho = S.bens.length === nAntes + 1 && draft.numero === '09998' && $('#scanMsg').textContent.includes('NÃO consta na planilha');
      // tipo escolhido à mão neste item: não salva sozinho (segue o caminho normal); leitura com uma janela aberta é ignorada
      draft = newDraft(false, false); pickTipo('MESA'); applyCode('01235', 'camera', 'code_128'); await sleep(300);
      c.camera_tipo_escolhido_a_mao_nao_salva_sozinho = S.bens.length === nAntes + 1 && draft.numero === '01235' && draft.tipo === 'MESA';
      draft = newDraft(false, false); syncDraftUI(); $('#modal').hidden = false; onScanRegistrar({ rawValue: '01235', format: 'code_128' }); await sleep(300); $('#modal').hidden = true;
      c.camera_ignorada_com_janela_aberta = S.bens.length === nAntes + 1 && draft.numero === '';
      // CSV da planilha: localizado / não localizado
      draft = newDraft(false, false); applyCode('01235', 'camera', 'code_128'); await sleep(600);
      const csv = csvPlanilha().split('\r\n');
      c.csv_planilha_tem_situacao = csv[0].includes('situacao') && csv.some(l => l.includes('="01235"') && l.includes('"localizado"')) && csv.some(l => l.includes('="01234"') && l.includes('"nao localizado"'));
      S.salaId = salaAntes; draft = newDraft(false, false); $('#scanMsg').innerHTML = ''; lastSaved = null; }
    // v0.8.0: catálogo legado pela plaqueta antiga (preenche tipo, descrição e Item Material; NÃO salva sozinho), plaqueta repetida no
    // catálogo só avisa, plaqueta "A..." de outro órgão, botão Mover e lista de escolha no modal. Dados FICTÍCIOS.
    { await writeMany([['meta', { k: 'catalogo_legado', v: [
        { a: '09871', s: '51000001', i: 'MONITOR', d: 'MONITOR DE VIDEO', m: '123456', r: false },
        { a: '09872', s: '51000002', i: 'POLTRONA', d: 'POLTRONA', m: '222', r: true },
        { a: '09872', s: '51000003', i: 'MESA', d: 'MESA', m: '333', r: true }] }]], { silencioso: true });
      await carregarCatalogoLegado();
      const salaAntes = S.salaId, nAntes = S.bens.length; S.salaId = S.salas.find(s => s.status !== 'mesclada').id;
      draft = newDraft(false, false); setNumero('9871', 'manual'); syncDraftUI();
      c.catalogo_digitado_sem_zero_preenche = !!draft.catalogo && draft.catalogo.s === '51000001' && draft.descricao === 'MONITOR DE VIDEO' && draft.itemMaterial === '123456' && draft.tipo === 'MONITOR' && $('#altNumero').textContent.includes('Consta no catálogo legado');
      // digitação: '9871' (consta, sem os zeros) e depois '98719' (não consta): a tela mostra o preenchido e depois não fica resto
      draft = newDraft(false, false); syncDraftUI();
      const digita = v => { $('#inNumero').value = v; $('#inNumero').dispatchEvent(new Event('input')); };
      digita('9871'); const telaPreenchida = $('#descMat').textContent.includes('123456') && ($('#cmbDesc .combo-val').textContent === 'MONITOR DE VIDEO' || (!$('#inDescLivre').hidden && $('#inDescLivre').value === 'MONITOR DE VIDEO')) && $('#cmbTipo .combo-val').textContent === 'MONITOR';
      digita('98719');
      c.catalogo_digitacao_atualiza_tela_e_nao_deixa_resto = telaPreenchida && !draft.catalogo && draft.descricao === '' && draft.itemMaterial === '' && draft.tipo === '' && $('#descMat').textContent === '';
      draft = newDraft(false, false); applyCode('09871', 'camera', 'code_128'); await sleep(500);
      c.catalogo_pela_camera_nao_salva_sozinho = S.bens.length === nAntes && draft.numero === '09871' && !!draft.catalogo && $('#scanMsg').textContent.includes('consta no catálogo legado');
      okLater(); await salvarBem(); await sleep(300);
      const bs = S.bens.find(b => b.situacao === 'ativo' && etqs(b).some(e => e.numero === '09871'));
      c.catalogo_salvo_guarda_o_numero_do_catalogo = !!bs && bs.numero_siads === '51000001' && bs.descricao === 'MONITOR DE VIDEO';
      const csvS = buildCSV('excel', false).split('\r\n');
      c.csv_tem_numero_catalogo_e_plaqueta_outro_orgao = csvS[0].endsWith(';numero_catalogo_legado;plaqueta_outro_orgao') && csvS.some(l => l.includes('="09871"') && l.includes('="51000001"'));
      draft = newDraft(false, false); setNumero('09872', 'manual'); syncDraftUI();
      c.catalogo_plaqueta_repetida_so_avisa = !draft.catalogo && draft.catalogoRepetido &&draft.descricao === '' && $('#altNumero').textContent.includes('MAIS DE UM');
      draft = newDraft(false, false); applyCode('A00005933', 'camera', 'code_128'); await sleep(300);
      c.plaqueta_outro_orgao_identificada_sem_alerta = ehPlaquetaOutroOrgao('A00005933') && alertaNumero('A00005933', 'outra') === '' && !draft.catalogo && $('#scanMsg').textContent.includes('plaqueta de outro órgão') && S.bens.length === nAntes + 1;
      // modal com lista de escolha
      const outra = S.salas.find(s => s.status !== 'mesclada' && s.id !== bs.sala_id);
      setTimeout(() => { $('#mSelect').value = outra.id; $('#mOk').click(); }, 150);
      const esc1 = await modal({ title: 'x', opcoes: [{ v: outra.id, t: 'Outra' }] });
      setTimeout(() => $('#mCancel').click(), 150);
      const esc2 = await modal({ title: 'x', opcoes: [{ v: outra.id, t: 'Outra' }] });
      c.modal_com_lista_devolve_a_escolha = esc1 === outra.id && esc2 === null && $('#mSelect').hidden === false;
      // mover: bem que ainda não foi ao servidor muda aqui mesmo, sem chamar o servidor
      let chamouSrv = false; const origMv = Remote.moverBem; Remote.moverBem = async () => { chamouSrv = true; return { ok: true, movidos: 1 }; };
      const okMv = await moverBem(bs, outra.id);
      c.mover_bem_local_muda_a_sala_sem_servidor = okMv && !chamouSrv && S.bens.find(b => b.id === bs.id).sala_id === outra.id;
      // bem que veio do servidor, sem login: não move e não chama o servidor
      const bsv = { ...S.bens.find(b => b.id === bs.id), servidor: true };
      c.mover_bem_do_servidor_exige_login = (await moverBem(bsv, S.salaId)) === false && !chamouSrv;
      Remote.moverBem = origMv;
      S.filtroSala = null; S.filtroCoord = null; $('#qBens').value = ''; showTab('bens'); renderBens();
      c.bens_tem_botao_mover = $$('#listBens [data-mover]').length >= 1;
      showTab('registrar'); S.salaId = salaAntes; draft = newDraft(false, false); $('#scanMsg').innerHTML = ''; lastSaved = null;
      await writeMany([['meta', { k: 'catalogo_legado', v: [] }]], { silencioso: true }); await carregarCatalogoLegado(); }
    await writeMany([['meta', { k: 'planilha', v: [] }]], { silencioso: true }); await carregarPlanilha(); draft = newDraft(false, false); }
  // v0.6.2: unidades e responsáveis (consulta) preenchem a CRIAÇÃO de sala. Dados FICTÍCIOS; os reais nunca ficam no código
  { await writeMany([['meta', { k: 'unidades', v: [
      { sigla: 'ZZA', uorg: '900001', denominacao: 'Unidade Teste A', siorg: '111', responsavel: 'FULANO TESTE', matricula: '0099', cpf: '52998224725' },
      { sigla: 'ZZB', uorg: '900002', denominacao: 'Unidade Teste B', siorg: '222', responsavel: 'BELTRANO TESTE', matricula: '', cpf: '' }] }]], { silencioso: true });
    await carregarUnidades();
    await writeMany([['meta', { k: 'planilha', v: [{ numero: '01236', tipo: 'X', marca: '', coordenacao: 'ZZP', andar: '', localidade: '' }] }]], { silencioso: true }); await carregarPlanilha();
    abrirSalaPanel(null);
    c.coordenacoes_da_planilha_e_das_unidades_aparecem_sem_sala = $('#dlCoord').innerHTML.includes('value="ZZA"') && $('#dlCoord').innerHTML.includes('value="ZZP"') && $('#dlCoord').innerHTML.includes('value="COORD-DEMO"');
    $('#sCoord').value = 'zza'; $('#sCoord').dispatchEvent(new Event('input'));
    c.unidade_preenche_sala_nova = $('#sUorg').value === '900001' && $('#rNome').value === 'FULANO TESTE' && $('#rSiorg').value === '111' && $('#rUorg').value === '900001' && $('#rMat').value === '0099' && cpfAtual === '52998224725';
    $('#sCoord').value = 'ZZB'; $('#sCoord').dispatchEvent(new Event('input'));
    c.unidade_trocar_coordenacao_troca_responsavel_e_limpa_cpf = $('#rNome').value === 'BELTRANO TESTE' && $('#sUorg').value === '900002' && $('#rMat').value === '' && cpfAtual === '';
    $('#rNome').value = 'DIGITADO PELA PESSOA'; $('#sCoord').value = 'ZZA'; $('#sCoord').dispatchEvent(new Event('input'));
    c.unidade_nao_apaga_o_que_a_pessoa_digitou = $('#rNome').value === 'DIGITADO PELA PESSOA' && $('#sUorg').value === '900001';
    $('#sCoord').value = 'COORDENACAO QUE NAO EXISTE'; $('#sCoord').dispatchEvent(new Event('input'));
    c.unidade_desconhecida_nao_mexe = $('#sUorg').value === '900001';
    fecharSalaPanel(); abrirSalaPanel(S.salas[0]); $('#rNome').value = ''; $('#sCoord').value = 'ZZA'; $('#sCoord').dispatchEvent(new Event('input'));
    c.unidade_nao_preenche_edicao_de_sala = $('#rNome').value === '';
    fecharSalaPanel(); await writeMany([['meta', { k: 'unidades', v: [] }], ['meta', { k: 'planilha', v: [] }]], { silencioso: true }); await carregarUnidades(); await carregarPlanilha(); }
  // v0.6.2: coordenações da planilha aparecem na aba Salas e abrem a lista dos itens (sem criar bem); marca os já lidos
  { await writeMany([['meta', { k: 'planilha', v: [
      { numero: '01240', tipo: 'CPU', marca: 'POSITIVO', coordenacao: 'ZZQ', andar: '7º andar', localidade: 'Prédio Central' },
      { numero: '01241', tipo: 'MONITOR', marca: 'AOC', coordenacao: 'ZZQ', andar: '7º andar', localidade: 'Prédio Central' },
      { numero: '01242', tipo: 'WEBCAM', marca: '', coordenacao: 'ZZR', andar: '7º andar', localidade: 'Prédio Central' }] }]], { silencioso: true });
    await carregarPlanilha(); showTab('salas'); renderSalas();
    c.salas_lista_coordenacoes_da_planilha = $$('#listSalas [data-coord]').length === 2 && $('#listSalas').textContent.includes('ZZQ') && $('#listSalas').textContent.includes('2 itens da planilha');
    const nBensAntes = S.bens.length;
    $('#listSalas [data-coord]').click();
    c.coordenacao_abre_itens_da_planilha = !$('#tab-bens').hidden && S.filtroCoord === 'zzq' && $$('#listBens .card').length === 2 && $('#listBens').textContent.includes('01240') && $('#listBens').textContent.includes('01241') && !$('#filtroBar').hidden && $('#filtroBar').textContent.includes('ZZQ');
    c.planilha_por_coordenacao_nao_cria_bem = S.bens.length === nBensAntes && $('#countBens').textContent.includes('2 itens da planilha') && $('#countBens').textContent.includes('0 já lidos');
    await writeMany([['bens', { id: 'bem-lido-1', etiquetas: [{ id: 'e-lido-1', numero: '01240', serie: 'curto' }], tipo_bem: 'CPU', sala_id: S.salas[0].id, situacao: 'ativo', criado_por: 'Teste', criado_em: nowISO(), atualizado_em: nowISO(), eventos: [] }]], { silencioso: true });
    await reload(); renderBens();
    c.item_da_planilha_ja_lido_aparece_marcado = $('#countBens').textContent.includes('1 já lidos') && $('#listBens').textContent.includes('já lido') && $('#listBens').textContent.includes('ainda não lido');
    $('#limparFiltro').click();
    c.limpar_filtro_volta_aos_bens = S.filtroCoord === null && $('#filtroBar').hidden;
    showTab('salas'); renderSalas(); $('#listSalas [data-novasala]').click();
    fecharSalaPanel(); showTab('registrar'); $('#salaBanner').click(); $('#listSalas [data-coord]').click();
    c.em_modo_escolha_tocar_coordenacao_abre_cadastro_da_sala = !$('#salaPanel').hidden && $('#salaPanelTitulo').textContent === 'Cadastrar sala nova' && $('#sCoord').value === 'ZZQ' && S.filtroCoord === null;
    fecharSalaPanel(); showTab('salas'); renderSalas(); $('#listSalas [data-novasala]').click();
    c.coordenacao_tem_botao_para_cadastrar_sala =!$('#salaPanel').hidden && $('#salaPanelTitulo').textContent === 'Cadastrar sala nova' && $('#sCoord').value === 'ZZQ' && $('#sAndar').value === '7º andar' && $('#sLocal').value === 'Prédio Central';
    fecharSalaPanel();
    // coordenação que já tem sala cadastrada some do topo: aparece só a sala; o botão do cartão é "Editar"
    c.botao_do_cartao_da_coordenacao_e_editar = $('#listSalas [data-novasala]').textContent.trim() === 'Editar';
    await writeMany([['coordenacoes', { id: 'coord-zzq', nome: 'ZZQ', nome_norm: 'zzq', criado_em: nowISO(), criado_por: 'Teste' }],
      ['salas', { id: 'sala-zzq', nome: 'Sala ZZQ 1', nome_norm: 'sala zzq 1', coordenacao_id: 'coord-zzq', uorg: '', andar: '7º andar', localidade: 'Prédio Central', responsavel: {}, criado_em: nowISO(), criado_por: 'Teste' }]], { silencioso: true });
    await reload(); showTab('salas'); renderSalas();
    c.coordenacao_com_sala_cadastrada_some_do_topo = $$('#listSalas [data-coord]').length === 1 && !$('#listSalas').textContent.includes('ZZQ (planilha)') && $('#listSalas').textContent.includes('Sala ZZQ 1') && $('#listSalas').textContent.includes('ZZR (planilha)');
    // a sala dessa coordenação mostra, depois dos bens dela, os itens da planilha da coordenação (lidos marcados, os que faltam primeiro)
    c.sala_card_mostra_resumo_da_planilha_da_coordenacao = $('#listSalas').textContent.includes('Planilha ZZQ: 2 itens · 1 já lidos');
    abrirBensDaSala('sala-zzq');
    c.sala_da_coordenacao_mostra_itens_da_planilha = !$('#tab-bens').hidden && $('#listBens').textContent.includes('Planilha · ZZQ') && $('#listBens').textContent.includes('01240') && $('#listBens').textContent.includes('01241') && $('#listBens').textContent.includes('Nenhum bem registrado nesta sala ainda');
    c.sala_sem_planilha_nao_mostra_itens = (abrirBensDaSala(S.salas.find(s => s.nome === '803').id), !$('#listBens').textContent.includes('Planilha ·'));
    abrirBensDaSala(S.salas[0].id); S.filtroSala = null; S.filtroCoord = null;
    // v0.7.3: sigla e nome completo da coordenação são a MESMA coordenação (a planilha usa a sigla; a sala pode ter o nome completo)
    { const antes = { u: unidades, n: siglaPorNome };
      unidades = new Map([['zzr', { sigla: 'ZZR', denominacao: 'Zona Zeta Rho' }]]); siglaPorNome = new Map([['zona zeta rho', 'zzr']]);
      c.chave_da_coordenacao_igual_para_sigla_e_nome_completo = chaveCoord('ZZR') === 'zzr' && chaveCoord('Zona Zeta Rho') === 'zzr' && chaveCoord('Outra Coisa') === 'outra coisa' && chaveCoord('') === '';
      const cz = { id: 'coord-zzr-full', nome: 'Zona Zeta Rho', nome_norm: 'zona zeta rho' };
      const sz = { id: 'sala-zzr-full', nome: 'ZZR - Sala 1', nome_norm: 'zzr sala 1', coordenacao_id: cz.id, uorg: '', andar: '', localidade: '', responsavel: {}, status: 'ativa' };
      S.coords.push(cz); S.salas.push(sz); showTab('salas'); renderSalas();
      c.cartao_da_planilha_some_quando_a_sala_usa_o_nome_completo = !$('#listSalas').textContent.includes('ZZR (planilha)') && $('#listSalas').textContent.includes('ZZR - Sala 1');
      c.sala_com_nome_completo_mostra_a_planilha_da_sigla = $('#listSalas').textContent.includes('Planilha ZZR: 1 itens');
      S.salas.pop(); S.coords.pop(); unidades = antes.u; siglaPorNome = antes.n; renderSalas();
      c.sem_unidade_a_regra_antiga_continua = $('#listSalas').textContent.includes('ZZR (planilha)'); }
    await writeMany([['meta', { k: 'planilha', v: [] }]], { silencioso: true }); await carregarPlanilha(); showTab('registrar'); }
  // v0.6.2: "toque para trocar" (aba Registrar) leva a ESCOLHER a sala e volta para registrar; abrir a aba Salas direto continua mostrando os bens
  { S.salaId = null; S.filtroSala = null; S.filtroCoord = null;
    showTab('registrar'); $('#salaBanner').click();
    c.trocar_sala_abre_aba_salas_em_modo_escolha = !$('#tab-salas').hidden && escolhendoSala === true && $('#listSalas').textContent.includes('Toque na sala');
    const alvo = $('#listSalas [data-ver]').dataset.ver;
    $('#listSalas [data-ver]').click(); await sleep(400);
    c.trocar_sala_seleciona_e_volta_para_registrar = S.salaId === alvo && !$('#tab-registrar').hidden && escolhendoSala === false && S.filtroSala === null;
    showTab('salas'); $('#listSalas [data-ver]').click();
    c.salas_direto_continua_abrindo_os_bens = !$('#tab-bens').hidden && !!S.filtroSala && S.salaId === alvo;
    S.filtroSala = null; showTab('registrar'); }
  // v0.6.7: sala "parecida" — números de sala diferentes (701 x 702) NÃO são parecidos; igual e 1 letra de diferença sem número ainda são
  { await writeMany([['salas', { id: 'sala-701', nome: '701', nome_norm: '701', coordenacao_id: null, uorg: '', andar: '', localidade: '', responsavel: {}, criado_em: nowISO(), criado_por: 'Teste' }],
      ['salas', { id: 'sala-copa', nome: 'Copa', nome_norm: 'copa', coordenacao_id: null, uorg: '', andar: '', localidade: '', responsavel: {}, criado_em: nowISO(), criado_por: 'Teste' }]], { silencioso: true });
    await reload(); abrirSalaPanel(null);
    $('#sNome').value = '702';
    c.sala_702_nao_e_parecida_com_701 = similaresSala().length === 0;
    $('#sNome').value = '701';
    c.sala_701_igual_continua_sendo_detectada = similaresSala().some(s => s.id === 'sala-701');
    $('#sNome').value = 'Copas';
    c.nome_sem_numero_com_1_letra_de_diferenca_continua_parecido = similaresSala().some(s => s.id === 'sala-copa');
    $('#sNome').value = 'Sala 701'; c.sala_701_com_prefixo_continua_igual = similaresSala().some(s => s.id === 'sala-701');
    fecharSalaPanel(); }
  // v0.7.0 (fase 2b, etapa 1): administração (mover bens, mesclar salas, desfazer). Servidor SIMULADO: o roteiro troca Remote.* e confere
  // o que o app envia. A permissão de verdade é do servidor (testada em supabase/tests/rls.sql, T9).
  { const orig = { m: Remote.moverBens, s: Remote.mesclarSalas, d: Remote.desfazerMovimento, l: Remote.listarMovimentos };
    renderAdmin();
    c.admin_oculto_para_quem_nao_e_admin = $('#adminBox').hidden === true;
    c.erro_admin_sem_internet_e_sem_migracao = msgErroAdmin({ rede: true }).includes('internet') && msgErroAdmin({ http: 404 }).includes('007') && msgErroAdmin({ permissao: true }).includes('administrador');
    // lista de bens da sala de origem, com caixas de marcar
    $('#admOrigem').innerHTML = admOpcoes('Todas as salas', ''); $('#admDestino').innerHTML = admOpcoes('— destino —', ''); $('#admMescOrigem').innerHTML = admOpcoes('—', ''); $('#admMescDestino').innerHTML = admOpcoes('—', '');
    $('#admOrigem').value = 's1'; $('#admBusca').value = ''; admMarcados.clear(); renderAdmLista();
    c.admin_lista_os_bens_da_sala_de_origem = $$('#admListaBens input[data-adm-bem]').length >= 1 && $('#admListaBens').textContent.includes('01888');
    const cb = $('#admListaBens input[data-adm-bem]'); cb.checked = true; cb.dispatchEvent(new Event('change', { bubbles: true }));
    c.admin_marcar_atualiza_o_contador = admMarcados.size === 1 && $('#admMover').textContent.includes('(1)');
    $('#admOrigem').value = ''; $('#admBusca').value = '01888'; admMarcados.clear(); renderAdmLista();
    c.admin_busca_por_numero_em_todas_as_salas = $$('#admListaBens input[data-adm-bem]').length === 1;
    // mover: manda os ids marcados e o destino; depois de confirmar
    let chamada = null;
    Remote.moverBens = async (ids, dest) => { chamada = { ids, dest }; return { ok: true, movidos: ids.length, movimento_id: 'm-teste' }; };
    $('#admListaBens input[data-adm-bem]').click();
    $('#admDestino').value = 'sala-zzq'; okLater(); await admMover();
    c.admin_mover_envia_ids_e_destino = !!chamada && chamada.ids.length === 1 && chamada.dest === 'sala-zzq' && admMarcados.size === 0;
    chamada = null; { const bX = S.bens[0]; admMarcados.clear(); admMarcados.add(bX.id); $('#admDestino').value = bX.sala_id; }
    await admMover();
    c.admin_mover_para_a_mesma_sala_nao_chama_o_servidor = chamada === null;
    // servidor recusa: o app mostra e NÃO limpa as marcas
    Remote.moverBens = async () => ({ ok: false, erro: 'sala_mesclada' });
    admMarcados.clear(); admMarcados.add(S.bens[0].id); $('#admDestino').value = 'sala-701'; okLater(); await admMover();
    c.admin_servidor_recusa_mantem_as_marcas = admMarcados.size === 1;
    // mesclar: manda origem e destino
    let mc = null; Remote.mesclarSalas = async (o, d) => { mc = { o, d }; return { ok: true, movidos: 0, movimento_id: 'm-mesc' }; };
    $('#admMescOrigem').value = 'sala-copa'; $('#admMescDestino').value = 'sala-701'; okLater(); await admMesclar();
    c.admin_mesclar_envia_origem_e_destino = !!mc && mc.o === 'sala-copa' && mc.d === 'sala-701';
    mc = null; $('#admMescOrigem').value = 'sala-701'; $('#admMescDestino').value = 'sala-701'; await admMesclar();
    c.admin_mesclar_a_mesma_sala_nao_chama_o_servidor = mc === null;
    // desfazer: só o movimento ainda não desfeito tem botão; o clique manda o id
    admMovs = [{ id: 'm1', tipo: 'mover_bens', feito_em: nowISO(), feito_por: 'Admin', desfeito_em: null, destino: 'Sala ZZQ 1', origem: null, quantidade: 1 },
      { id: 'm2', tipo: 'mesclar_salas', feito_em: nowISO(), feito_por: 'Admin', desfeito_em: nowISO(), destino: '701', origem: 'Copa', quantidade: 2 }];
    renderMovimentos();
    c.admin_so_movimento_nao_desfeito_tem_botao = $$('#admMovimentos [data-adm-desfazer]').length === 1 && $('#admMovimentos').textContent.includes('desfeito em');
    let dz = null; Remote.desfazerMovimento = async id => { dz = id; return { ok: true, restaurados: 1, pulados: 0 }; }; Remote.listarMovimentos = async () => [];
    okLater(); $('#admMovimentos [data-adm-desfazer]').click(); await sleep(1200);
    c.admin_desfazer_envia_o_id_do_movimento = dz === 'm1';
    Object.assign(Remote, { moverBens: orig.m, mesclarSalas: orig.s, desfazerMovimento: orig.d, listarMovimentos: orig.l });
    admMarcados.clear(); admMovs = []; $('#admBusca').value = ''; }
  // sala MESCLADA pelo administrador: some das listas, não é "parecida", a sala escolhida passa para a que ficou; o bem movido segue para a nova sala
  { await writeMany([['salas', { id: 'sala-copa', nome: 'Copa', nome_norm: 'copa', coordenacao_id: null, uorg: '', andar: '', localidade: '', responsavel: {}, status: 'mesclada', mesclada_em_id: 'sala-701', criado_em: nowISO(), criado_por: 'Teste' }]], { silencioso: true });
    S.salaId = 'sala-copa'; await reload(); showTab('salas'); renderSalas();
    c.sala_mesclada_some_da_lista_de_salas = !$('#listSalas').textContent.includes('Copa') && $('#listSalas').textContent.includes('701');
    c.sala_escolhida_mesclada_passa_para_a_que_ficou = S.salaId === 'sala-701';
    abrirSalaPanel(null); $('#sNome').value = 'Copas'; c.sala_mesclada_nao_e_parecida = similaresSala().every(s => s.id !== 'sala-copa'); fecharSalaPanel();
    // o administrador moveu o bem (criado neste aparelho) para outra sala: o pull aplica
    await Engine.aplicarPull({ bens: [{ id: 'bem-lido-1', sala_id: 'sala-701', tipo_bem: 'CPU', situacao: 'ativo', registrado_em: nowISO(), recebido_em: nowISO(), usuario_nome: 'Teste', usuario_sigla: 'TS', etiquetas: [{ id: 'e-lido-1', numero: '01240', serie: 'curto' }] }] });
    c.pull_aplica_bem_movido_pelo_administrador = S.bens.find(b => b.id === 'bem-lido-1').sala_id === 'sala-701';
    S.salaId = null; showTab('registrar'); }
  // v0.7.2 (fase 2b, etapa 3): usuários na administração. Servidor SIMULADO; as regras de verdade (não se rebaixar, sempre sobrar um
  // admin, só admin executa) são do servidor e ficam em supabase/tests/rls.sql (T11).
  { const orig = { l: Remote.listarUsuarios, a: Remote.alterarUsuario };
    const us = [
      { id: 'u-pend', nome: 'Novo Perfil', sigla: 'NP', email: 'novo@exemplo.com', papel: 'coletor', ativo: false, aprovado_em: null, deve_trocar_senha: true },
      { id: 'u-eu', nome: 'Eu Admin', sigla: 'EA', email: 'eu@exemplo.com', papel: 'admin', ativo: true, aprovado_em: nowISO(), deve_trocar_senha: false },
      { id: 'u-col', nome: 'Coletor Um', sigla: 'C1', email: 'c1@exemplo.com', papel: 'coletor', ativo: true, aprovado_em: nowISO(), deve_trocar_senha: false },
      { id: 'u-adm2', nome: 'Outro Admin', sigla: 'A2', email: null, papel: 'admin', ativo: true, aprovado_em: nowISO(), deve_trocar_senha: false },
      { id: 'u-off', nome: 'Desligado', sigla: 'DS', email: 'd@exemplo.com', papel: 'coletor', ativo: false, aprovado_em: nowISO(), deve_trocar_senha: false }];
    admUsers = us; renderUsuarios('u-eu');
    const bts = id => $$(`#admUsuarios [data-adm-user="${id}"]`).map(b => b.dataset.admAcao);
    c.usuarios_lista_mostra_todos = $$('#admUsuarios .card').length === 5 && $('#admUsuarios').textContent.includes('Aguardando aprovação') && $('#admUsuarios').textContent.includes('Desativado') && $('#admUsuarios').textContent.includes('sem e-mail');
    c.usuarios_pendente_tem_aprovar = bts('u-pend').includes('ativar') && $('#admUsuarios').textContent.includes('Aprovar');
    c.usuarios_desativado_tem_reativar = bts('u-off').includes('ativar') && $('#admUsuarios').textContent.includes('Reativar') && !bts('u-off').includes('desativar');
    c.usuarios_sem_botao_perigoso_para_si_mesmo = bts('u-eu').length === 0 && $('#admUsuarios').textContent.includes('você');
    c.usuarios_coletor_vira_admin_e_admin_vira_coletor = bts('u-col').includes('tornar_admin') && bts('u-adm2').includes('tornar_coletor') && !bts('u-adm2').includes('tornar_admin');
    // clique: confirma e manda id + ação; o servidor recusando mostra o motivo
    let ch = null; Remote.listarUsuarios = async () => us; Remote.alterarUsuario = async (id, acao) => { ch = { id, acao }; return { ok: true }; };
    okLater(); $(`#admUsuarios [data-adm-user="u-pend"][data-adm-acao="ativar"]`).click(); await sleep(1200);
    c.usuarios_aprovar_envia_id_e_acao = !!ch && ch.id === 'u-pend' && ch.acao === 'ativar';
    ch = null; Remote.alterarUsuario = async () => ({ ok: false, erro: 'ultimo_admin' });
    okLater(); await admUsuario('u-adm2', 'tornar_coletor');
    c.usuarios_servidor_recusa_mostra_motivo = ($('#toast') ? $('#toast').textContent : document.body.textContent).includes('pelo menos um administrador');
    // ação desconhecida ou usuário que não está na lista: não chama o servidor
    ch = null; Remote.alterarUsuario = async (id, acao) => { ch = { id, acao }; return { ok: true }; };
    await admUsuario('u-inexistente', 'ativar'); await admUsuario('u-col', 'apagar');
    c.usuarios_acao_invalida_nao_chama_o_servidor = ch === null;
    c.usuarios_sem_servidor_ou_sem_migracao_avisa = msgErroUsuarios({ http: 404 }).includes('009') && msgErroUsuarios({ rede: true }).includes('internet');
    Object.assign(Remote, { listarUsuarios: orig.l, alterarUsuario: orig.a }); admUsers = []; $('#admUsuarios').innerHTML = ''; }
  // v0.7.1 (fase 2b, etapa 2): CSV baixado do SERVIDOR. Servidor SIMULADO; a permissão de verdade é do servidor (rls.sql, T10)
  { const it = (id, num, extra = {}) => ({ id, codigo_provisorio: null, etiquetado_em_campo: false, tipo_bem: 'MESA', tipo_bem_outro: '', descricao: '', item_material: '0012', marca: 'DELL', fornecedor: '',
      observacao: '', situacao: 'ativo', registrado_em: '2026-10-07T15:04:27.123+00:00', recebido_em: '2026-10-07T15:04:30+00:00', atualizado_em: '2026-10-07T15:04:30+00:00', registrado_por: 'Teste', sigla: 'TS',
      coordenacao: 'ZZQ', sala: '701', uorg_sala: '9', andar: '7º andar', localidade: 'Prédio Central', legado: { nivel_org_1: 'N1', nivel_org_2: 'N2' }, responsavel_siorg: '111', responsavel_uorg: '9',
      etiquetas: [{ numero: num, serie: 'curto', origem: 'camera' }], ...extra });
    const lista = [it('s-1', '01888'), it('s-2', '01888'), it('s-3', '04000', { observacao: '=1+1', situacao: 'ativo' }), it('s-4', '05000', { situacao: 'anulado' })];
    const local = buildCSV('excel', false).split('\r\n'), srv = csvDeServidor(lista, 'excel', false).split('\r\n');
    c.csv_servidor_mesmas_colunas_do_csv_local = srv[0] === local[0] && srv[0].slice(1).split(';').length === 30; const _semBom = srv[0].replace('﻿', '').split(';').length === 30;
    c.csv_servidor_uma_linha_por_bem = srv.filter(Boolean).length === 1 + lista.length;
    const txt = srv.join('\n');
    c.csv_servidor_zero_preservado_e_formula_neutralizada = txt.includes('="01888"') && txt.includes('"\'=1+1"') && txt.includes('="0012"');
    c.csv_servidor_marca_duplicidade = srv.filter(l => l.includes('repetido: 01888')).length === 2 && !srv.some(l => l.includes('"05000"') && l.includes('repetido'));
    c.csv_servidor_legado_e_sala = txt.includes('"N1 / N2"') && txt.includes('"701"') && txt.includes('"ZZQ"');
    c.csv_servidor_sem_pessoais_por_padrao = !txt.includes('responsavel_cpf') && !txt.includes('FULANO');
    const comP = csvDeServidor([it('s-9', '01999', { responsavel_nome: 'FULANO TESTE', responsavel_matricula: '0042', responsavel_cpf: '52998224725' })], 'excel', true);
    c.csv_servidor_com_pessoais_so_quando_pedido = comP.includes('responsavel_cpf') && comP.includes('="52998224725"') && comP.includes('FULANO TESTE') && comP.includes('="0042"');
    // fluxo de exportação: pagina até acabar, entrega o arquivo e avisa a diferença para o aparelho
    const orig = { e: Remote.exportarBensPagina, s: saveFile }; const chamadas = []; let salvo = null;
    Remote.exportarBensPagina = async (apos, lim, pess) => { chamadas.push({ apos, lim, pess }); return apos ? { itens: [it('s-3', '04000')], mais: false, ultimo: null } : { itens: [it('s-1', '01888'), it('s-2', '01777')], mais: true, ultimo: 's-2' }; };
    saveFile = async (nome, blob) => { salvo = { nome, texto: await blob.text() }; return true; };
    $('#admChkPessoais').checked = false; await exportarServidor('dados');
    c.exportar_servidor_pagina_ate_acabar = chamadas.length === 2 && chamadas[0].apos === null && chamadas[1].apos === 's-2' && chamadas[0].pess === false;
    c.exportar_servidor_entrega_o_arquivo = !!salvo && salvo.nome.startsWith('patrimonio_servidor_dados_') && salvo.nome.endsWith('.csv') && salvo.texto.split('\r\n').filter(Boolean).length === 4 && !salvo.texto.includes('="01888"');
    c.exportar_servidor_mostra_a_contagem = $('#admExportInfo').textContent.includes('3 bens no servidor');
    // pessoais: pede confirmação e manda pessoais=true ao servidor; desmarca depois
    chamadas.length = 0; salvo = null; $('#admChkPessoais').checked = true; okLater(); await exportarServidor('excel');
    c.exportar_servidor_pessoais_confirma_e_avisa_o_servidor = chamadas.length === 2 && chamadas.every(x => x.pess === true) && !!salvo && $('#admChkPessoais').checked === false;
    // sem internet / sem a migração: avisa e não entrega arquivo
    salvo = null; Remote.exportarBensPagina = async () => { const e = new Error('sem conexão'); e.rede = true; throw e; };
    await exportarServidor('excel'); c.exportar_servidor_sem_internet_nao_gera_arquivo = salvo === null && $('#admCsvExcel').disabled === false;
    Remote.exportarBensPagina = async () => { const e = new Error('nf'); e.http = 404; throw e; };
    await exportarServidor('excel'); c.exportar_servidor_sem_migracao_nao_gera_arquivo = salvo === null && $('#admExportInfo').textContent === '';
    Remote.exportarBensPagina = async () => ({ itens: [], mais: false, ultimo: null }); await exportarServidor('excel'); c.exportar_servidor_vazio_nao_gera_arquivo = salvo === null;
    Remote.exportarBensPagina = orig.e; saveFile = orig.s; $('#admExportInfo').textContent = ''; }
  // v0.7.2 (urgente, campo): editar uma sala que já existe NÃO pode duplicar nem ficar sem resposta. Servidor SIMULADO (Remote.atualizarSala);
  // o perfil (coletor/admin) e "já sincronizada" são simulados trocando os getters de Engine, e tudo é restaurado no fim do bloco.
  { const eng0 = Object.getOwnPropertyDescriptors(Engine), rem0 = { a: Remote.atualizarSala, l: Remote.lerResponsavelPessoal }, toast0 = toast, tmo0 = salaTimeoutMs;
    const logs = []; toast = (m, k, ms) => { logs.push(m); toast0(m, k, ms); };
    const perfCol = { id: 'u-rg', nome: 'Teste', sigla: 'TS', papel: 'coletor', ativo: true, deve_trocar_senha: false };
    let perfil = perfCol, okIds = [];
    const def = (k, f) => Object.defineProperty(Engine, k, { get: f, configurable: true });
    def('ligado', () => true); def('logado', () => true); def('perfil', () => perfil);
    def('admin', () => !!(perfil && perfil.ativo && !perfil.deve_trocar_senha && perfil.papel === 'admin'));
    Engine.itemOk = (t, id) => okIds.includes(t + ':' + id);
    const dormir = ms => new Promise(r => setTimeout(r, ms));
    const sSrv = (id, nome, coord) => ({ id, nome, coordenacao: coord, uorg: '', andar: '10', localidade: 'Prédio Central', responsavel_nome: 'Fulano', responsavel_siorg: '', responsavel_uorg: '', status: 'ativa', mesclada_em_id: null, origem: 'campo', recebido_em: nowISO() });
    // toca em "Editar" no cartão da sala (como a pessoa faz) e preenche o formulário
    const editarPeloCartao = async (id, nome, andar, resp) => {
      showTab('salas'); renderSalas(); const b = $('#listSalas').querySelector(`[data-edit="${id}"]`); if (b) b.click(); await dormir(60);
      const abriu = !!b && !$('#salaPanel').hidden && $('#salaPanelTitulo').textContent === 'Editar sala';
      $('#sNome').value = nome; $('#sAndar').value = andar; if (resp != null) $('#rNome').value = resp; return abriu; };
    const nomes = () => S.salas.map(s => s.nome);
    // (a) COLETOR, sala que veio do pull (servidor: true), com bens de outros usuários e um do próprio usuário
    await Engine.aplicarPull({ salas: [sSrv('rg-srv-1', 'RG 1001', 'RGCOORD')], bens: [
      { id: 'rg-bx1', sala_id: 'rg-srv-1', tipo_bem: 'MESA', situacao: 'ativo', registrado_em: nowISO(), recebido_em: nowISO(), usuario_nome: 'Outro', usuario_sigla: 'XX', etiquetas: [{ id: 'rg-ex1', numero: '07001', serie: 'curto', origem: 'manual' }] },
      { id: 'rg-bx2', sala_id: 'rg-srv-1', tipo_bem: 'MESA', situacao: 'ativo', registrado_em: nowISO(), recebido_em: nowISO(), usuario_nome: 'Outro 2', usuario_sigla: 'YY', etiquetas: [{ id: 'rg-ex2', numero: '07002', serie: 'curto', origem: 'manual' }] }] });
    await writeMany([['bens', { id: 'rg-bmeu', etiquetas: [{ id: 'rg-em', numero: '07003', serie: 'curto', origem: 'manual' }], tipo_bem: 'MESA', sala_id: 'rg-srv-1', situacao: 'ativo', criado_por: S.user, criado_em: nowISO(), atualizado_em: nowISO(), eventos: [], elegivel_sync: true }]], { silencioso: true }); await reload();
    let chamada = null, n0 = S.salas.length, nc0 = S.coords.length; Remote.atualizarSala = async p => { chamada = p; return { ok: true }; };
    logs.length = 0; const abriu1 = await editarPeloCartao('rg-srv-1', 'RG 1001-CORRIGIDA', '11', 'Beltrano');
    c.edit_sala_do_pull_coletor_abre_pelo_cartao = abriu1 && $('#rCpf').disabled === true && $('#rMat').disabled === true;
    await salvarSala(); await dormir(100);
    const sa = S.salas.find(s => s.id === 'rg-srv-1');
    c.edit_sala_do_pull_coletor_atualiza_a_mesma_sala = !!sa && sa.nome === 'RG 1001-CORRIGIDA' && sa.andar === '11' && sa.responsavel.nome === 'Beltrano' && S.salas.length === n0 && S.coords.length === nc0 && nomes().filter(n => n.startsWith('RG 1001')).length === 1;
    c.edit_sala_do_pull_coletor_manda_ao_servidor_sem_cpf = !!chamada && chamada.id === 'rg-srv-1' && chamada.nome === 'RG 1001-CORRIGIDA' && chamada.andar === '11' && !('responsavel_cpf' in chamada) && !('responsavel_matricula' in chamada);
    c.edit_sala_do_pull_coletor_avisa_e_fecha_o_painel = $('#salaPanel').hidden && logs.includes('Sala atualizada.') && !logs.includes('Sala criada e selecionada.') && $('#btnSalvarSala').disabled === false && $('#btnSalvarSala').textContent === 'Salvar sala';
    c.edit_sala_do_pull_nao_gera_sala_local_nova = (await getAll('salas')).filter(s => s.nome.startsWith('RG 1001') && !s.servidor).length === 0;
    c.edit_sala_do_pull_continua_unica_depois_de_novo_pull = await (async () => { await Engine.aplicarPull({ salas: [{ ...sSrv('rg-srv-1', 'RG 1001-CORRIGIDA', 'RGCOORD'), andar: '11', responsavel_nome: 'Beltrano' }] }); const x = S.salas.filter(s => s.id === 'rg-srv-1'); return x.length === 1 && x[0].nome === 'RG 1001-CORRIGIDA' && S.salas.length === n0 && S.coords.filter(k => k.nome === 'RGCOORD').length === 1; })();
    // (b) ADMIN: a MESMA sala; CPF/matrícula só seguem porque o administrador os leu antes
    perfil = { ...perfCol, papel: 'admin' }; Remote.lerResponsavelPessoal = async () => ({ cpf: '52998224725', matricula: '9' }); chamada = null; n0 = S.salas.length;
    const abriu2 = await editarPeloCartao('rg-srv-1', 'RG 1001-ADM', '12', null); await dormir(60);
    await salvarSala(); await dormir(100);
    c.edit_sala_do_pull_admin_atualiza_a_mesma_sala = abriu2 && S.salas.length === n0 && S.salas.find(s => s.id === 'rg-srv-1').nome === 'RG 1001-ADM' && !!chamada && chamada.id === 'rg-srv-1' && chamada.responsavel_cpf === '52998224725' && chamada.responsavel_matricula === '9';
    perfil = perfCol;
    // (c) sala PRÓPRIA: já sincronizada vai ao servidor (mesma sala); ainda não sincronizada fica só no aparelho (mesma sala, sem chamada)
    const cid = S.coords.find(k => k.nome === 'RGCOORD').id;
    await writeMany([['salas', { id: 'rg-prop-ok', nome: 'RG 2001', nome_norm: '2001', coordenacao_id: cid, uorg: '', andar: '2', localidade: '', responsavel: {}, criado_em: nowISO(), criado_por: S.user, elegivel_sync: true }],
      ['salas', { id: 'rg-prop-pend', nome: 'RG 2002', nome_norm: '2002', coordenacao_id: cid, uorg: '', andar: '2', localidade: '', responsavel: {}, criado_em: nowISO(), criado_por: S.user, elegivel_sync: true }]], { silencioso: true }); await reload();
    okIds = ['salas:rg-prop-ok']; chamada = null; n0 = S.salas.length;
    await editarPeloCartao('rg-prop-ok', 'RG 2001-X', '3', null); await salvarSala(); await dormir(100);
    c.edit_sala_propria_sincronizada_vai_ao_servidor_e_nao_duplica = !!chamada && chamada.id === 'rg-prop-ok' && S.salas.length === n0 && S.salas.find(s => s.id === 'rg-prop-ok').nome === 'RG 2001-X';
    chamada = null;
    await editarPeloCartao('rg-prop-pend', 'RG 2002-X', '3', null); await salvarSala(); await dormir(100);
    c.edit_sala_propria_nao_sincronizada_fica_local_e_nao_duplica = chamada === null && S.salas.length === n0 && S.salas.find(s => s.id === 'rg-prop-pend').nome === 'RG 2002-X';
    okIds = [];
    // (d) sala parecida: avisa; cancelar não grava nem chama o servidor; confirmar salva a MESMA sala
    await Engine.aplicarPull({ salas: [sSrv('rg-srv-2', 'RG 3002', 'RGCOORD'), sSrv('rg-srv-3', 'RG 3003', 'RGCOORD')] });
    chamada = null; n0 = S.salas.length; c.edit_sala_parecida_avisa = false;
    await editarPeloCartao('rg-srv-3', 'RG 3002', '10', null);
    setTimeout(() => { if (!$('#modal').hidden) { c.edit_sala_parecida_avisa = $('#mTitle').textContent === 'Sala parecida já existe' && $('#mOk').textContent === 'Salvar mesmo assim'; $('#mCancel').click(); } }, 300);
    await salvarSala(); await dormir(100);
    c.edit_sala_parecida_cancelar_nao_grava = chamada === null && !$('#salaPanel').hidden && S.salas.find(s => s.id === 'rg-srv-3').nome === 'RG 3003' && S.salas.length === n0 && $('#btnSalvarSala').disabled === false;
    setTimeout(() => { if (!$('#modal').hidden) $('#mOk').click(); }, 300);
    await salvarSala(); await dormir(100);
    c.edit_sala_parecida_confirmar_salva_a_mesma_sala = !!chamada && chamada.id === 'rg-srv-3' && S.salas.length === n0 && S.salas.find(s => s.id === 'rg-srv-3').nome === 'RG 3002' && $('#salaPanel').hidden;
    // (e) falhas do servidor: sempre uma mensagem, o painel continua aberto, o botão volta e NADA é gravado nem criado
    await Engine.aplicarPull({ salas: [sSrv('rg-srv-4', 'RG 4001', 'RGCOORD')] });
    const falha = async (remoto, esperaMsg) => {
      Remote.atualizarSala = remoto; logs.length = 0; n0 = S.salas.length;
      await editarPeloCartao('rg-srv-4', 'RG 4001-FALHA', '5', null); await salvarSala(); await dormir(60);
      const ok = esperaMsg.test(logs.join(' | ')) && !$('#salaPanel').hidden && $('#btnSalvarSala').disabled === false && $('#btnSalvarSala').textContent === 'Salvar sala' && S.salas.length === n0 && S.salas.find(s => s.id === 'rg-srv-4').nome === 'RG 4001' && !logs.includes('Sala atualizada.') && !logs.includes('Sala criada e selecionada.');
      fecharSalaPanel(); return ok; };
    c.edit_servidor_recusa_mostra_o_motivo = await falha(async () => ({ ok: false, erro: 'x' }), /O servidor não aceitou a edição \(x\)/);
    c.edit_servidor_sem_resposta_util_mostra_aviso = await falha(async () => undefined, /O servidor não aceitou a edição \(erro\)/);
    c.edit_servidor_rede_mostra_sem_conexao = await falha(async () => { const e = new Error('x'); e.rede = true; throw e; }, /Sem conexão: sala do servidor só pode ser editada com internet/);
    c.edit_servidor_404_mostra_migracao = await falha(async () => { const e = new Error('nf'); e.http = 404; throw e; }, /migração 004/);
    c.edit_servidor_409_mostra_erro = await falha(async () => { const e = new Error('conflito'); e.http = 409; throw e; }, /Erro ao editar no servidor: conflito/);
    c.edit_servidor_500_mostra_erro = await falha(async () => { const e = new Error('boom'); e.http = 500; throw e; }, /Erro ao editar no servidor: boom/);
    c.edit_servidor_permissao_mostra_aviso = await falha(async () => { const e = new Error('rls'); e.http = 403; e.permissao = true; throw e; }, /Sem permissão no servidor/);
    // (e2) servidor que NÃO responde (promessa pendente): mostra "Salvando…" enquanto espera e, vencido o prazo, avisa e libera o botão
    salaTimeoutMs = 400; Remote.atualizarSala = () => new Promise(() => {}); logs.length = 0; n0 = S.salas.length;
    await editarPeloCartao('rg-srv-4', 'RG 4001-PENDURADO', '5', null);
    const pend = salvarSala(); await dormir(150);
    c.edit_servidor_pendurado_mostra_salvando = $('#toast').textContent === 'Salvando no servidor…' && !$('#toast').hidden && $('#btnSalvarSala').disabled === true && $('#btnSalvarSala').textContent === 'Salvando…';
    await pend; await dormir(60);
    c.edit_servidor_pendurado_vence_o_prazo_e_avisa = /Sem conexão: sala do servidor só pode ser editada com internet/.test(logs.join(' | ')) && $('#toast').textContent.startsWith('Sem conexão') && $('#btnSalvarSala').disabled === false && $('#btnSalvarSala').textContent === 'Salvar sala' && !$('#salaPanel').hidden && S.salas.length === n0 && S.salas.find(s => s.id === 'rg-srv-4').nome === 'RG 4001';
    fecharSalaPanel(); salaTimeoutMs = tmo0;
    // (e3) CANCELAR enquanto o servidor ainda não respondeu: a edição continua valendo para a MESMA sala (antes criava uma sala nova, que seguia para o servidor)
    Remote.atualizarSala = async p => { chamada = p; await dormir(500); return { ok: true }; }; chamada = null; logs.length = 0; n0 = S.salas.length;
    await editarPeloCartao('rg-srv-4', 'RG 4001-CANCELADO', '6', null);
    const lenta = salvarSala(); await dormir(150); $('#btnCancelarSala').click(); await lenta; await dormir(100);
    c.edit_cancelar_durante_o_envio_nao_cria_sala_nova = S.salas.length === n0 && nomes().filter(n => n.startsWith('RG 4001')).length === 1 && S.salas.find(s => s.id === 'rg-srv-4').nome === 'RG 4001-CANCELADO' && !logs.includes('Sala criada e selecionada.') && logs.includes('Sala atualizada.') && $('#salaPanel').hidden;
    c.edit_cancelar_durante_o_envio_nao_deixa_sala_para_enviar = (await getAll('salas')).filter(s => s.nome.startsWith('RG 4001') && s.id !== 'rg-srv-4').length === 0;
    // (f) TOQUE DUPLO em "Salvar sala" (sala nova): uma sala e uma coordenação só
    Remote.atualizarSala = rem0.a; n0 = S.salas.length; nc0 = S.coords.length;
    abrirSalaPanel(null); $('#sNome').value = 'RG 9999'; $('#sCoord').value = 'RGNOVA'; $('#sAndar').value = '9'; renderLocalSelect('Prédio Central'); logs.length = 0;
    const t1 = salvarSala(), t2 = salvarSala(); await Promise.all([t1, t2]); await dormir(150);      // dois toques antes de a primeira gravação terminar
    c.sala_nova_toque_duplo_cria_so_uma = S.salas.filter(s => s.nome === 'RG 9999').length === 1 && S.salas.length === n0 + 1 && S.coords.filter(k => k.nome === 'RGNOVA').length === 1 && S.coords.length === nc0 + 1 && logs.filter(m => m === 'Sala criada e selecionada.').length === 1;
    c.sala_toque_duplo_libera_o_botao = $('#btnSalvarSala').disabled === false && $('#btnSalvarSala').textContent === 'Salvar sala';
    // restaura o que o bloco trocou
    Object.defineProperties(Engine, eng0); Remote.atualizarSala = rem0.a; Remote.lerResponsavelPessoal = rem0.l; toast = toast0; salaTimeoutMs = tmo0;
    S.salaId = null; fecharSalaPanel(); showTab('registrar'); }
  // --- armazenamento: faixa do topo e aba Mais precisam concordar, mesmo com chamadas simultâneas ---
  await Promise.all([renderStorage(), renderStorage(), renderStorage()]);
  const chip = $('#statusStorage').textContent, info = $('#infoStorage').textContent;
  c.armazenamento_consistente = chip.includes('protegido') === info.includes('(protegido)') && chip.includes('NÃO garantido') === info.includes('NÃO garantido');
  c.sem_erros_js = (window.__errs || []).length === 0;
  return JSON.stringify({ c, chip, errs: window.__errs });
})()
'@

# ================================================================ a partir daqui: execução
# (se este arquivo estiver sem BOM e o PowerShell 5.1 ler como ANSI, os blocos acima são relidos como UTF-8 aqui)
$b = Bloco 'seed';    if ($b) { $seed = $b }
$b = Bloco 'roteiro'; if ($b) { $roteiro = $b }

$navs = @(Achar-Navegadores)

# ---------------------------------------------------------------- modo -Diagnostico
function Diagnosticar {
  Escrever '=== DIAGNOSTICO (nenhum teste e executado) ===' 'Cyan'
  Escrever ('PowerShell : ' + $PSVersionTable.PSVersion + ' (' + $PSVersionTable.PSEdition + ')')
  Escrever ('Windows    : ' + [Environment]::OSVersion.VersionString)
  Escrever ('Usuario    : ' + $env:USERDOMAIN + '\' + $env:USERNAME)
  Escrever ('Projeto    : ' + $root)
  Escrever ('TEMP       : ' + $env:TEMP)
  $pyc = Get-Command py -ErrorAction SilentlyContinue; if (-not $pyc) { $pyc = Get-Command python -ErrorAction SilentlyContinue }
  if ($pyc) { Escrever ('Python     : ' + $pyc.Source) } else { Escrever 'Python     : NAO ENCONTRADO' 'Red' }
  if (-not $navs) { Escrever 'Navegadores: nenhum Edge/Chrome encontrado nos caminhos padrao' 'Red' }
  foreach ($n in $navs) { Escrever ('Navegador  : ' + $n.Nome + ' ' + $n.Versao + '  ' + $n.Caminho) }

  Escrever '--- processos de navegador ja abertos com remote-debugging-port (de qualquer sessao que voce consiga ver) ---'
  try {
    $ps = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" | Where-Object { $_.CommandLine -match 'remote-debugging-port' })
    if ($ps.Count -eq 0) { Escrever '  nenhum' }
    foreach ($x in $ps) { $cl = [string]$x.CommandLine; if ($cl.Length -gt 220) { $cl = $cl.Substring(0, 220) + '...' }; Escrever ('  PID ' + $x.ProcessId + '  ' + $x.Name + '  ' + $cl) }
  } catch { Escrever ('  nao consegui listar: ' + $_.Exception.Message) 'Yellow' }

  Escrever '--- porta 9337 (a antiga porta fixa) ---'
  try {
    $con = @(Get-NetTCPConnection -LocalPort 9337 -ErrorAction SilentlyContinue)
    if ($con.Count -eq 0) { Escrever '  livre' } else { foreach ($k in $con) { Escrever ('  ' + $k.State + '  PID ' + $k.OwningProcess) } }
  } catch { Escrever ('  nao consegui consultar: ' + $_.Exception.Message) 'Yellow' }

  Politicas

  Escrever '--- servidor local e sonda de pagina (o teste NAO usa file://; serve por http://127.0.0.1) ---'
  $srvD = $null
  try {
    [IO.File]::WriteAllText($arqS, $seed.Replace('__TEMPO__', '15000'), $utf8)
    $srvD = Iniciar-Servidor
    Escrever ('  servidor: ' + $srvD.Tipo + ' em ' + $base)
    foreach ($nav in $navs) {
      Escrever ('--- sonda: ' + $nav.Nome + ' ---') 'Cyan'
      $ctx = $null
      try {
        $ctx = Abrir-CDP $nav $true
        Escrever '  CDP conectado (ok)' 'Green'
        $nv = Cdp 'Page.navigate' @{ url = "$base/_seed.html" }
        if ($nv.result.errorText) { Escrever ('  navegar para ' + $base + '/_seed.html FALHOU: ' + $nv.result.errorText) 'Red' } else { Escrever ('  navegar para ' + $base + '/_seed.html: ok') }
        [void](Esperar-Pagina 'window.__done === true || !!window.__erro' 20)
        Escrever ('  resultado da semeadura na pagina: ' + (Valor-Pagina 'document.getElementById("semeado") ? document.getElementById("semeado").textContent : "(sem pre)"'))
        Escrever (Contexto-Falha)
        # mesma coisa por "localhost": se so este falhar, o problema e a resolucao de nome/proxy
        $nl = Cdp 'Page.navigate' @{ url = "http://localhost:$Porta/_seed.html" }
        if ($nl.result.errorText) { Escrever ('  navegar por localhost FALHOU: ' + $nl.result.errorText + '  (por isso o teste usa 127.0.0.1)') 'Yellow' } else { Escrever '  navegar por localhost: ok' }
      } catch { Escrever ('  ERRO: ' + $_.Exception.Message) 'Red' }
      finally { if ($ctx) { Fechar-CDP $ctx } }
    }
  } catch { Escrever ('  ERRO: ' + $_.Exception.Message) 'Red' }
  finally {
    Parar-Servidor $srvD
    Remove-Item -LiteralPath $arqS -Force -ErrorAction SilentlyContinue
  }
  Escrever '=== fim do diagnostico: copie tudo acima e cole na conversa ===' 'Cyan'
}

# politicas corporativas que podem afetar o teste (URLBlocklist, file://, depuracao, extensoes, proxy)
function Politicas {
  Escrever '--- politicas de navegador (registro: HKLM e HKCU) ---'
  $raizes = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKLM:\SOFTWARE\Policies\Google\Chrome', 'HKCU:\SOFTWARE\Policies\Microsoft\Edge', 'HKCU:\SOFTWARE\Policies\Google\Chrome'
  $rel = 'URL|File|Debug|Developer|Extension|Proxy|Remote|Headless|Command|Incognito|Allow|Block'
  $bloq = @(); $perm = @(); $achou = $false
  foreach ($ch in $raizes) {
    if (-not (Test-Path $ch)) { continue }
    $achou = $true
    Escrever ('  chave ' + $ch)
    try {
      (Get-ItemProperty $ch).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and $_.Name -match $rel } | ForEach-Object { Escrever ('    ' + $_.Name + ' = ' + $_.Value) }
      foreach ($k in @(Get-ChildItem $ch -Recurse -ErrorAction SilentlyContinue)) {
        $nome = $k.PSChildName
        $vals = @((Get-ItemProperty $k.PSPath).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { [string]$_.Value })
        if ($nome -match 'URLBlocklist|URLBlacklist') { $bloq += $vals }
        if ($nome -match 'URLAllowlist|URLWhitelist') { $perm += $vals }
        if ($nome -match 'URL|File|Debug|Extension|Allow|Block|Proxy') { Escrever ('    [' + $nome + '] ' + ($vals -join '  ;  ')) }
      }
    } catch { Escrever ('    nao consegui ler: ' + $_.Exception.Message) 'Yellow' }
  }
  if (-not $achou) { Escrever '  nenhuma chave de politica encontrada (ou sem permissao para ler)' }
  $fileBloq = @($bloq | Where-Object { $_ -match '^(file:|\*$)' })
  if ($fileBloq.Count -gt 0) { Escrever ('  >>> file:// (ou tudo) esta BLOQUEADO por URLBlocklist: ' + ($fileBloq -join ', ') + '  (o teste nao usa file://)') 'Yellow' }
  else { Escrever '  file:// NAO esta bloqueado por URLBlocklist (e o teste nao usa file://: serve por http://127.0.0.1).' }
  if ($bloq.Count -gt 0) { Escrever ('  URLBlocklist completa: ' + ($bloq -join '  ;  ')) }
  if ($perm.Count -gt 0) { Escrever ('  URLAllowlist completa: ' + ($perm -join '  ;  ')) }
}

# ---------------------------------------------------------------- servidor local (python ou .NET puro)
function Iniciar-Servidor {
  $pyc = Get-Command py -ErrorAction SilentlyContinue
  if (-not $pyc) { $pyc = Get-Command python -ErrorAction SilentlyContinue }
  $proc = $null
  if ($pyc) {
    $proc = Start-Process $pyc.Source -ArgumentList ('-m http.server ' + $Porta + ' --bind 127.0.0.1 --directory "' + $root + '"') -PassThru -WindowStyle Hidden
    if (Esperar-Servidor) { return @{ Tipo = 'python http.server'; Proc = $proc; Ps = $null } }
    Encerrar $proc
    Escrever '  python http.server nao respondeu; usando o servidor .NET.' 'Yellow'
  }
  # alternativa sem Python: servidor HTTP minimo em um runspace (so 127.0.0.1, so GET, so arquivos da pasta do projeto)
  $codigoServ = {
    param($raiz, $porta)
    $tipos = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.json' = 'application/json; charset=utf-8'; '.png' = 'image/png'; '.webmanifest' = 'application/manifest+json'; '.wasm' = 'application/wasm'; '.svg' = 'image/svg+xml' }
    $l = New-Object Net.Sockets.TcpListener -ArgumentList @([Net.IPAddress]::Loopback, $porta)
    $l.Start()
    while ($true) {
      $cli = $l.AcceptTcpClient()
      try {
        $cli.ReceiveTimeout = 3000
        $s = $cli.GetStream()
        $buf = New-Object byte[] 8192; $n = $s.Read($buf, 0, $buf.Length)
        if ($n -gt 0) {
          $req = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
          $alvo = (($req -split ' ')[1] -split '\?')[0]
          $rel = [Uri]::UnescapeDataString($alvo).TrimStart('/').Replace('/', '\')
          if ($rel -eq '') { $rel = 'index.html' }
          $arq = [IO.Path]::GetFullPath((Join-Path $raiz $rel))
          if ($arq.StartsWith($raiz, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $arq -PathType Leaf)) {
            $corpo = [IO.File]::ReadAllBytes($arq)
            $ct = $tipos[[IO.Path]::GetExtension($arq).ToLower()]; if (-not $ct) { $ct = 'application/octet-stream' }
            $cab = "HTTP/1.1 200 OK`r`nContent-Type: $ct`r`nContent-Length: $($corpo.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
          } else {
            $corpo = [Text.Encoding]::ASCII.GetBytes('nao encontrado')
            $cab = "HTTP/1.1 404 Not Found`r`nContent-Length: $($corpo.Length)`r`nConnection: close`r`n`r`n"
          }
          $hb = [Text.Encoding]::ASCII.GetBytes($cab); $s.Write($hb, 0, $hb.Length); $s.Write($corpo, 0, $corpo.Length)
        }
      } catch {} finally { try { $cli.Close() } catch {} }
    }
  }
  $ps = [PowerShell]::Create()
  [void]$ps.AddScript($codigoServ).AddArgument($root).AddArgument($Porta)
  [void]$ps.BeginInvoke()
  if (-not (Esperar-Servidor)) { try { [void]$ps.BeginStop($null, $null) } catch {}; throw ('Nem o python nem o servidor .NET responderam em http://127.0.0.1:' + $Porta) }
  return @{ Tipo = 'servidor .NET (sem python)'; Proc = $null; Ps = $ps }
}
function Esperar-Servidor {
  for ($i = 0; $i -lt 40; $i++) {
    try { [void](Invoke-WebRequest "http://127.0.0.1:$Porta/index.html" -UseBasicParsing -TimeoutSec 2); return $true } catch { Start-Sleep -Milliseconds 250 }
  }
  return $false
}
function Parar-Servidor($s) {
  if (-not $s) { return }
  Encerrar $s.Proc
  if ($s.Ps) { try { [void]$s.Ps.BeginStop($null, $null) } catch {} }
}

# ---------------------------------------------------------------- pré-requisitos
if ($Porta -le 0) { $Porta = Porta-Livre }
# 127.0.0.1 (e nao "localhost"): evita resolucao de nome/proxy do ambiente; nada de file://
$base = "http://127.0.0.1:$Porta"

# ---------------------------------------------------------------- páginas de teste (UTF-8 sem BOM)
$utf8 = New-Object Text.UTF8Encoding $false
$indexHtml = [IO.File]::ReadAllText((Join-Path $root 'index.html'), [Text.Encoding]::UTF8)
$gancho = '<script src="remote-adapter.js">'
if (-not $indexHtml.Contains($gancho)) { Escrever 'index.html mudou: nao achei <script src="remote-adapter.js"> para injetar a captura de erros.' 'Red'; exit 1 }
$captura = '<script>window.__errs=[];window.onerror=function(m,s,l,c){window.__errs.push(m+" @"+l+":"+c)};window.addEventListener("unhandledrejection",function(e){window.__errs.push("rej:"+(e.reason&&e.reason.message||e.reason))})</script>'
$html = $indexHtml.Replace($gancho, $captura + $gancho)
# versão do modo --dump-dom: o roteiro roda sozinho depois do carregamento e escreve o resultado em <pre id="resultado">
# No tempo virtual do --dump-dom um timer fixo dispara antes de o IndexedDB responder (o app ainda nao abriu o banco).
# Por isso a espera e feita por ESTADO (banco aberto, sala semeada, descricoes importadas), com fetch para dar tempo real.
$rodape = "<script>window.addEventListener('load', function () {`n" +
  "var fim = function (txt) { var p = document.createElement('pre'); p.id = 'resultado'; p.textContent = txt; document.body.appendChild(p); };`n" +
  "var pronto = function () { try { return typeof db !== 'undefined' && !!db && db.version >= 4 && S.salas.some(function (s) { return s.id === 's1'; }); } catch (e) { return false; } };`n" +
  "var importou = function () { try { return S.descricoes.length > 0; } catch (e) { return false; } };`n" +
  "(async function () {`n" +
  "  for (var i = 0; i < 5000 && !pronto(); i++) { try { await fetch('index.html?p=' + i, { cache: 'no-store' }); } catch (e) {} }`n" +
  "  for (var j = 0; j < 600 && !importou(); j++) { try { await fetch('index.html?q=' + j, { cache: 'no-store' }); } catch (e) {} }`n" +
  "  return await Promise.resolve(`n" + $roteiro + "`n);`n" +
  "})().then(fim).catch(function (e) { fim(JSON.stringify({ c: { roteiro_sem_excecao: false }, errs: [String(e)] })); });`n" +
  "});`n" +
  "setTimeout(function () { if (document.getElementById('resultado')) return; var p = document.createElement('pre'); p.id = 'diag'; p.textContent = JSON.stringify({ url: location.href, titulo: document.title, readyState: document.readyState, errs: window.__errs || [], body: (document.body ? document.body.innerText : '').slice(0, 600) }); document.body.appendChild(p); }, 150000);`n" +
  "</script></body>"
$htmlDom = $html.Replace('</body>', $rodape)
if ($htmlDom -eq $html) { Escrever 'index.html sem </body>: o modo dom nao consegue injetar o roteiro.' 'Yellow' }

$arqT = Join-Path $root '_t.html'; $arqD = Join-Path $root '_td.html'; $arqS = Join-Path $root '_seed.html'

# ---------------------------------------------------------------- CDP (depuração remota por WebSocket)
$script:cws = $null; $script:cid = 0
function Cdp($metodo, $params, [int]$limite = 90) {
  $script:cid++
  $corpo = @{ id = $script:cid; method = $metodo }
  if ($params) { $corpo.params = $params }
  $bytes = [Text.Encoding]::UTF8.GetBytes(($corpo | ConvertTo-Json -Depth 8 -Compress))
  $cts = New-Object Threading.CancellationTokenSource -ArgumentList ($limite * 1000)
  $script:cws.SendAsync([ArraySegment[byte]]$bytes, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait()
  $buf = New-Object byte[] 65536
  while ($true) {
    $sb = New-Object Text.StringBuilder
    do {
      $r = $script:cws.ReceiveAsync([ArraySegment[byte]]$buf, $cts.Token).Result
      if ($r.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'o navegador fechou a conexao de depuracao' }
      [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Count))
    } until ($r.EndOfMessage)
    $m = $sb.ToString() | ConvertFrom-Json
    if ($m.method) { Registrar-Evento $m }
    if ($m.id -eq $script:cid) { return $m }
  }
}

# guarda o que o navegador reporta (excecoes JS, console de erro, log, requisicoes que falharam) para imprimir quando algo der errado
$script:eventos = New-Object Collections.ArrayList; $script:urls = @{}; $script:ultimoErroCdp = ''
function Registrar-Evento($m) {
  $p = $m.params; $t = $null
  switch ($m.method) {
    'Runtime.exceptionThrown' {
      $d = $p.exceptionDetails; $desc = ''
      if ($d.exception -and $d.exception.description) { $desc = [string]$d.exception.description }
      $t = 'EXCECAO JS: ' + $d.text + ' ' + $desc + ' @ ' + $d.url + ':' + $d.lineNumber
    }
    'Runtime.consoleAPICalled' {
      if ($p.type -in 'error', 'warning', 'assert') {
        $txt = (@($p.args) | ForEach-Object { if ($null -ne $_.value) { [string]$_.value } else { [string]$_.description } }) -join ' '
        $t = 'console.' + $p.type + ': ' + $txt
      }
    }
    'Log.entryAdded' {
      if ($p.entry.level -in 'error', 'warning') { $t = 'LOG[' + $p.entry.level + '] ' + $p.entry.text + ' ' + $p.entry.url }
    }
    'Network.requestWillBeSent' { $script:urls[[string]$p.requestId] = [string]$p.request.url }
    'Network.loadingFailed' { $t = 'REQUISICAO FALHOU: ' + $script:urls[[string]$p.requestId] + '  erro=' + $p.errorText + ' bloqueio=' + $p.blockedReason }
    'Network.responseReceived' { if ([int]$p.response.status -ge 400) { $t = 'HTTP ' + $p.response.status + ' ' + $p.response.url } }
  }
  if ($t -and $script:eventos.Count -lt 300) { [void]$script:eventos.Add($t) }
}

function Valor-Pagina($expr) {
  try {
    $r = Cdp 'Runtime.evaluate' @{ expression = $expr; returnByValue = $true } 10
    if ($r.result -and $r.result.result) { return [string]$r.result.result.value }
  } catch { $script:ultimoErroCdp = $_.Exception.Message }
  return ''
}
function Esperar-Pagina($expr, [int]$seg) {
  $fim = (Get-Date).AddSeconds($seg)
  while ((Get-Date) -lt $fim) {
    try {
      $r = Cdp 'Runtime.evaluate' @{ expression = $expr; returnByValue = $true } 10
      if ($r.result -and $r.result.result -and $r.result.result.value -eq $true) { return $true }
    } catch { $script:ultimoErroCdp = $_.Exception.Message }
    Start-Sleep -Milliseconds 300
  }
  return $false
}

# estado da pagina + eventos capturados: anexado a toda mensagem de timeout
function Contexto-Falha {
  $l = @()
  $estado = Valor-Pagina 'JSON.stringify({ url: location.href, titulo: document.title, readyState: document.readyState, erro_semeadura: window.__erro || null, errs_app: window.__errs || null, body: (document.body ? document.body.innerText : "(sem body)").slice(0, 600) })'
  if ($estado) { $l += ('  estado da pagina: ' + $estado) } else { $l += ('  estado da pagina: nao consegui ler (' + $script:ultimoErroCdp + ')') }
  if ($script:ultimoErroCdp) { $l += ('  ultimo erro de CDP engolido durante a espera: ' + $script:ultimoErroCdp) }
  if ($script:eventos.Count -eq 0) { $l += '  eventos do navegador: nenhum capturado' }
  else { $l += '  eventos do navegador (ate 40):'; foreach ($e in @($script:eventos | Select-Object -First 40)) { $l += ('    ' + $e) } }
  return ($l -join "`n")
}

function Fechar-CDP($ctx) {
  if ($script:cws) { try { $script:cws.Dispose() } catch {}; $script:cws = $null }
  Encerrar $ctx.Proc
  Remover-Perfil $ctx.Perfil
}

# abre o navegador com depuracao remota e conecta; devolve o contexto (Proc, Perfil, Dbg). Fechar com Fechar-CDP.
function Abrir-CDP($nav, [bool]$verboso) {
  $dbg = $PortaDebug; if ($dbg -le 0) { $dbg = Porta-Livre }
  $ctx = @{ Proc = $null; Perfil = (Novo-Perfil); Dbg = $dbg }
  $script:cws = $null; $script:cid = 0; $script:ultimoErroCdp = ''
  $script:eventos = New-Object Collections.ArrayList; $script:urls = @{}
  try {
    $linha = (Args-Base $ctx.Perfil) + ' --remote-debugging-port=' + $dbg + ' --remote-debugging-address=127.0.0.1 --remote-allow-origins=* about:blank'
    $ctx.Proc = Start-Process $nav.Caminho -ArgumentList $linha -PassThru
    $erroCon = ''
    for ($t = 1; $t -le 3 -and -not $script:cws; $t++) {
      $alvo = Esperar-Alvo $ctx.Proc $dbg 30
      $ws = [string]@($alvo.webSocketDebuggerUrl)[0]
      if ($verboso) {
        try { Escrever ('  /json/version: ' + ((Invoke-RestMethod "http://127.0.0.1:$dbg/json/version" -TimeoutSec 5) | ConvertTo-Json -Compress)) } catch { Escrever ('  /json/version falhou: ' + $_.Exception.Message) 'Yellow' }
        Escrever ('  alvo: type=' + $alvo.type + ' url=' + $alvo.url + '  ws=' + $ws)
        Escrever ('  handshake bruto: ' + (Handshake-Bruto $dbg ([Uri]$ws).AbsolutePath))
      }
      $cli = New-Object Net.WebSockets.ClientWebSocket
      try { $cli.Options.Proxy = $null } catch {}
      try {
        $tk = $cli.ConnectAsync([Uri]$ws, [Threading.CancellationToken]::None)
        if (-not $tk.Wait(15000)) { throw 'tempo esgotado (15 s) no ConnectAsync' }
        $script:cws = $cli
      } catch {
        $hs = Handshake-Bruto $dbg ([Uri]$ws).AbsolutePath
        $erroCon = "tentativa $t falhou ao abrir o WebSocket em $ws`n  excecao real:`n$(Texto-Excecao $_.Exception)`n  handshake HTTP bruto: $hs"
        try { $cli.Dispose() } catch {}
        Start-Sleep -Seconds 1
      }
    }
    if (-not $script:cws) { throw ("Nao consegui conectar na depuracao remota.`n" + $erroCon) }
    foreach ($dom in 'Runtime.enable', 'Log.enable', 'Network.enable') { [void](Cdp $dom $null 15) }
  } catch { Fechar-CDP $ctx; throw }
  return $ctx
}

function Navegar($url) {
  $r = Cdp 'Page.navigate' @{ url = $url }
  if ($r.result.errorText) { throw ('A navegacao para ' + $url + ' falhou: ' + $r.result.errorText + "`n" + (Contexto-Falha)) }
}

function Rodar-CDP($nav) {
  [IO.File]::WriteAllText($arqS, $seed.Replace('__TEMPO__', '15000'), $utf8)
  $ctx = $null
  try {
    $ctx = Abrir-CDP $nav $false

    # 1) semeia o banco no formato antigo (a pagina tem timeout interno de 15 s e escreve o motivo do erro)
    Navegar "$base/_seed.html"
    if (-not (Esperar-Pagina 'window.__done === true || !!window.__erro' 30)) { throw ("_seed.html nao terminou em 30 s`n" + (Contexto-Falha)) }
    $er = Valor-Pagina 'window.__erro || ""'
    if ($er) { throw ("A semeadura falhou dentro da pagina: " + $er + "`n" + (Contexto-Falha)) }
    # 2) abre o app (faz a migração) e roda o roteiro
    Navegar "$base/_t.html"
    if (-not (Esperar-Pagina "document.readyState === 'complete' && typeof Engine !== 'undefined' && typeof S !== 'undefined'" 30)) { throw ("O app (_t.html) nao terminou de carregar em 30 s`n" + (Contexto-Falha)) }
    Start-Sleep -Seconds 2
    $resp = Cdp 'Runtime.evaluate' @{ expression = $roteiro; awaitPromise = $true; returnByValue = $true } 120
    if ($resp.result.exceptionDetails) {
      $d = $resp.result.exceptionDetails; $txt = ''
      if ($d.exception -and $d.exception.description) { $txt = [string]$d.exception.description } else { $txt = [string]$d.text }
      throw ("O roteiro lancou uma excecao no navegador: " + $txt + "`n" + (Contexto-Falha))
    }
    return [string]$resp.result.result.value
  } finally {
    if ($ctx) { Fechar-CDP $ctx }
  }
}

# ---------------------------------------------------------------- plano B: --dump-dom, sem WebSocket
function Executar-Dump($nav, $linha, [int]$limiteSeg) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $nav.Caminho; $psi.Arguments = $linha; $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $p = [Diagnostics.Process]::Start($psi)
  $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
  $script:stderrDump = ''
  if (-not $p.WaitForExit($limiteSeg * 1000)) { Encerrar $p; [void]$so.Wait(5000); $script:stderrDump = 'TEMPO ESGOTADO (' + $limiteSeg + ' s): o navegador foi encerrado.' }
  try { [void]$p.WaitForExit(5000) } catch {}
  # stderr sem o ruido conhecido (GPU, PHONE_REGISTRATION, update_service, TensorFlow, task_manager)
  try {
    if ($se.Wait(3000)) {
      $linhas = @(([string]$se.Result) -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch 'GPU process exited|PHONE_REGISTRATION_ERROR|update_service_dialer|TensorFlow|task_manager|fallback_task_provider' } | Select-Object -Last 15 | ForEach-Object { if ($_.Length -gt 300) { $_.Substring(0, 300) + '...' } else { $_ } })
      if ($linhas.Count) { $script:stderrDump = ($script:stderrDump + "`n" + ($linhas -join "`n")).Trim() }
    }
  } catch {}
  if ($so.IsCompleted) { return [string]$so.Result } else { return '' }
}
$script:stderrDump = ''

# resume o que a pagina escreveu no DOM quando algo falha (os erros vao dentro do DOM: <pre id="semeado"> e <pre id="diag">)
function Resumo-Dom($saida) {
  $l = @()
  $m = [regex]::Match($saida, '(?s)<pre id="semeado">(.*?)</pre>'); if ($m.Success) { $l += ('  <pre id=semeado>: ' + [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)) }
  $m = [regex]::Match($saida, '(?s)<pre id="diag">(.*?)</pre>'); if ($m.Success) { $l += ('  <pre id=diag>: ' + [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)) }
  $m = [regex]::Match($saida, '(?s)<title>(.*?)</title>'); if ($m.Success) { $l += ('  titulo: ' + $m.Groups[1].Value) }
  if (-not $saida) { $l += '  o navegador nao devolveu nenhum DOM' } elseif ($l.Count -eq 0) { $l += ('  DOM com ' + $saida.Length + ' caracteres; inicio: ' + $saida.Substring(0, [Math]::Min(400, $saida.Length)).Replace("`n", ' ')) }
  if ($script:stderrDump) { $l += '  stderr do navegador (sem o ruido conhecido):'; foreach ($x in ($script:stderrDump -split "`n")) { $l += ('    ' + $x) } }
  return ($l -join "`n")
}

function Rodar-Dom($nav) {
  $perfil = Novo-Perfil
  try {
    $b = Args-Base $perfil
    # 1a execução: semeia o IndexedDB (o mesmo perfil e reaproveitado na 2a execução)
    # (tempo interno da pagina bem maior que no CDP: no tempo virtual, timers disparam cedo demais)
    [IO.File]::WriteAllText($arqS, $seed.Replace('__TEMPO__', '55000'), $utf8)
    $o1 = Executar-Dump $nav ($b + ' --virtual-time-budget=60000 --dump-dom "' + $base + '/_seed.html"') 90
    if ($o1 -notmatch 'SEMEADO-OK') { throw ("dump-dom: a pagina de semeadura nao terminou (nao apareceu SEMEADO-OK no DOM).`n" + (Resumo-Dom $o1)) }
    # 2a execução: abre o app com o banco semeado e roda o roteiro
    $o2 = Executar-Dump $nav ($b + ' --virtual-time-budget=180000 --dump-dom "' + $base + '/_td.html"') 240
    $m = [regex]::Match($o2, '(?s)<pre id="resultado">(.*?)</pre>')
    if (-not $m.Success) { throw ("dump-dom: o roteiro nao escreveu <pre id=resultado> (tempo virtual insuficiente ou erro de carga).`n" + (Resumo-Dom $o2)) }
    return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
  } finally { Remover-Perfil $perfil }
}

if ($Diagnostico) { Diagnosticar; exit 0 }
if (-not $navs) { Escrever 'Edge/Chrome nao encontrado (veja -Diagnostico).' 'Red'; exit 1 }

# ---------------------------------------------------------------- execução
$codigo = 1; $srv = $null; $json = $null; $usado = ''; $motivos = @()
try {
  [IO.File]::WriteAllText($arqT, $html, $utf8)
  [IO.File]::WriteAllText($arqD, $htmlDom, $utf8)
  [IO.File]::WriteAllText($arqS, $seed, $utf8)

  $srv = Iniciar-Servidor
  Escrever ('Servidor local: ' + $srv.Tipo + ' em ' + $base + '  (sem file://)') 'Cyan'

  $modos = @('cdp', 'dom'); if ($Modo -ne 'auto') { $modos = @($Modo) }
  foreach ($md in $modos) {
    foreach ($nav in $navs) {
      Escrever ("Tentando modo " + $md.ToUpper() + " com " + $nav.Nome + " " + $nav.Versao + " ...") 'Cyan'
      try {
        if ($md -eq 'cdp') { $json = Rodar-CDP $nav } else { $json = Rodar-Dom $nav }
        if ($json) { $usado = $md.ToUpper() + ' / ' + $nav.Nome; break }
      } catch {
        $motivo = ('[' + $md.ToUpper() + ' / ' + $nav.Nome + '] ' + $_.Exception.Message)
        $motivos += $motivo
        Escrever ('  falhou: ' + $_.Exception.Message) 'Yellow'
      }
    }
    if ($json) { break }
  }

  if (-not $json) {
    Escrever '' ; Escrever 'NAO CONSEGUI RODAR OS TESTES. Causas encontradas:' 'Red'
    foreach ($mo in $motivos) { Escrever ('  ' + $mo) 'Red' }
    Escrever 'Proxima acao: rode  powershell -ExecutionPolicy Bypass -File tools\teste-headless.ps1 -Diagnostico  e cole a saida na conversa.' 'Yellow'
    Escrever '  - "403" ou "fechou sozinho": provavel politica corporativa bloqueando depuracao remota (o modo dom deveria cobrir).' 'Yellow'
    Escrever '  - "nao escreveu <pre id=resultado>": o modo dom estourou o tempo; tente -Navegador chrome ou -Navegador edge.' 'Yellow'
  } else {
    Escrever ("Modo usado: $usado") 'Cyan'
    $out = $json | ConvertFrom-Json
    $total = 0; $falhas = 0
    foreach ($p in $out.c.PSObject.Properties) {
      $total++
      if ($p.Value -eq $true) { Escrever ('PASS  ' + $p.Name) 'Green' } else { Escrever ('FAIL  ' + $p.Name + '  (valor devolvido: ' + $p.Value + ')') 'Red'; $falhas++ }
    }
    if ($out.chip) { Escrever ('Faixa de armazenamento: ' + $out.chip) }
    if ($out.errs -and @($out.errs).Count) { Escrever ('Erros JS: ' + (@($out.errs) -join ' | ')) 'Red' }
    $passou = $total - $falhas
    Escrever ("Resumo: $total verificacoes, $passou passaram, $falhas falharam.") $(if ($falhas) { 'Red' } else { 'Green' })
    if ($falhas -eq 0 -and $total -gt 0) { $codigo = 0 }
  }
} catch {
  Escrever ('ERRO: ' + $_.Exception.Message) 'Red'
} finally {
  Parar-Servidor $srv
  Remove-Item -LiteralPath $arqT, $arqD, $arqS -Force -ErrorAction SilentlyContinue
}
exit $codigo
