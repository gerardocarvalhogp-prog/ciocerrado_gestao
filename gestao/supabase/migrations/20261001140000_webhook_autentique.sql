-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- RPC que a Edge Function "autentique-webhook" chama para marcar um
-- contrato como assinado sem depender mais do polling manual
-- (integracao.py --status). Pedido do organizador em 01/10/2026, junto
-- com o pagamento da fatura — mas esse outro item ja existia pronto
-- (admin_marcar_fatura + aba Financeiro, Bloco 5.2), so a linha do
-- checklist em CLAUDE.md estava desatualizada.
--
-- POR QUE UMA FUNCAO SO PRA ISSO, EM VEZ DE REPETIR O UPDATE DIRETO NA
-- EDGE FUNCTION
--
-- Mesmo motivo de sempre no schema: a Edge Function e' estatica/externa,
-- nao da pra confiar nela sem um guard de papel, e a logica (idempotencia,
-- enfileirar aviso) tem que morrer num lugar so. Segue o MESMO padrao de
-- toda funcao administrativa: _exige_staff() na primeira linha.
--
-- COMO A EDGE FUNCTION AUTORIZA A CHAMADA
--
-- Nao existe usuario logado num webhook — quem chama e' o Autentique, sem
-- JWT nenhum. A Edge Function usa a SERVICE_ROLE_KEY (que so ela tem,
-- injetada pelo Supabase) pra chamar esta RPC. is_staff() ja reconhece
-- esse caso desde a migration 20260909210000 ("chave de servico passa por
-- admin/staff"): auth.jwt()->>'role' = 'service_role' passa no
-- _exige_staff() sem precisar de e-mail cadastrado em admins. O GRANT
-- abaixo e' mais estreito que o normal (so' service_role, nem authenticated)
-- porque nenhum humano deveria chamar isto direto — so a function.
--
-- A Edge Function e' quem decide SE o documento foi assinado de verdade
-- (reconsultando a API do Autentique com AUTENTIQUE_TOKEN, a mesma
-- consulta GraphQL que ler_status ja usa) — esta RPC confia nisso e so
-- aplica o estado. Design deliberado: o payload que o Autentique manda no
-- POST do webhook nao e' tratado como fonte de verdade (formato nao
-- confirmado, assinatura do webhook nao verificada), so' como aviso pra
-- ir reconferir na API autenticada.
--
-- Idempotente: reentrega do webhook (ou um signatario assinando por vez,
-- com testemunha/parte fixos desde 20261001?) nao duplica o aviso nem
-- regrava assinado_em — so a PRIMEIRA vez que o contrato vira assinado
-- dispara a notificacao.
-- =====================================================================

set search_path = gestao, public;

create or replace function webhook_contrato_assinado(p_autentique_id text)
returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare
  v_contrato_id uuid;
  v_status_atual text;
  v_participante_id uuid;
  v_evento_id uuid;
  v_email text;
begin
  perform _exige_staff();

  if coalesce(trim(p_autentique_id),'') = '' then
    raise exception 'autentique_id vazio' using errcode='22023';
  end if;

  select ct.id, ct.status, ct.participante_id, pa.evento_id
    into v_contrato_id, v_status_atual, v_participante_id, v_evento_id
  from contratos ct
  join participantes pa on pa.id = ct.participante_id
  where ct.autentique_id = p_autentique_id
  limit 1;

  if v_contrato_id is null then
    raise exception 'Nenhum contrato com autentique_id %', p_autentique_id
      using errcode='P0002';
  end if;

  -- ja estava assinado (reentrega do webhook, ou --status rodou antes):
  -- nao reaplica nem manda aviso de novo
  if v_status_atual = 'assinado' then
    return jsonb_build_object('ok', true, 'ja_estava_assinado', true,
                               'contrato_id', v_contrato_id);
  end if;

  update contratos set status = 'assinado', assinado_em = now()
   where id = v_contrato_id;

  select g.email into v_email
  from participantes pa join gestores g on g.id = pa.gestor_id
  where pa.id = v_participante_id;

  if coalesce(trim(v_email),'') <> '' then
    insert into notificacoes (evento_id, destinatario, tipo, assunto, status)
    values (v_evento_id, v_email, 'contrato_assinado',
            'Contrato assinado — complete sua hospedagem', 'enfileirada');
  end if;

  return jsonb_build_object('ok', true, 'ja_estava_assinado', false,
                             'contrato_id', v_contrato_id);
end;
$$;

revoke execute on function webhook_contrato_assinado(text) from public, anon, authenticated;
grant execute on function webhook_contrato_assinado(text) to service_role;

-- ---------------------------------------------------------------------
-- autoconfere: a funcao existe e so' service_role pode executar
-- ---------------------------------------------------------------------
do $$
declare
  v_pode_authenticated boolean;
  v_pode_service boolean;
begin
  select has_function_privilege('authenticated', 'gestao.webhook_contrato_assinado(text)', 'execute')
    into v_pode_authenticated;
  select has_function_privilege('service_role', 'gestao.webhook_contrato_assinado(text)', 'execute')
    into v_pode_service;

  if v_pode_authenticated then
    raise exception 'webhook_contrato_assinado nao deveria ser executavel por authenticated';
  end if;
  if not v_pode_service then
    raise exception 'webhook_contrato_assinado deveria ser executavel por service_role';
  end if;

  raise notice 'webhook_contrato_assinado: grant conferido (so service_role).';
end $$;
