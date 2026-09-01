# Jantares — `jantares.html`

Jantares e eventos menores. Ciclo curto, com etapas próprias. **Não usa
`?evento=` na URL** — jantar é entidade própria, independente de evento
grande (ver abaixo).

Tela **só de staff/admin** — confirmado: as 20 funções `jantar_*` exigem
`_exige_staff()` ou `_exige_admin()` na primeira linha, sem exceção. O
patrocinador de um jantar não tem login nem acesso ao portal para
acompanhá-lo; tudo é operado pela equipe.

Três abas: **Agenda**, **Sondagem**, **Estatísticas**.

---

## Modelo

Jantar tem entidade própria (tabela `jantares`), **sem `evento_id`** — não é
uma linha na mesma tabela do evento grande. `patrocinador_nome` é texto livre,
não uma referência a `patrocinadores` — um jantar não exige que a empresa já
esteja cadastrada como patrocinadora de nenhum evento.

Cada jantar tem um patrocinador. A organização escolhe quem senta à mesa.

A curadoria da lista é a atividade central. Ela cruza a base de cadastro do
CIO Cerrado com o perfil comercial do patrocinador, calcula aderência e
seleciona os executivos — via `jantar_base` (monta o universo de candidatos) e
IA (`ia` Edge Function, chamada a partir da tela) para pontuar aderência.

O processo de curadoria tem procedimento próprio, documentado à parte (skill
`jantares-cio-cerrado`). Não é reconstruído aqui.

---

## Aba Agenda

### Lista de jantares
`jantar_listar` — todos os jantares (não filtrado por evento, já que jantar
não pertence a evento). Ação para criar (`jantar_salvar`), cancelar
(`jantar_cancelar`) e remover (`jantar_remover`) um jantar da agenda.

### Ficha do jantar (`jantar_obter`)

**Dados do jantar:** patrocinador, data, horário, local, capacidade, link do
Sympla de inscrição (`jantares.sympla_url`) — editável, salva por
`jantar_salvar`.

**Importar convidados do Sympla:** upload de planilha exportada do Sympla,
processada por `jantar_importar_convidados_sympla` — cria/atualiza
`jantar_convidados` a partir de quem se inscreveu pelo link Sympla do jantar.

**Buscar no cadastro:** busca livre com filtro (perfil, segmento, cidade, UF,
posição, com/sem e-mail) sobre a base inteira de `gestores`
(`admin_listar_gestores` / `admin_filtros_gestores`), seleção múltipla, e
adiciona direto ao jantar (`jantar_adicionar_convidados_existentes`) — o
caminho para quando já se sabe quem chamar, sem depender da IA.

**Sugerir convidados por aderência (IA):** roda a análise de aderência
(`jantar_base` monta o universo, a Edge Function `ia` pontua) e permite
selecionar quem entra (`jantar_salvar_selecao`).

**Adicionar quem não passou pela análise:** cadastro avulso e imediato de
alguém fora da base — equipe própria, convidado de última hora
(`jantar_avulso`).

### Lista de convidados (`jantar_convidados_listar`)

Cada convidado tem `status`: `sugerido → convidado → confirmado → compareceu`,
ou `recusado`. Ação para marcar mudança de status
(`jantar_marcar_convidado`) e remover convidado (`jantar_remover_convidado`).

Ações da lista:
- **Etiquetas**: exporta crachá dos convidados ativos.
- **Exportar mailing**: pergunta "só quem compareceu" ou "todos", se já houver
  algum check-in registrado; inclui segmento, cidade, UF e telefone formatado
  (`(DD) 9NNNN-NNNN`).
- **Abrir check-in**: link para `checkin.html?jantar=<id>`, escopado a este
  jantar (ver `40-checkin.md`).

---

## Aba Sondagem

