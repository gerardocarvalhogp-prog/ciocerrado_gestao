-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Permite disparar UMA notificacao, em vez da fila inteira.
--
-- POR QUE
--
-- notificacoes_pendentes devolvia sempre o lote todo. Isso torna
-- impossivel duas coisas legitimas:
--
--   - testar o envio sem despejar a fila acumulada em cima de gente
--     real (o caso concreto: 7 avisos represados desde que o sistema
--     subiu, de fatos de semanas atras, que ninguem decidiu ainda se
--     devem sair);
--   - reenviar uma mensagem especifica que falhou, sem re-disparar as
--     que ja deram certo.
--
-- p_id opcional resolve os dois. Sem ele, o comportamento e o mesmo de
-- antes.
--
-- Quando p_id vem preenchido, o filtro de tentativas nao se aplica: e
-- uma acao deliberada de alguem olhando aquela mensagem, nao o
-- processamento automatico que precisa desistir depois de 3 falhas.
-- =====================================================================

set search_path = gestao, public;

DROP FUNCTION IF EXISTS "gestao"."notificacoes_pendentes"(integer);

CREATE FUNCTION "gestao"."notificacoes_pendentes"(
  "p_limite" integer DEFAULT 50,
  "p_id" "uuid" DEFAULT NULL
) RETURNS TABLE("id" "uuid", "destinatario" "text", "assunto" "text", "corpo" "text", "tipo" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select n.id, n.destinatario, n.assunto, n.corpo, n.tipo
    from notificacoes n
    where n.status = 'enfileirada'
      and coalesce(trim(n.destinatario),'') <> ''
      and (p_id is null or n.id = p_id)
      -- desistir depois de 3 falhas vale para o processamento em lote;
      -- um reenvio pedido a mao e decisao de quem esta olhando
      and (p_id is not null or n.tentativas < 3)
    order by n.created_at
    limit case when p_id is not null then 1 else p_limite end;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."notificacoes_pendentes"(integer,"uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."notificacoes_pendentes"(integer,"uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."notificacoes_pendentes"(integer,"uuid") TO "service_role";


-- Enfileira uma mensagem de teste para o proprio solicitante. Serve
-- para provar a configuracao (chave, dominio, remetente) sem tocar em
-- nada que va para outra pessoa.
CREATE OR REPLACE FUNCTION "gestao"."admin_notificacao_teste"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_email text; v_id uuid;
begin
  perform _exige_staff();

  v_email := auth.jwt() ->> 'email';
  if coalesce(trim(v_email),'') = '' then
    raise exception 'Sem e-mail no token' using errcode='22023';
  end if;

  insert into notificacoes (destinatario, tipo, assunto, corpo, status)
  values (v_email, 'teste',
          'Teste de envio — CIO Cerrado',
          'Se voce esta lendo isto, o envio de e-mail do sistema esta' || E'\n' ||
          'funcionando: chave do Resend valida, dominio aceito e' || E'\n' ||
          'remetente configurado.' || E'\n\n' ||
          'Disparado em ' || to_char(now(), 'DD/MM/YYYY HH24:MI') || '.',
          'enfileirada')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'destinatario', v_email);
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_notificacao_teste"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_notificacao_teste"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_notificacao_teste"() TO "service_role";
