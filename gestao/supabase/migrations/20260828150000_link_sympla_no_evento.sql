-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- admin_salvar_evento ganha o link publico do Sympla.
--
-- eventos.sympla_url foi criada na migration anterior, mas so dava
-- para preencher por SQL — a funcao que a tela usa nao conhecia o
-- campo. Sem isso o convite nunca sai, porque so e enfileirado quando
-- ha link.
--
-- sympla_event_id (que ja existia) e o identificador interno; nao
-- serve para colar num e-mail. Os dois convivem.
--
-- DROP antes do CREATE: parametro novo muda a assinatura, e
-- CREATE OR REPLACE criaria uma segunda funcao — duas assinaturas
-- fazem o PostgREST recusar a chamada inteira.
--
-- O corpo abaixo e o original, com tres acrescimos marcados. As
-- validacoes (slug vazio, nome vazio, status invalido, data final
-- anterior a inicial, cota unica com varias cotas) e a criacao
-- automatica da cota Unica seguem iguais.
-- =====================================================================

set search_path = gestao, public;

DROP FUNCTION IF EXISTS "gestao"."admin_salvar_evento"(
  "text","text","text","date","date","text","date","date","date","text",boolean,
  timestamp with time zone);

CREATE FUNCTION "gestao"."admin_salvar_evento"(
  "p_slug" "text",
  "p_nome" "text",
  "p_local" "text" DEFAULT NULL::"text",
  "p_data_inicio" "date" DEFAULT NULL::"date",
  "p_data_fim" "date" DEFAULT NULL::"date",
  "p_status" "text" DEFAULT 'rascunho'::"text",
  "p_prazo_contrato" "date" DEFAULT NULL::"date",
  "p_prazo_rooming" "date" DEFAULT NULL::"date",
  "p_prazo_cancelamento" "date" DEFAULT NULL::"date",
  "p_sympla_event_id" "text" DEFAULT NULL::"text",
  "p_cota_unica" boolean DEFAULT false,
  "p_escolha_abre_em" timestamp with time zone DEFAULT NULL::timestamp with time zone,
  "p_sympla_url" "text" DEFAULT NULL::"text"
) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_slug text; v_id uuid; v_cotas int;
begin
  perform _exige_admin();

  v_slug := trim(both '-' from regexp_replace(
    lower(unaccent('unaccent', coalesce(trim(p_slug),''))), '[^a-z0-9]+','-','g'));

  if v_slug = '' then
    raise exception 'Informe o identificador do evento' using errcode='22023';
  end if;
  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome do evento' using errcode='22023';
  end if;
  if p_status not in ('rascunho','aberto','encerrado') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;
  if p_data_inicio is not null and p_data_fim is not null
     and p_data_fim < p_data_inicio then
    raise exception 'A data final e anterior a inicial' using errcode='22023';
  end if;

  -- Virar cota unica com varias cotas ja criadas deixaria a fila de
  -- escolha sem sentido, entao o caminho e limpar as cotas antes.
  if p_cota_unica then
    select count(*) into v_cotas from cotas c
    join eventos e on e.id = c.evento_id
    where e.slug = v_slug;
    if v_cotas > 1 then
      raise exception
        'Este evento tem % cotas. Remova-as antes de marcar como cota unica.', v_cotas
        using errcode='22023';
    end if;
  end if;

  insert into eventos (slug, nome, local, data_inicio, data_fim, status,
                       prazo_contrato, prazo_rooming, prazo_cancelamento,
                       sympla_event_id, cota_unica, escolha_abre_em,
                       sympla_url)                                   -- (1) novo
  values (v_slug, trim(p_nome), p_local, p_data_inicio, p_data_fim, p_status,
          p_prazo_contrato, p_prazo_rooming, p_prazo_cancelamento,
          p_sympla_event_id, coalesce(p_cota_unica,false), p_escolha_abre_em,
          nullif(trim(p_sympla_url),''))                             -- (2) novo
  on conflict (slug) do update set
    nome = excluded.nome, local = excluded.local,
    data_inicio = excluded.data_inicio, data_fim = excluded.data_fim,
    status = excluded.status,
    prazo_contrato = excluded.prazo_contrato,
    prazo_rooming = excluded.prazo_rooming,
    prazo_cancelamento = excluded.prazo_cancelamento,
    sympla_event_id = coalesce(excluded.sympla_event_id, eventos.sympla_event_id),
    cota_unica = excluded.cota_unica,
    escolha_abre_em = excluded.escolha_abre_em,
    -- (3) novo. coalesce igual ao do sympla_event_id: salvar o evento
    -- por outra tela, sem mandar o link, nao pode apagar o que ja esta
    -- la — foi o padrao escolhido para o id e vale igual aqui.
    sympla_url = coalesce(excluded.sympla_url, eventos.sympla_url)
  returning id into v_id;

  -- Evento de cota unica ja nasce com a cota pronta: sem ela o
  -- patrocinador nao consegue ser cadastrado.
  if coalesce(p_cota_unica,false) then
    insert into cotas (evento_id, nome, ordem_prioridade, quartos_incluidos,
                       tipo_quarto_padrao, vagas_mesa_redonda,
                       tem_reuniao_exclusiva, tem_jantar)
    values (v_id, 'Única', 1, 0, 'duplo', 0, false, true)
    on conflict (evento_id, nome) do nothing;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'slug', v_slug,
                            'cota_unica', coalesce(p_cota_unica,false));
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_salvar_evento"("text","text","text","date","date","text","date","date","date","text",boolean,timestamp with time zone,"text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_salvar_evento"("text","text","text","date","date","text","date","date","date","text",boolean,timestamp with time zone,"text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_salvar_evento"("text","text","text","date","date","text","date","date","date","text",boolean,timestamp with time zone,"text") TO "service_role";


-- A listagem tambem precisa devolver o link, senao a tela nao tem como
-- exibir nem preencher o campo. Muda o RETURNS TABLE, entao exige DROP.
DROP FUNCTION IF EXISTS "gestao"."admin_listar_eventos"();

CREATE FUNCTION "gestao"."admin_listar_eventos"() RETURNS TABLE(
  "id" "uuid", "slug" "text", "nome" "text", "local" "text",
  "data_inicio" "date", "data_fim" "date", "status" "text",
  "cota_unica" boolean, "prazo_contrato" "date", "prazo_rooming" "date",
  "prazo_cancelamento" "date", "participantes" bigint,
  "escolha_abre_em" timestamp with time zone,
  "sympla_url" "text", "sympla_event_id" "text"
)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select e.id, e.slug, e.nome, e.local, e.data_inicio, e.data_fim,
           e.status, e.cota_unica,
           e.prazo_contrato, e.prazo_rooming, e.prazo_cancelamento,
           (select count(*) from participantes p where p.evento_id = e.id),
           e.escolha_abre_em,
           e.sympla_url, e.sympla_event_id
    from eventos e
    order by e.data_inicio desc nulls last;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_listar_eventos"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_eventos"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_eventos"() TO "service_role";
