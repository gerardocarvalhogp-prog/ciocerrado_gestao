# Testes de comportamento

```bash
docker exec -i supabase_db_gestao-cio-cerrado psql -U postgres -d postgres -q \
  < supabase/tests/07-regras-de-dinheiro.sql
```

Ou, pra não precisar ler a saída a olho (de `12` em diante):

```bash
python supabase/tests/confere.py supabase/tests/1[2-9]-*.sql supabase/tests/2*.sql
```

`confere.py` roda cada arquivo e diz, sozinho, se toda recusa esperada
recusou e toda checagem bateu — ver "Formato que o confere.py lê", abaixo.

## O 24 é diferente: duas conexões

```bash
python supabase/tests/24-corrida-na-reserva-do-cio.py
```

Corrida só existe com duas transações abertas ao mesmo tempo, e um `.sql`
roda numa conexão só. O `24` abre duas sessões `psql`: A salva a
hospedagem e segura a transação aberta; B salva a mesma hospedagem
enquanto A está aberta. Passa se B começou antes do commit de A e só
terminou depois dele (esperou a trava `FOR UPDATE` de `_garantir_reserva`),
sem erro, com uma reserva só. Os tempos são medidos dentro do banco
(`clock_timestamp()`), não no relógio do Python — o `docker exec` tem
latência variável. Se numa rodada as duas sessões nem se sobrepuserem,
ela é declarada inconclusiva e repetida (até 3x), nunca dada como passou.

Grava de verdade (as duas sessões precisam ver o participante), com
prefixo `cob24`, e apaga tudo no fim, mesmo se falhar.

Prova negativa feita em 05/10/2026: com a trava tirada de
`_garantir_reserva` no banco local, B estoura `duplicate key ...
reservas_participante_ativa_uk` e o teste acusa.

## Duas famílias, e a diferença importa

**`04` e `07` a `23` rodam em transação e desfazem tudo no fim.** Podem
rodar contra um banco com dado dentro, quantas vezes quiser, sem `db reset`.
De `13` em diante, cada arquivo cria o próprio evento (`cob13`, `cob14`...),
admins, cotas e preços dentro da transação — não depende de dado nenhum
do banco. `04` e `12` ainda dependem do `cerrado2027` com cotas (e o `04`,
de preço cadastrado nele).

**`01`, `02`, `03` e `05` gravam de verdade** e exigem banco limpo:
`supabase db reset`, depois `01` (que monta o cenário), depois o que
você quiser exercitar.

**O `db reset` do zero voltou a passar em 05/10/2026.** De 29/09 a
05/10, 17 migrations de DADO (vincular CIO de teste por nome, resetar
contrato de teste, limpar fila do hospedado...) faziam `raise exception`
quando não achavam a linha que procuravam — e num banco vazio nunca
acham. A guarda "alvo não encontrado" de cada uma virou `raise notice` +
`return` (no hospedado elas já tinham rodado; não muda nada lá). Conferido
no mesmo dia: reset do zero, depois a suíte inteira — `01`→`02`→`03`,
`01`→`05`, e `04`, `07`–`23` — só com as recusas esperadas.

`01` e `02` estavam desatualizados desde 01/09 (chamavam
`patro_salvar_quarto` com os dois parâmetros de brinde que saíram e liam
`brinde_vai_enviar`); foram ajustados pro brinde da empresa
(`patro_salvar_brinde`).

A diferença nasceu de um problema real: o banco local passou a ter a
importação do CADASTRO 2025, com 1056 gestores. Um `db reset` para rodar
teste destrói isso. Teste que só roda em banco vazio é teste que não
roda — daí a família nova.

Quando der, vale converter `01`–`03` e `05` para o mesmo formato.

## O que cada um cobre

