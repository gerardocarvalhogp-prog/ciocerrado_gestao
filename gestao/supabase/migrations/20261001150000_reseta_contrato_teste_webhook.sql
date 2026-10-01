-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Terceiro reset do contrato de teste do "GERARDO CARVALHO" em
-- teste2027 — desta vez pra testar o webhook do Autentique de ponta a
-- ponta (20261001140000/20261001150000-anterior): o contrato ja estava
-- assinado dos testes anteriores (antes do webhook existir), entao
-- `--contratos` nao tinha mais nada pra enviar. Pedido do organizador
-- em 01/10/2026.
--
-- Mesma logica de 20261001090000/20261001100000 (autoconfere gestor
-- unico + contrato unico antes de mexer), agora tambem conferindo que
-- o contrato pertence a teste2027 especificamente — ja existe mais de
-- um evento de teste na base, e um merge por nome (sem filtro de
-- evento) seria arriscado se um dia o Gerardo tiver contrato em mais
-- de um evento.
-- =====================================================================

set search_path = gestao, public;

do $$
declare
  v_evento_id uuid;
  v_gestor_id uuid;
  v_qtd_gestores int;
  v_contrato_id uuid;
  v_status_atual text;
begin
  select id into v_evento_id from eventos where slug = 'teste2027';
  if v_evento_id is null then
    raise exception 'Evento "teste2027" nao encontrado';
  end if;

  select count(*) into v_qtd_gestores from gestores where nome = 'GERARDO CARVALHO';
  if v_qtd_gestores = 0 then
    raise exception 'Nenhum gestor "GERARDO CARVALHO" encontrado';
  end if;
  if v_qtd_gestores > 1 then
    raise exception '% gestores com esse nome — resolva a duplicata antes de resetar', v_qtd_gestores;
  end if;

  select id into v_gestor_id from gestores where nome = 'GERARDO CARVALHO';

  select ct.id, ct.status into v_contrato_id, v_status_atual
  from contratos ct
  join participantes pa on pa.id = ct.participante_id
  where pa.gestor_id = v_gestor_id and pa.evento_id = v_evento_id;

  if v_contrato_id is null then
    raise exception 'Nenhum contrato encontrado para esse gestor em teste2027';
  end if;

  update contratos set
    status         = 'nao_enviado',
    autentique_id  = null,
    autentique_url = null,
    enviado_em     = null,
    assinado_em    = null
  where id = v_contrato_id;

  raise notice 'contrato % resetado (status anterior: %) — rode --contratos --producao --evento teste2027 pra testar o webhook.',
    v_contrato_id, v_status_atual;
end $$;
