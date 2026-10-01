-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- webhook_contrato_assinado enfileirava o aviso "contrato_assinado" SEM
-- corpo — quem manda de verdade depois era a Edge Function
-- enviar-notificacoes (o botao "Enviar toda a fila" do admin.html), e
-- ela, sem corpo pronto, caia no texto generico ("assunto\n\nEquipe CIO
-- Cerrado") sem o link pro rooming nenhum. Achado pelo organizador em
-- 01/10/2026 testando o aviso de contrato assinado de verdade.
--
-- Mesmo commit que corrigiu integracao.py pro mesmo problema do lado
-- Python (enfileirar() la tambem passa a gravar o corpo pronto, com o
-- mesmo texto — ver CORPO["contrato_assinado"]). O texto fica igual
-- nos dois lados por enquanto por falta de uma fonte unica (SQL nao
-- importa o dict Python nem vice-versa); se um dia esse texto mudar,
-- muda nos dois lugares.
--
-- Link usa o slug do PROPRIO evento do contrato (via participantes),
-- nao um parametro — cada contrato sabe o evento certo sozinho.
-- =====================================================================

set search_path = gestao, public;

create or replace function webhook_contrato_assinado(
  p_autentique_id text, p_pdf_assinado_url text default null
) returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare
  v_contrato_id uuid;
  v_status_atual text;
  v_participante_id uuid;
  v_evento_id uuid;
  v_evento_slug text;
  v_nome text;
  v_email text;
begin
  perform _exige_staff();

  if coalesce(trim(p_autentique_id),'') = '' then
    raise exception 'autentique_id vazio' using errcode='22023';
  end if;

  select ct.id, ct.status, ct.participante_id, pa.evento_id, e.slug
    into v_contrato_id, v_status_atual, v_participante_id, v_evento_id, v_evento_slug
  from contratos ct
  join participantes pa on pa.id = ct.participante_id
  join eventos e on e.id = pa.evento_id
  where ct.autentique_id = p_autentique_id
  limit 1;

  if v_contrato_id is null then
    raise exception 'Nenhum contrato com autentique_id %', p_autentique_id
      using errcode='P0002';
  end if;

  -- ja estava assinado (reentrega do webhook, ou --status rodou antes):
  -- so completa o link do PDF se ainda nao tiver (nunca sobrescreve um
  -- link ja gravado), nao reaplica nem manda aviso de novo
  if v_status_atual = 'assinado' then
    if coalesce(trim(p_pdf_assinado_url),'') <> '' then
      update contratos set autentique_url = coalesce(autentique_url, p_pdf_assinado_url)
       where id = v_contrato_id and autentique_url is null;
    end if;
    return jsonb_build_object('ok', true, 'ja_estava_assinado', true,
                               'contrato_id', v_contrato_id);
  end if;

  update contratos set
    status = 'assinado',
    assinado_em = now(),
    autentique_url = coalesce(nullif(trim(p_pdf_assinado_url),''), autentique_url)
  where id = v_contrato_id;

  select g.nome, g.email into v_nome, v_email
  from participantes pa join gestores g on g.id = pa.gestor_id
  where pa.id = v_participante_id;

  if coalesce(trim(v_email),'') <> '' then
    insert into notificacoes (evento_id, destinatario, tipo, assunto, corpo, status)
    values (v_evento_id, v_email, 'contrato_assinado',
            'Contrato assinado — complete sua hospedagem',
            format(
              E'Olá, %s.\n\nContrato assinado, obrigado. Agora complete seus dados de hospedagem — quem vai com você e se vai usar o transfer.\n\nhttps://ciocerrado.netlify.app/gestao/rooming.html?evento=%s\n\nEquipe CIO Cerrado',
              coalesce(nullif(trim(v_nome),''), split_part(v_email,'@',1)),
              v_evento_slug),
            'enfileirada');
  end if;

  return jsonb_build_object('ok', true, 'ja_estava_assinado', false,
                             'contrato_id', v_contrato_id);
end;
$$;

revoke execute on function webhook_contrato_assinado(text, text) from public, anon, authenticated;
grant execute on function webhook_contrato_assinado(text, text) to service_role;

-- ---------------------------------------------------------------------
-- autoconfere: o grant continua certo (CREATE OR REPLACE nao devia
-- mexer nisso, mas o resto da migration ja tem esse habito por motivo
-- de seguranca, repete aqui por consistencia)
-- ---------------------------------------------------------------------
do $$
declare
  v_pode_authenticated boolean;
  v_pode_service boolean;
begin
  select has_function_privilege('authenticated', 'gestao.webhook_contrato_assinado(text,text)', 'execute')
    into v_pode_authenticated;
  select has_function_privilege('service_role', 'gestao.webhook_contrato_assinado(text,text)', 'execute')
    into v_pode_service;
  if v_pode_authenticated then
    raise exception 'webhook_contrato_assinado nao deveria ser executavel por authenticated';
  end if;
  if not v_pode_service then
    raise exception 'webhook_contrato_assinado deveria ser executavel por service_role';
  end if;

  raise notice 'webhook_contrato_assinado: grant conferido, agora grava corpo com link do rooming.';
end $$;
