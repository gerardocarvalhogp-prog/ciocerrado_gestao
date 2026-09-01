# Changelog

Uma linha por mudança de comportamento do sistema, com data. Mudança que não
altera comportamento (refactor, ajuste de estilo, cor de marca, quebra de
layout no mobile) não entra — ficou de fora deliberadamente, mesmo constando
no histórico do git.

Formato: `AAAA-MM-DD — o que mudou — arquivo de documentação afetado`

Minerado do `git log` do repositório em 2026-09-01. Datas anteriores a
2026-08-24 não têm histórico de commit (sistema convertido de scripts soltos
para migrations nessa data) — o que se sabe do período anterior está descrito
nos arquivos de área, não aqui.

---

## 2026-09

- 2026-09-01 — Documentação funcional instalada em `docs/` e conferida
  contra o código-fonte e o banco hospedado — todos os arquivos
- 2026-09-01 — Estatística de convite de jantar (quem nunca confirma, quem
  confirma e falta, frequência) sai de relatório avulso e vira aba ao vivo —
  `50-jantares.md`

## 2026-08-31

- 2026-08-31 — Padrão de formatação obrigatório no cadastro: nome, empresa,
  cargo e cidade em caixa alta; estado validado contra as 27 UFs — aplicado
  via trigger, cobre todo caminho de escrita (integração e manual) —
  `70-modelo-de-dados.md`
- 2026-08-31 — Staff só vê o evento ao qual está associado; admin continua
  vendo todos — `70-modelo-de-dados.md`, `10-admin.md`
- 2026-08-31 — Correção de auditoria de segurança: achado crítico (integração
  com o app do evento não exigia admin) + 3 achados médios — `80-integracoes.md`
- 2026-08-31 — Quarto de equipe/staff passa a existir fora da cota de
  qualquer patrocinador (aba Organização) — `10-admin.md`

## 2026-08-30

- 2026-08-30 — Módulo de acompanhamento de pendências (fase 2): resumo por
  etapa, prazo configurável, preparo de cobrança com confirmação humana —
  `10-admin.md`, `60-modulos-previstos.md`
- 2026-08-30 — Módulo de presença (fase 3): atividades, check-in por QR code,
  base para envio por WhatsApp — `40-checkin.md`, `10-admin.md`,
  `60-modulos-previstos.md`
- 2026-08-30 — Integração com o app do evento, Cenário A: geração da planilha
  no formato exato do parceiro, com de-para de ID — `80-integracoes.md`,
  `60-modulos-previstos.md`

## 2026-08-29

- 2026-08-29 — Data de nascimento validada contra a data do evento, não a
  data de hoje — `30-area-cio.md`
- 2026-08-29 — Importação de convidados de jantar direto do Sympla —
  `50-jantares.md`

## 2026-08-28

- 2026-08-28 — Segmento de negócio vira lista fechada (27 valores livres
  reduzidos a 14 canônicos); multi-filtro no cadastro de gestores e empresas
  — `70-modelo-de-dados.md`, `10-admin.md`
- 2026-08-28 — Fusão de cadastros duplicados e vínculo automático
  gestor-empresa — `70-modelo-de-dados.md`
- 2026-08-28 — Vencimento passa a ser obrigatório para emitir fatura; número
  do lounge no cadastro do patrocinador — `10-admin.md`, `20-portal-patrocinador.md`
- 2026-08-28 — Importação dos inscritos do Sympla como confirmados
  (aparecem no check-in) — `40-checkin.md`, `80-integracoes.md`
- 2026-08-28 — Cancelamento de jantar; link de inscrição do Sympla por
  jantar — `50-jantares.md`
- 2026-08-28 — Resumo de pendências no portal do patrocinador —
  `20-portal-patrocinador.md`

## 2026-08-26

- 2026-08-26 — Cortesia de um acompanhante adulto e teto de quatro pessoas
  por quarto — `30-area-cio.md`
- 2026-08-26 — Transfer passa a ser por pessoa, cada ocupante do quarto pode
  sair de origem diferente — `30-area-cio.md`
- 2026-08-26 — Brinde é da empresa, não do quarto — pode gerar custo se
  entregue no quarto do convidado — `20-portal-patrocinador.md`
- 2026-08-26 — Valor do quarto adicional mostrado antes da confirmação de
  reserva — `20-portal-patrocinador.md`
- 2026-08-26 — Login por senha passa a existir nas cinco telas, como
  alternativa ao magic link — `80-integracoes.md`

## 2026-08-25

- 2026-08-25 — Acesso direto a tabela fechado também para `authenticated`
  (só `SECURITY DEFINER` a partir daqui) — `70-modelo-de-dados.md`
- 2026-08-25 — Rastreio do brinde, da promessa até a entrega no quarto —
  `20-portal-patrocinador.md`
- 2026-08-25 — Escolha manual de convidado em jantares; check-in vinculado a
  um jantar específico — `50-jantares.md`, `40-checkin.md`

## 2026-08-24

- 2026-08-24 — Indicação de CIO no perfil do patrocinador vira reserva com
  janela de tempo, não indicação permanente — `20-portal-patrocinador.md`
- 2026-08-24 — Fatura complementar cobra só a diferença quando a anterior já
  foi paga — `30-area-cio.md`
- 2026-08-24 — Aba Financeiro do admin implementada — `10-admin.md`
- 2026-08-24 — Vazamento de view para o papel `anon` fechado — `70-modelo-de-dados.md`

---

## Antes de 2026-08-24

Sistema rodava como scripts avulsos e planilhas antes de virar migrations
versionadas — sem histórico de commit rastreável. O que se sabe do período
está descrito nos arquivos de área, não aqui.