Prospecção avulsa **sem criar o jantar** — mesma análise de aderência
(`jantar_base` com jantar nulo, IA pontua a base inteira), usada para levar
número numa conversa comercial antes de fechar. Não grava convidado; se o
jantar acontecer de fato, ele é criado na Agenda e a seleção refeita lá, com
capacidade real.

---

## Aba Estatísticas

Quatro blocos, todos sobre `jantar_convidados`, com a equipe do CIO Cerrado
(`perfil='CIO CERRADO'`) excluída dos rankings — ela comparece aos próprios
eventos que organiza, o que distorceria a leitura de "quem é convidado com
frequência":

- **Panorama**: total de jantares, pessoas já convidadas, convites emitidos,
  taxa geral de confirmação.
- **Convidados sempre, confirmam nunca**: 3+ convites, zero confirmações.
- **Confirmaram e não apareceram**: confirmou presença, o jantar já aconteceu
  (`jantares.data < hoje`), o check-in nunca marcou `compareceu`.
- **Quem é chamado com mais frequência**: ranking bruto de convites, com taxa
  de confirmação ao lado.

A aba tem histórico curto por enquanto: em produção, 3 jantares e 66 registros
de convidado. Uma análise em cima da planilha antiga de convites (44 jantares
históricos, fora deste sistema) encontrou os mesmos três padrões em escala —
ver artifact do relatório enviado ao organizador em 2026-08-31; esses dados
históricos **não foram importados** para dentro do schema `gestao`.

---

## O que não se aplica

Jantar não tem rooming, transfer, acompanhante, filho nem mesa redonda. Essas
etapas não existem para `jantares` — a tabela nem tem `evento_id` para se
ligar a `reservas`, `sessoes` ou `faturas`.

---

## Regra crítica: o que o patrocinador recebe (a confirmar o estado atual)

O rascunho descreve uma etapa de "validação com o patrocinador" usando lista
sem nome de executivo (só empresa, segmento, cidade, estado, aderência). **Não
encontrei essa etapa como tela ou export dedicado em `jantares.html`** — a
tela de staff mostra nome de convidado normalmente em toda lista (Buscar no
cadastro, Sugerir por IA, lista de convidados). Se essa validação acontece
hoje, é **fora do sistema** (planilha, e-mail, ou pela skill
`jantares-cio-cerrado`, que roda fora desta tela) — não há como confirmar
pelo código. Ver `PERGUNTAS.md`.

---

## Perguntas do rascunho, respondidas pelo código

- **O jantar é cadastrado como um "evento" da mesma tabela do evento grande,
  ou tem entidade própria?** Entidade própria — `jantares`, sem `evento_id`.
- **Um executivo pode ser convidado para dois jantares diferentes? Há trava?**
  Não há trava, por desenho — o próprio bloco de Estatísticas existe para
  medir e mostrar quem está sendo repetido.
- **O patrocinador do jantar tem acesso ao portal, ou o jantar é operado só
  pelo admin?** Operado só por staff/admin — as 20 funções `jantar_*` exigem
  `_exige_staff`/`_exige_admin`; nenhuma é acessível a patrocinador.
- **Existe registro de quem foi convidado e não compareceu, para uso em
  curadorias futuras?** Sim, dentro do sistema atual (aba Estatísticas). Do
  histórico de 44 jantares anteriores ao sistema, existe só como relatório
  avulso, não importado.

## A confirmar com o organizador

- A etapa de "validação com o patrocinador" (lista sem nome de executivo):
  ainda existe no processo? Se sim, por qual caminho, já que não está em
  `jantares.html`?
- A confirmação de presença do convidado é por link, e-mail ou Sympla? O
  campo `sympla_url` existe por jantar, mas não achei o texto/canal de convite
  em si no código lido nesta passagem.
- Vale importar o histórico de 44 jantares da planilha para dentro do schema
  `gestao`, para a aba Estatísticas enxergar o padrão completo? (decisão
  represada — ver conversa de 2026-08-31, envolve casar ~900 pessoas contra o
  cadastro).
