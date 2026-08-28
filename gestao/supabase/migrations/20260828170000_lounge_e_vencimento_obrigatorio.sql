-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Numero do lounge no patrocinador, e vencimento obrigatorio ao emitir.
--
-- 1. VENCIMENTO
--
-- admin_marcar_fatura aceitava emitir sem data de vencimento. Fatura
-- emitida sem vencimento nao tem como ser cobrada nem entrar em
-- "vencidas" — some do controle sem ninguem perceber.
--
-- A exigencia vale so ao EMITIR. 'estimada' e rascunho e nao precisa;
-- 'paga' ja aconteceu; 'cancelada' nao vai ser cobrada. E aceita
-- vencimento que ja esteja gravado, entao reemitir uma fatura que ja
-- tinha data nao exige redigitar.
--
-- 2. LOUNGE
--
-- Campo novo em patrocinadores. Como muda a assinatura das duas
-- funcoes (salvar e listar), as duas precisam de DROP antes do CREATE
-- — CREATE OR REPLACE com assinatura diferente cria uma SEGUNDA
-- funcao, e com duas o PostgREST recusa a chamada inteira.
-- =====================================================================

set search_path = gestao, public;

ALTER TABLE "gestao"."patrocinadores" ADD COLUMN IF NOT EXISTS "lounge" "text";


CREATE OR REPLACE FUNCTION "gestao"."admin_marcar_fatura"(
  "p_fatura_id" "uuid", "p_status" "text",
  "p_forma_pagamento" "text" DEFAULT NULL::"text",
  "p_observacao" "text" DEFAULT NULL::"text",
  "p_vencimento" "date" DEFAULT NULL::"date"
) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_ant text; v_venc_atual date;
begin
  perform _exige_admin();

  select status, vencimento into v_ant, v_venc_atual from faturas where id = p_fatura_id;
  if v_ant is null then
    raise exception 'Fatura nao encontrada' using errcode='P0002';
  end if;
  if p_status not in ('estimada','emitida','paga','cancelada') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;

  -- emitir e o ato que transforma estimativa em cobranca; sem
  -- vencimento a fatura nao entra em nenhum controle de atraso
  if p_status = 'emitida' and coalesce(p_vencimento, v_venc_atual) is null then
    raise exception 'Informe a data de vencimento para emitir a fatura'
      using errcode='22023';
  end if;

  update faturas set
    status = p_status,
    -- carimba a data na primeira vez que entra no estado, e limpa se
    -- voltar atras: fatura reaberta com data de pagamento antiga
    -- confunde a conferencia
    emitida_em = case
      when p_status in ('emitida','paga') then coalesce(emitida_em, now())
      else null end,
    paga_em = case
      when p_status = 'paga' then coalesce(paga_em, now())
      else null end,
    forma_pagamento = case
      when p_status = 'paga' then coalesce(p_forma_pagamento, forma_pagamento)
      else forma_pagamento end,
    observacao = coalesce(p_observacao, observacao),
    vencimento = coalesce(p_vencimento, vencimento)
  where id = p_fatura_id;

  return jsonb_build_object('ok', true, 'de', v_ant, 'para', p_status);
end;
$$;


DROP FUNCTION IF EXISTS "gestao"."admin_salvar_patrocinador"(
  "text","text","text","text","text","text",integer,integer,"text","text","text","text","text","text");

