-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- schema-extra.sql  ·  as colunas que a cadeia usa e ninguem cria
--
-- Roda DEPOIS de schema.sql e ANTES de funcoes-base-helpers.sql.
-- Seguro de rodar mais de uma vez.
--
-- POR QUE E TAO CURTO
--
-- Quase tudo que as telas pedem alem do schema.sql ja entra pela cadeia
-- migracao-02..06 (cota_unica, composicao de quartos via cota_quartos,
-- site/resumo/natureza do patrocinador, faixa de idade nos precos,
-- rotulo do convidado, investimentos da pesquisa, pessoa_key do
-- check-in). Repetir aquilo aqui so criaria duas fontes para a mesma
-- coluna.
--
-- Sobram DUAS colunas que a cadeia LE mas nunca CRIA - e por isso ela
-- nao roda sozinha hoje:
--
--   sessoes.passou_em     · lido por correcoes-01.sql (patro_minhas_sessoes)
--   checkins.desfeito_em  · lido por migracao-05.sql em quatro consultas
--
-- Sem elas, os arquivos ate sao criados, mas a primeira chamada quebra
-- com "column does not exist".
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- SESSOES · passar a vez
--
-- "Passar a vez" e "encerrar" fecham a sessao, mas so o primeiro
-- devolve as vagas para a fila. correcoes-01.sql ja trata os dois casos
-- como estados diferentes (encerrada = encerrou OU passou; passou = so
-- passou) - falta a coluna que sustenta a distincao.
-- ---------------------------------------------------------------------
alter table sessoes add column if not exists passou_em timestamptz;

-- ---------------------------------------------------------------------
-- CHECKINS · desfazer sem apagar
--
-- Check-in desfeito nao sai da tabela: ganha data. Os relatorios ja
-- filtram por desfeito_em is null; a auditoria mantem a linha. Apagar
-- esconderia o erro de operacao que a organizacao precisa enxergar
-- depois do evento.
--
-- desfeito_por responde "quem desfez", que e a pergunta seguinte
-- sempre que um check-in some do placar.
-- ---------------------------------------------------------------------
alter table checkins add column if not exists desfeito_em  timestamptz;
alter table checkins add column if not exists desfeito_por text;

-- Mesmo ocupante nao pode ter dois check-ins valendo ao mesmo tempo.
-- Parcial de proposito: o desfeito sai do indice e a pessoa pode fazer
-- check-in de novo depois de uma correcao.
create unique index if not exists checkins_ocupante_ativo_uk
  on checkins(ocupante_id)
  where desfeito_em is null and ocupante_id is not null;
