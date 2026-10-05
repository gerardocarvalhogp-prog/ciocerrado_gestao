-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- admin_preparar_cobranca ganha o escopo de staff por evento.
--
-- Sobra da varredura de 05/10/2026 (20261005110000 fechou as funcoes
-- com p_evento_slug; esta recebe sujeito_id + etapa, entao a varredura
-- do teste 23 nao a pegava). Staff de OUTRO evento montava a cobranca
-- de um CIO/patrocinador deste — e a previa devolve destinatario,
-- assunto e corpo, ou seja, o e-mail de quem esta pendente. O evento
-- vem da propria linha de v_pendencias; _exige_staff() continua na
-- primeira linha e admin segue passando.
-- =====================================================================

set search_path = gestao, public;

CREATE OR REPLACE FUNCTION gestao.admin_preparar_cobranca(p_sujeito_id uuid, p_etapa_chave text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare
  v_row record;
  v_destinatarios text[];
  v_assunto text;
  v_corpo text;
  v_ultimo timestamptz;
begin
  perform _exige_staff();

  select * into v_row from v_pendencias
   where sujeito_id = p_sujeito_id and etapa_chave = p_etapa_chave
   limit 1;
  if v_row is null then
    raise exception 'Pendência não encontrada' using errcode = 'P0002';
  end if;
  perform _exige_staff_do_evento(v_row.evento_id);
  if v_row.status = 'concluida' then
    raise exception 'Essa etapa já foi concluída — não há pendência para cobrar'
      using errcode = '55000';
  end if;

  if v_row.publico = 'participante' then
    v_destinatarios := array[v_row.destinatario_email];
  else
    select array_agg(up.email) into v_destinatarios
    from usuarios_patrocinador up
    where up.patrocinador_id = v_row.sujeito_id and up.ativo;
  end if;

  select max(n.created_at) into v_ultimo
  from notificacoes n
  where n.tipo = 'cobranca_' || p_etapa_chave
    and n.destinatario = any(coalesce(v_destinatarios, array[]::text[]))
    and n.created_at > now() - interval '3 days';

  v_assunto := 'CIO Cerrado — ' || v_row.etapa_rotulo;
  v_corpo := case v_row.etapa_chave
    when 'contrato_assinado' then
      'Olá! Notamos que o contrato ainda não foi assinado. Pode verificar quando tiver um momento?'
    when 'hospedagem_preenchida' then
      'Olá! Os dados de hospedagem ainda não foram preenchidos. O prazo está próximo — pode completar quando puder?'
    when 'fatura_paga' then
      'Olá! Há uma fatura em aberto. Qualquer dúvida sobre o valor, é só responder este e-mail.'
    when 'presenca_confirmada' then
      'Olá! Ainda não temos sua confirmação de presença. Pode confirmar quando puder?'
    when 'contrato_patrocinio_assinado' then
      'Olá! O contrato de patrocínio ainda não foi assinado. Pode verificar quando tiver um momento?'
    when 'indicacao_cio_feita' then
      'Olá! Ainda não recebemos indicações de CIOs da sua empresa para este evento.'
    when 'quartos_preenchidos' then
      'Olá! Os ocupantes dos quartos da cota ainda não foram todos preenchidos.'
    when 'convidados_mesa_escolhidos' then
      'Olá! Os convidados de mesa redonda ainda não foram escolhidos.'
    when 'convidados_jantar_escolhidos' then
      'Olá! Os convidados de jantar ainda não foram escolhidos.'
    when 'brindes_definidos' then
      'Olá! Ainda não recebemos a definição de brindes da sua empresa.'
    when 'arquivos_enviados' then
      'Olá! Ainda faltam arquivos da sua cota (logo, banner, arte de revista, apresentação ou vídeo, conforme o pacote). Pode enviar pelo portal quando puder?'
    else 'Olá! Notamos uma pendência: ' || v_row.etapa_rotulo || '.'
  end;

  return jsonb_build_object(
    'destinatarios', to_jsonb(coalesce(v_destinatarios, array[]::text[])),
    'assunto', v_assunto,
    'corpo', v_corpo,
    'dias_em_aberto', v_row.dias_em_aberto,
    'ja_enviado_recentemente', v_ultimo is not null,
    'ultimo_envio', v_ultimo
  );
end;
$function$;