CREATE FUNCTION "gestao"."admin_salvar_patrocinador"(
  "p_evento_slug" "text", "p_empresa" "text",
  "p_cota_nome" "text" DEFAULT NULL::"text",
  "p_cnpj" "text" DEFAULT NULL::"text",
  "p_segmento" "text" DEFAULT NULL::"text",
  "p_o_que_vende" "text" DEFAULT NULL::"text",
  "p_quartos_extras" integer DEFAULT 0,
  "p_vagas_mesa_override" integer DEFAULT NULL::integer,
  "p_status" "text" DEFAULT 'ativo'::"text",
  "p_site" "text" DEFAULT NULL::"text",
  "p_resumo" "text" DEFAULT NULL::"text",
  "p_natureza" "text" DEFAULT NULL::"text",
  "p_cidade" "text" DEFAULT NULL::"text",
  "p_estado" "text" DEFAULT NULL::"text",
  "p_lounge" "text" DEFAULT NULL::"text"
) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_evento uuid; v_cota uuid; v_id uuid;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if coalesce(trim(p_empresa),'') = '' then
    raise exception 'Informe o nome da empresa' using errcode='22023';
  end if;

  if p_cota_nome is not null and trim(p_cota_nome) <> '' then
    select id into v_cota from cotas
     where evento_id = v_evento and lower(nome) = lower(trim(p_cota_nome));
    if v_cota is null then
      raise exception 'Cota "%" nao existe neste evento', p_cota_nome
        using errcode='P0002';
    end if;
  end if;

  insert into patrocinadores (evento_id, cota_id, empresa, cnpj, segmento,
                              o_que_vende, quartos_extras_cota,
                              vagas_mesa_override, status,
                              site, resumo, natureza, cidade, estado, lounge)
  values (v_evento, v_cota, trim(p_empresa), p_cnpj, p_segmento,
          p_o_que_vende, coalesce(p_quartos_extras,0),
          p_vagas_mesa_override, p_status,
          p_site, p_resumo, p_natureza, p_cidade, p_estado,
          nullif(trim(p_lounge),''))
  on conflict (evento_id, lower(empresa)) do update set
    cota_id = coalesce(excluded.cota_id, patrocinadores.cota_id),
    cnpj = coalesce(excluded.cnpj, patrocinadores.cnpj),
    segmento = coalesce(excluded.segmento, patrocinadores.segmento),
    o_que_vende = coalesce(excluded.o_que_vende, patrocinadores.o_que_vende),
    quartos_extras_cota = excluded.quartos_extras_cota,
    vagas_mesa_override = excluded.vagas_mesa_override,
    status = excluded.status,
    site = coalesce(excluded.site, patrocinadores.site),
    resumo = coalesce(excluded.resumo, patrocinadores.resumo),
    natureza = coalesce(excluded.natureza, patrocinadores.natureza),
    cidade = coalesce(excluded.cidade, patrocinadores.cidade),
    estado = coalesce(excluded.estado, patrocinadores.estado),
    -- coalesce como os demais: salvar sem mandar o lounge nao apaga
    -- o numero que ja estava la
    lounge = coalesce(excluded.lounge, patrocinadores.lounge)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_salvar_patrocinador"("text","text","text","text","text","text",integer,integer,"text","text","text","text","text","text","text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_salvar_patrocinador"("text","text","text","text","text","text",integer,integer,"text","text","text","text","text","text","text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_salvar_patrocinador"("text","text","text","text","text","text",integer,integer,"text","text","text","text","text","text","text") TO "service_role";


-- A listagem tambem precisa devolver o lounge. Muda o RETURNS TABLE,
-- entao exige DROP.
DROP FUNCTION IF EXISTS "gestao"."admin_listar_patrocinadores"("text");

CREATE FUNCTION "gestao"."admin_listar_patrocinadores"("p_evento_slug" "text") RETURNS TABLE(
  "id" "uuid", "empresa" "text", "cnpj" "text", "segmento" "text", "site" "text",
  "resumo" "text", "o_que_vende" "text", "natureza" "text", "cidade" "text",
  "estado" "text", "cota" "text", "ordem" integer, "quartos_extras" integer,
  "vagas_mesa_override" integer, "status" "text",
  "fechado_em" timestamp with time zone, "enriquecido_em" timestamp with time zone,
  "usuarios" bigint, "reservas" bigint, "lounge" "text"
)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select p.id, p.empresa, p.cnpj, p.segmento,
           p.site, p.resumo, p.o_que_vende, p.natureza,
           p.cidade, p.estado,
           c.nome, c.ordem_prioridade, p.quartos_extras_cota,
           p.vagas_mesa_override, p.status, p.fechado_em, p.enriquecido_em,
           (select count(*) from usuarios_patrocinador u
             where u.patrocinador_id = p.id and u.ativo),
           (select count(*) from reservas r
             where r.patrocinador_id = p.id and r.status <> 'cancelado'),
           p.lounge
    from patrocinadores p
    left join cotas c on c.id = p.cota_id
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    order by c.ordem_prioridade nulls last, p.empresa;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_listar_patrocinadores"("text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_patrocinadores"("text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_patrocinadores"("text") TO "service_role";