| | |
|---|---|
| `01` | cenário base: evento aberto, duas patrocinadoras, quartos, um CIO com contrato |
| `02` | portal e rooming, e o que cada papel **não** pode fazer |
| `03` | fila da mesa redonda: ordem por cota, passar a vez, convidado que some da lista |
| `04` | fatura congelada: estimada acompanha o rooming, emitida e paga não |
| `05` | reserva da indicação e janela por cota |
| `07` | cortesia do acompanhante, teto de 4, transfer por pessoa, brinde da empresa e seu custo, preço do quarto adicional, correção do tipo de faixa |
| `08` | quarto de equipe (staff/organização): só admin cria, teto de 4, aparece em admin_listar_alocacao, remover libera o quarto |
| `09` | "App do evento" é admin-only nas 4 funções que exportam dado de participante, não só na tela (achado do relatório de segurança do Cowork) |
| `10` | staff só enxerga o evento associado em `admin_eventos`; admin vê todos — amostra de 4 funções |
| `11` | mesmo escopo por evento, agora nas funções que recebem id de sessão/reserva/brinde/atividade/checkin em vez do slug direto |
| `12` | mesa/sessão: limite de vagas ao adicionar, trava de CIO duplicado no mesmo tipo (mas não entre tipos), reconfirmar não esbarra na própria vaga, busca só traz quem pode entrar, quarto quádruplo |
| `13` | quartos: listar um por um, editar tipo (só admin), bloquear pra venda avulsa, finalidade do quarto travando a alocação, compra automática só do pool avulso, capacidade fixa por tipo pro patrocinador, "ocupado por", `_garantir_reserva` sem duplicar, etiqueta de equipe com o rótulo |
| `14` | "familiar" na prévia da fatura, quarto extra do patrocinador entra e sai da fatura, Financeiro sem fatura zerada, contrato da cota (valor, pagamento, vencido calculado), cobrança que não sai pra quem já resolveu |
| `15` | vários brindes por empresa, editar/remover só o próprio e só enquanto prometido, rastreio por brinde, custo de entrega contando quarto de CIO (não o da cota, não o cancelado), uma cobrança por porta |
| `16` | limite de indicações por cota (o que consome e o que não), cota que não escolhe sai da fila e é preenchida por sorteio |
| `17` | slots de arquivo pela cota, reenvio substitui, revisão só admin, pendência "arquivos enviados", policy do bucket (só a própria pasta), pré-cadastro por link (anon abre/envia, só admin decide, link vira só-leitura) |
| `18` | saúde no rooming, visita ao lounge (patrocinador e CIO), presença na mesa, materiais do CIO, relatório do Lounge, CIO edita os próprios dados e indica outra pessoa |
| `19` | jantar: link do Sympla na criação, CEP, logo, capacidade, QR, cadastro na porta, estatística de confirmação (31/08); atividade geral × exclusiva |
| `20` | WhatsApp dos jantares: telefone E.164, aviso só na transição pra confirmado, importação do Sympla, pipeline organizador → daemon (service_role) → convites |
| `21` | padrão de cadastro (trigger, 31/08), editar gestor, filtros, enriquecimento, empresa global entre eventos, CPF e CNPJ como chave |
| `22` | webhook do Autentique (só service_role, idempotente, link do PDF, aviso com corpo), mailing do evento inteiro, pesquisa no mailing |
| `23` | catálogo: service_role e admin inativo, nenhum papel de cliente lê tabela/view, views com security_invoker, RLS em toda tabela, índices, o que anon executa, overload órfão, escopo de staff por evento |
| `25` | usuário do patrocinador cadastrado como a tela faz hoje (só pela empresa): aparece na cobrança, na fatura, na planilha do app, no crachá e no check-in |
| `24` | **corrida de verdade** no duplo clique de "salvar hospedagem": duas sessões `psql` ao mesmo tempo, a segunda espera a trava da primeira e reaproveita a mesma reserva (`.py`, ver abaixo) |

`03` e `05` **não rodam juntos**: os dois criam mesa redonda para as
mesmas empresas e `sessoes` não tem chave única. `01` também não é
idempotente na parte de `sessoes`.

## Por que eles trocam de papel

```sql
set role authenticated;
set request.jwt.claims = '{"email":"ana@alfa.test","role":"authenticated"}';
```

É o que o PostgREST faz a cada request. Sem isso `auth.jwt()` volta
vazio, tudo roda como superusuário e **todo teste de permissão passa por
engano**.

## Cuidado ao escrever teste novo

**Os ids precisam ser capturados com `\gset` antes do `set role`.** Isso
era estilo e virou obrigação: antes, um subselect rodando como Ana
voltava vazio pela RLS e o teste passava a medir a RLS em vez da função —
erro silencioso. Desde 25/08 o papel `authenticated` não tem acesso
nenhum às tabelas do schema (só RPC), então o mesmo subselect estoura com
`permission denied for table X`. Barulhento, o que é melhor.

**Cada recusa esperada precisa do seu `savepoint`.** No Postgres o
primeiro erro aborta a transação inteira e todo comando seguinte devolve
"current transaction is aborted" — o resto do teste não roda e passa por
engano. O padrão é:

```sql
savepoint s1;
select funcao_que_deve_falhar(...);
rollback to s1;
```

**Checagem que volta zero linhas passa calada.** `select x = 1 as ok
from f() where ...` sem linha nenhuma não imprime nem `t` nem `f`. Achado
escrevendo o `13`: uma checagem de `admin_listar_alocacao` "passava" porque
a reserva testada não tinha ocupante e a função não devolvia nada. O
`confere.py` acusa zero linhas e valor nulo em coluna `_ok`.

