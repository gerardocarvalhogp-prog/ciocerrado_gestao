-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Convite com link do Sympla e fila de e-mail pronta para envio.
--
-- O QUE JA FUNCIONAVA (conferido antes de escrever)
--
-- A segunda metade do pedido — "apos confirmacao, alem do fluxo normal
-- inserir no cadastro geral" — ja acontece: admin_converter_indicacao
-- cria o gestor quando a indicacao vira inscricao. Nao mexi nisso.
--
-- O QUE FALTAVA
--
-- 1. Onde guardar o link. eventos so tinha sympla_event_id, que e o id
--    interno, nao um endereco que da para colar num e-mail.
--
-- 2. O que mandar. notificacoes guardava evento/destinatario/tipo/
--    assunto — nenhum corpo. Quem fosse enviar teria que adivinhar o
--    texto a partir do tipo.
--
-- 3. Quem manda. NAO EXISTE remetente no sistema: a fila enche
--    (status 'enfileirada') e nada nunca sai. A unica Edge Function e
--    a de IA. Esta migration prepara os dados; o envio em si vive em
--    supabase/functions/enviar-notificacoes, que precisa da chave do
--    Resend configurada como secret — sem ela a funcao recusa a rodar
--    em vez de fingir que enviou.
--
-- DECISAO
--
-- O convite so e enfileirado quando ha link do Sympla no evento.
-- Enfileirar um convite sem link produziria um e-mail dizendo
-- "inscreva-se" sem dizer onde — pior que nao mandar.
-- =====================================================================

set search_path = gestao, public;

ALTER TABLE "gestao"."eventos"       ADD COLUMN IF NOT EXISTS "sympla_url" "text";
ALTER TABLE "gestao"."notificacoes"  ADD COLUMN IF NOT EXISTS "corpo" "text";
ALTER TABLE "gestao"."notificacoes"  ADD COLUMN IF NOT EXISTS "tentativas" integer NOT NULL DEFAULT 0;


-- Aprovar participante passa a enfileirar tambem o convite com o link,
-- quando o evento tem um. O aviso de "inscricao aprovada" continua
-- como estava.
CREATE OR REPLACE FUNCTION "gestao"."admin_aprovar_participante"(
  "p_participante_id" "uuid", "p_aprovado" boolean DEFAULT true
) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid; v_email text; v_nome text;
  v_sympla text; v_evento_nome text;
begin
  perform _exige_admin();

  select pa.evento_id, g.email, g.nome, e.sympla_url, e.nome
    into v_evento, v_email, v_nome, v_sympla, v_evento_nome
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  join eventos  e on e.id = pa.evento_id
  where pa.id = p_participante_id;

  if v_evento is null then
    raise exception 'Participante nao encontrado' using errcode='P0002';
  end if;

  -- aprovado_em = now() mesmo quando recusa: e o comportamento que ja
  -- existia. Parece errado (carimbo de "aprovado em" numa recusa), mas
  -- mudar aqui seria alteracao nao pedida, e relatorio que filtre por
  -- esse campo mudaria de resultado sem aviso. Fica registrado.
  update participantes set
    status      = case when p_aprovado then 'aprovado' else 'recusado' end,
    aprovado_em = now(),
    aprovado_por = auth.jwt() ->> 'email'
  where id = p_participante_id;

  if p_aprovado then
    insert into contratos (participante_id, status)
    values (p_participante_id, 'nao_enviado')
    on conflict (participante_id) do nothing;

    insert into notificacoes (evento_id, destinatario, tipo, assunto)
    values (v_evento, v_email, 'inscricao_aprovada', 'Inscricao aprovada');

    -- convite so faz sentido com link: sem ele o e-mail mandaria a
    -- pessoa se inscrever sem dizer onde
    if coalesce(trim(v_sympla),'') <> '' then
      insert into notificacoes (evento_id, destinatario, tipo, assunto, corpo)
      values (v_evento, v_email, 'convite_evento',
              'Seu convite para o ' || coalesce(v_evento_nome, 'CIO Cerrado'),
              'Ola, ' || coalesce(v_nome,'') || E'!\n\n' ||
              'Sua participacao no ' || coalesce(v_evento_nome,'evento') ||
              ' foi aprovada. Garanta sua vaga pela inscricao oficial:' || E'\n\n' ||
              v_sympla || E'\n\n' ||
              'Ate la!' || E'\nEquipe CIO Cerrado');
    end if;
  end if;

  return jsonb_build_object('ok', true, 'convite_enfileirado',
                            p_aprovado and coalesce(trim(v_sympla),'') <> '');
end;
$$;


-- A Edge Function le por aqui em vez de tocar a tabela direto: mantem
-- o padrao do schema (nenhum papel le tabela) e ja marca as tentativas.
CREATE OR REPLACE FUNCTION "gestao"."notificacoes_pendentes"("p_limite" integer DEFAULT 50)
RETURNS TABLE("id" "uuid", "destinatario" "text", "assunto" "text", "corpo" "text", "tipo" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select n.id, n.destinatario, n.assunto, n.corpo, n.tipo
    from notificacoes n
    where n.status = 'enfileirada'
      and n.tentativas < 3       -- nao insiste para sempre num endereco morto
      and coalesce(trim(n.destinatario),'') <> ''
    order by n.created_at
    limit p_limite;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."notificacoes_pendentes"(integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."notificacoes_pendentes"(integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."notificacoes_pendentes"(integer) TO "service_role";


CREATE OR REPLACE FUNCTION "gestao"."notificacao_marcar"(
  "p_id" "uuid", "p_ok" boolean, "p_erro" "text" DEFAULT NULL
) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  update notificacoes set
    status     = case when p_ok then 'enviada' else 'erro' end,
    enviada_em = case when p_ok then now() else enviada_em end,
    erro       = case when p_ok then null else left(coalesce(p_erro,'falha'), 500) end,
    tentativas = tentativas + 1
  where id = p_id;
  if not found then
    raise exception 'Notificacao nao encontrada' using errcode='P0002';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."notificacao_marcar"("uuid",boolean,"text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."notificacao_marcar"("uuid",boolean,"text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."notificacao_marcar"("uuid",boolean,"text") TO "service_role";


-- Resumo para a tela saber o que esta parado na fila.
CREATE OR REPLACE FUNCTION "gestao"."admin_notificacoes_resumo"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v jsonb;
begin
  perform _exige_staff();
  select jsonb_build_object(
    'enfileiradas', count(*) filter (where status='enfileirada'),
    'enviadas',     count(*) filter (where status='enviada'),
    'com_erro',     count(*) filter (where status='erro')
  ) into v from notificacoes;
  return v;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_notificacoes_resumo"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_notificacoes_resumo"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_notificacoes_resumo"() TO "service_role";
