-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Quarto reset do contrato de teste do "GERARDO CARVALHO" em
-- teste2027 — o teste anterior do webhook (20261001150000) esbarrou
-- num 401 do proprio gateway do Supabase (verify_jwt bloqueando antes
-- do codigo da function rodar, corrigido em supabase/config.toml no
-- mesmo commit desta migration). Reenviando pra testar de novo, agora
-- com o gateway liberado. Pedido do organizador em 01/10/2026.
--
-- Mesma logica das tres anteriores (autoconfere gestor e contrato
-- unicos em teste2027 antes de mexer).
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

  raise notice 'contrato % resetado (status anterior: %) — rode --contratos --producao --evento teste2027 de novo.',
    v_contrato_id, v_status_atual;
end $$;
