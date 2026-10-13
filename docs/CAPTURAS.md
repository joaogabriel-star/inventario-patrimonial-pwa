# Capturas de tela e vídeo (roteiro)

Use **somente o seed de demonstração** (`supabase/seed_demo.sql`): todos os dados são fictícios. Antes de capturar, confira
que a barra de endereço, o e-mail do usuário e qualquer URL do projeto Supabase **não aparecem** na imagem. Tire as capturas
no celular (ou no navegador do computador em modo celular, ~390 px de largura) e salve em `docs/img/` com os nomes abaixo
(o README já aponta para eles).

## Capturas

| Arquivo | Tela | Como chegar | O que deve aparecer |
|---|---|---|---|
| `registrar-leitura.png` | Registrar com leitura | Aba *Salas* → escolha "DAD - Sala 101" → aba *Registrar* → aponte a câmera para uma etiqueta (ou use o modo diagnóstico/digite `01001`) | Faixa "Lido: 01001", tipo/marca preenchidos pela planilha, sala escolhida, contador na faixa do topo |
| `salas-resumo-planilha.png` | Lista de salas com resumo da planilha | Aba *Salas* | Salas do seed (DAD, CTI, COM, JUR, PLAN...) com o resumo dos itens da planilha de consulta ligados às salas/coordenações (confira na tela o que aparece) |
| `bens-duplicidade.png` | Bens com aviso de duplicidade | Aba *Bens*; o seed traz o número `01005` repetido em "DAD - Sala 101" e "DAD - Sala 102" | Etiqueta "DUPLICIDADE" no bem; se quiser, também a plaqueta de outro órgão (`A00001234`) |
| `mover-bem.png` | Mover bem | Aba *Bens* → botão **Mover** num bem → janela com a lista de salas | Janela "Mover bem" com a sala de destino escolhida |
| `exportar-csv.png` | Exportar CSV | *Mais → Exportar* | Botões "CSV para Excel", "CSV de dados", "Cópia JSON" e "CSV da planilha" (não abra o arquivo exportado na captura) |
| `tema-escuro.png` | Tema escuro | *Mais →* Tema → Escuro; volte à aba *Registrar* ou *Bens* | Mesma tela em tema escuro |

Dica: se o número `01005` não gerar o aviso no aparelho, faça um *pull* (botão "Sincronizar agora") para baixar os bens do
seed; o aviso depende do último pull.

## Roteiro de vídeo (40 a 60 s)

Grave a tela do celular em modo retrato, sem áudio ou com uma trilha leve. Legende cada passo.

| Tempo | Cena | Legenda sugerida |
|---|---|---|
| 0–5 s | Abrir o app instalado na tela inicial; mostrar o título e a faixa "Servidor conectado" | "Inventário Patrimonial — PWA instalável" |
| 5–15 s | Aba *Salas*: escolher "CTI - Sala 201" e mostrar o resumo da planilha | "Escolho a sala; o app mostra o que já consta na planilha" |
| 15–25 s | Aba *Registrar*: ler uma etiqueta com a câmera; tipo e marca vêm preenchidos; salvar | "Leio a etiqueta e salvo — vibra e bipa só depois de gravar" |
| 25–32 s | Ligar o **modo avião**; registrar mais um bem; mostrar a faixa "⏳ 1 pendente" | "Sem internet: tudo é salvo no celular" |
| 32–40 s | Desligar o modo avião; a faixa passa de ⏳ para ✔ | "Voltou o sinal: a fila envia sozinha, sem duplicar" |
| 40–48 s | Ler `01005` de novo: aviso de **duplicidade** | "Número repetido? Aviso na hora, sem apagar nada" |
| 48–54 s | Aba *Bens* → **Mover** um bem de sala | "Moveu errado? Mover e desfazer, com auditoria" |
| 54–60 s | *Mais → Exportar → CSV para Excel*; fechar com o tema escuro | "Exporta CSV seguro para o Excel. Offline-first, RLS no Postgres, sem DELETE" |

## Checklist antes de publicar as imagens
- [ ] Nenhuma captura mostra URL do projeto Supabase, e-mail, sigla ou nome reais.
- [ ] O banco usado é um projeto novo com o seed de demonstração.
- [ ] Os arquivos estão em `docs/img/` com os nomes da tabela acima.