## Formato que o confere.py lê

- `\echo '-- <o que acontece> — deve PASSAR'` antes de cada checagem, e
  as colunas que afirmam algo terminam em `_ok` (`as cobrou_ok`). Tem que
  vir `t`/`true`.
- `\echo '-- <o que acontece> — deve FALHAR'` antes de cada recusa
  esperada, com o `savepoint` em volta. Tem que vir um `ERROR` que não
  seja de sintaxe, de transação abortada, de savepoint inexistente nem
  `permission denied for table` — esses são defeito do teste, não a
  recusa que se queria provar.
- `\echo '-- ACHADO (data): ...'` marca comportamento que diverge do que
  a migration ou o CLAUDE.md dizem que deveria acontecer, e que ficou
  pra decisão do organizador. O teste registra o que acontece hoje (com
  `savepoint` em volta quando é erro) e **não** afirma nem que está certo
  nem que está errado — quando o organizador decidir, o bloco vira
  "deve PASSAR" ou "deve FALHAR" de verdade.
- Dentro de `\echo '...'` não pode ter apóstrofo: o psql lê como começo
  de string e engole o resto da linha.

## Achados de 05/10/2026 — todos corrigidos

Os testes `13`–`23` acharam 13 comportamentos que divergiam do que a
migration ou o CLAUDE.md diziam. Ficaram uma rodada marcados como
`ACHADO`; o organizador mandou corrigir todos no mesmo dia, e cada bloco
virou "deve PASSAR"/"deve FALHAR" de verdade, citando a migration:

| teste | o que acontecia | conserto |
|---|---|---|
| `13` | `admin_criar_faixa_quartos` cortava número de 4+ dígitos (`lpad(1301, 3)` = `'130'`): a faixa 1301–1306 criava **um** quarto, sem erro | `20261005090000` |
| `13` | CIO com a reserva principal não conseguia comprar quarto extra (índice único de 18/09 × compra que voltou em 30/09) | `20261005100000` |
| `13`, `14`, `23` | 6 funções com `p_evento_slug` (+ `admin_definir_status_quarto`) sem o escopo de staff por evento de 10/11 | `20261005110000` |
| `17` | upload aceitava tipo que a cota não pede e logo além da quantidade | `20261005120000` |
| `17` | arquivo rejeitado seguia fechando a pendência "arquivos enviados" | `20261005120000` |
| `19`, `23` | `admin_salvar_atividade` com duas versões (7 e 8 parâmetros) | `20261005130000` |
| `19` | atividade exclusiva não reconhecia CIO com rooming (`ocupante:<id>`) — sumia da lista da porta | `20261005130000` |
| `20` | `jantar_grupo_obter` estourava "status is ambiguous" pra qualquer jantar | `20261005140000` |
| `20` | convidado novo vindo do Sympla não recebia o aviso de WhatsApp | `20261005140000` |
| `20`, `23` | `_jantar_enfileirar_whatsapp_confirmacao` executável por `anon` | `20261005140000` |
| `14` | `admin_preparar_cobranca` (prévia com o e-mail do pendente) sem escopo de staff por evento — sobra da varredura | `20261005150000` |
| `25` | achado ao vivo (07/10): usuário de patrocinador cadastrado pela tela de hoje não era achado na cobrança, fatura, app, crachá e check-in — 6 lugares ainda procuravam por `patrocinador_id`, não pela empresa. Os testes 14 e 18 não pegaram porque montavam o usuário do jeito antigo | `20261007090000` |
| `20` | importação (jantar e evento) criava gestor a partir de linha recusada/cancelada | `20261005140000` |
| `20` | telefone fixo ganhava o 9 e virava celular inexistente | `20261005140000` |

O conserto do quarto extra mexeu em mais do que o índice: com mais de
uma reserva ativa por CIO, todo lugar que lê "a reserva do CIO" passou a
dizer qual (a principal, `origem <> 'extra'`) — `_garantir_reserva`,
`part_meu_status`, `part_listar_rooming`, `v_painel_participantes` e a
etapa de hospedagem em `v_pendencias_fatos`. O `13` cobre isso.

O marcador `ACHADO` continua valendo pra rodadas futuras: comportamento
que diverge e ainda espera decisão fica registrado, sem ser afirmado.

## O que saiu daqui

`04-fatura-complementar.sql` e `06-brindes.sql` foram removidos em
26/08: os dois afirmavam comportamento que deixou de existir — a fatura
complementar virou fatura congelada, e o brinde por quarto virou brinde
por empresa. Teste que afirma o passado é pior que teste nenhum, porque
falha por motivo errado e faz procurar defeito onde não tem. A cobertura
foi para `04-fatura-congelada.sql` e para a seção 4 do `07`.
