-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Contrato assinado pros 4 CIOs de teste da equipe — sem isso a etapa
-- de hospedagem (rooming.html) fica bloqueada, e o teste da persona
-- CIO nao chega nem na parte mais importante. Esqueci na migration
-- 20260831100000, corrigido aqui. Idempotente por participante_id
-- (unique ja existente em contratos).
-- =====================================================================

set search_path = gestao, public;

insert into contratos (participante_id, status, enviado_em, assinado_em)
select pa.id, 'assinado', now(), now()
from participantes pa
join gestores g on g.id = pa.gestor_id
where g.email in (
  'tacio.henrique+cio@ciocerrado.com.br',
  'kelson.duarte+cio@ciocerrado.com.br',
  'amarildo.moraes+cio@ciocerrado.com.br',
  'comunicacao+cio@ciocerrado.com.br'
)
on conflict (participante_id) do update
  set status = 'assinado', assinado_em = coalesce(contratos.assinado_em, now());
