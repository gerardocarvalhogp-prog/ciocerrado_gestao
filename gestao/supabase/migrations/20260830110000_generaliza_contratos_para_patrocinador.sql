-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Modulo de acompanhamento, presenca e cobranca — parte 1/4
--
-- contratos so aceitava participante_id. Contrato de patrocinio nao
-- tem hoje nenhum rastreamento — nao sabemos se passa pelo Autentique
-- como o do CIO ou por outro processo (decisao em aberto com o
-- organizador). Generalizar a tabela existente, em vez de criar uma
-- nova, deixa os dois caminhos possiveis sem re-trabalho: se acabar
-- sendo Autentique tambem, os campos ja estao la; se for outro
-- processo, o status/datas continuam validos preenchidos a mao.
-- =====================================================================

set search_path = gestao, public;

alter table contratos alter column participante_id drop not null;
alter table contratos add column if not exists patrocinador_id uuid references patrocinadores(id) on delete cascade;

alter table contratos add constraint contratos_dono_ck
  check ((participante_id is not null and patrocinador_id is null)
      or (participante_id is null and patrocinador_id is not null));

alter table contratos add constraint contratos_patrocinador_id_key unique (patrocinador_id);

comment on column contratos.patrocinador_id is
  'Contrato de patrocinio. Mutuamente exclusivo com participante_id (contratos_dono_ck) — ver modulo de acompanhamento.';
