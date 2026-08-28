-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Cancelar jantar que nao aconteceu, e guardar o link do Sympla.
--
-- 1. CANCELAR != REMOVER
--
-- jantar_remover bloqueia quando ha convidado confirmado, e esta certo:
-- apagar a linha joga fora o historico de quem foi convidado, e esse
-- historico e o que alimenta "quem ja foi convidado antes" na
-- prospeccao e nas estatisticas.
--
-- Mas isso deixava um buraco: jantar planejado, convidados
-- confirmados, e o jantar nao aconteceu. Nao dava para remover (a
-- trava, corretamente, impedia) e cancelar exigia abrir o jantar,
-- trocar o status no seletor e salvar. Na pratica esses jantares
-- ficavam "planejado" para sempre, sujando a agenda e contando como
-- vaga ocupada.
--
-- jantar_cancelar resolve pelo caminho certo: marca cancelado,
-- preserva tudo, e sai da contagem de ativos. So recusa jantar ja
-- realizado — esse aconteceu, cancelar seria reescrever historia.
--
-- 2. LINK DO SYMPLA
--
-- A tabela jantares nao tinha nenhum campo de inscricao. O link do
-- evento no Sympla e o que a organizacao manda para o convidado se
-- inscrever — sem lugar para guardar, ele vivia no WhatsApp de quem
-- organizou aquele jantar especifico.
-- =====================================================================

set search_path = gestao, public;

ALTER TABLE "gestao"."jantares" ADD COLUMN IF NOT EXISTS "sympla_url" "text";


CREATE OR REPLACE FUNCTION "gestao"."jantar_cancelar"("p_id" "uuid", "p_motivo" "text" DEFAULT NULL)
RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_status text; v_obs text;
begin
  perform _exige_admin();

  select status, observacoes into v_status, v_obs from jantares where id = p_id;
  if v_status is null then
    raise exception 'Jantar nao encontrado' using errcode='P0002';
  end if;
  if v_status = 'realizado' then
    raise exception 'Este jantar consta como realizado — cancelar apagaria um fato'
      using errcode='22023';
  end if;
  if v_status = 'cancelado' then
    return jsonb_build_object('ok', true, 'ja_estava', true);
  end if;

  update jantares set
    status = 'cancelado',
    -- o motivo vai para observacoes com data: daqui a seis meses
    -- ninguem lembra por que aquele jantar caiu
    observacoes = case when coalesce(trim(p_motivo),'') = '' then v_obs
                       else trim(coalesce(v_obs || E'\n', '')) ||
                            '[cancelado em ' || to_char(now(),'DD/MM/YYYY') || '] ' || trim(p_motivo)
                  end
  where id = p_id;

  return jsonb_build_object('ok', true, 'ja_estava', false);
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."jantar_cancelar"("uuid","text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_cancelar"("uuid","text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_cancelar"("uuid","text") TO "service_role";


-- jantar_salvar ganha o sympla_url.
--
-- DROP obrigatorio antes: parametro novo muda a assinatura, e
-- CREATE OR REPLACE criaria uma SEGUNDA funcao em vez de substituir a
-- primeira. Com duas assinaturas o PostgREST recusa a chamada inteira
-- ("could not choose the best candidate function"), e a tela quebra
-- sem erro no SQL.
DROP FUNCTION IF EXISTS "gestao"."jantar_salvar"(
  "text","uuid","date",time without time zone,"text","text","text","text","text",integer,"text");

CREATE OR REPLACE FUNCTION "gestao"."jantar_salvar"(
  "p_patrocinador_nome" "text",
  "p_id" "uuid" DEFAULT NULL::"uuid",
  "p_data" "date" DEFAULT NULL::"date",
  "p_horario" time without time zone DEFAULT NULL::time without time zone,
  "p_local" "text" DEFAULT NULL::"text",
  "p_patrocinador_site" "text" DEFAULT NULL::"text",
  "p_perfil_convidado" "text" DEFAULT NULL::"text",
  "p_observacoes" "text" DEFAULT NULL::"text",
  "p_abrangencia" "text" DEFAULT NULL::"text",
  "p_capacidade" integer DEFAULT 8,
  "p_status" "text" DEFAULT 'planejado'::"text",
  "p_sympla_url" "text" DEFAULT NULL::"text"
) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_id uuid; v_ja int;
begin
  perform _exige_admin();

  if coalesce(trim(p_patrocinador_nome),'') = '' then
    raise exception 'Informe o patrocinador' using errcode='22023';
  end if;
  if p_status not in ('planejado','confirmado','realizado','cancelado') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;

  if p_id is not null then
    -- capacidade nao pode ficar menor que quem ja esta confirmado
    select count(*) into v_ja from jantar_convidados
     where jantar_id = p_id and status in ('confirmado','compareceu');
    if coalesce(p_capacidade,8) < v_ja then
      raise exception 'Já há % confirmado(s); a capacidade não pode ser menor que isso', v_ja
        using errcode='22023';
    end if;

    update jantares set
      data = p_data, horario = p_horario, local = p_local,
      patrocinador_nome = trim(p_patrocinador_nome),
      patrocinador_site = p_patrocinador_site,
      perfil_convidado = p_perfil_convidado,
      observacoes = p_observacoes, abrangencia = p_abrangencia,
      capacidade = coalesce(p_capacidade,8), status = p_status,
      sympla_url = nullif(trim(p_sympla_url),'')
    where id = p_id
    returning id into v_id;
  else
    insert into jantares (data, horario, local, patrocinador_nome,
                          patrocinador_site, perfil_convidado, observacoes,
                          abrangencia, capacidade, status, sympla_url, criado_por)
    values (p_data, p_horario, p_local, trim(p_patrocinador_nome),
            p_patrocinador_site, p_perfil_convidado, p_observacoes,
            p_abrangencia, coalesce(p_capacidade,8), p_status,
            nullif(trim(p_sympla_url),''), auth.jwt() ->> 'email')
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."jantar_salvar"("text","uuid","date",time without time zone,"text","text","text","text","text",integer,"text","text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_salvar"("text","uuid","date",time without time zone,"text","text","text","text","text",integer,"text","text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_salvar"("text","uuid","date",time without time zone,"text","text","text","text","text",integer,"text","text") TO "service_role";


-- jantar_obter devolve o campo novo para a tela conseguir exibi-lo.
-- Muda as colunas do RETURNS TABLE, entao exige DROP: o Postgres nao
-- deixa CREATE OR REPLACE alterar o formato de retorno.
DROP FUNCTION IF EXISTS "gestao"."jantar_obter"("uuid");

CREATE FUNCTION "gestao"."jantar_obter"("p_id" "uuid") RETURNS TABLE(
  "id" "uuid", "data" "date", "horario" time without time zone, "local" "text",
  "patrocinador_nome" "text", "patrocinador_site" "text", "perfil_convidado" "text",
  "observacoes" "text", "abrangencia" "text", "capacidade" integer, "status" "text",
  "sympla_url" "text"
)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select j.id, j.data, j.horario, j.local, j.patrocinador_nome,
           j.patrocinador_site, j.perfil_convidado, j.observacoes,
           j.abrangencia, j.capacidade, j.status, j.sympla_url
    from jantares j where j.id = p_id;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."jantar_obter"("uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_obter"("uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_obter"("uuid") TO "service_role";
