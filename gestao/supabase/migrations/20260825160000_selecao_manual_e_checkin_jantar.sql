-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Escolha manual de convidado em jantar + check-in vinculado ao jantar.
--
-- 1. jantar_adicionar_convidado_existente
--
-- Ate aqui, jantares.html so tinha dois jeitos de povoar a lista de
-- convidados: rodar a prospeccao por IA (busca todas as empresas,
-- pontua, custa chamada de IA), ou "avulso" (digitar nome do zero —
-- que so casa por e-mail; sem e-mail, sempre cria gestor novo, mesmo
-- que a pessoa ja exista na base). Nao havia como buscar na base de
-- 1.468 gestores e simplesmente escolher alguem.
--
-- Reaproveita admin_listar_gestores (ja publicada) para a busca no
-- front; esta funcao so faz a insercao, pelo mesmo padrao de
-- jantar_salvar_selecao (mesmo unique constraint jantar_id+gestor_id,
-- mesmo ON CONFLICT).
--
-- 2. jantar_checkin_listar / jantar_checkin_registrar / jantar_checkin_desfazer
--
-- checkin.html so entende ?evento=slug e opera sobre v_esperados, que
-- e por evento. Jantar nao tem evento_id (design deliberado, jantares
-- sao standalone) — hoje NAO HA como fazer check-in de convidado de
-- jantar pela tela de portaria. jantares.html tem botao "Compareceu"
-- na lista de convidados, mas isso e tela de admin revisando depois,
-- nao a experiencia de porta (busca rapida, cartao grande, um toque)
-- que checkin.html oferece.
--
-- As tres funcoes aqui espelham checkin_listar/checkin_registrar/
-- checkin_desfazer, trocando "evento_id" por "jantar_id" e operando
-- direto em jantar_convidados (sem view v_esperados: jantar_convidados
-- ja tem tudo que precisa, nao ha quarto/reserva envolvido).
-- =====================================================================

set search_path = gestao, public;

CREATE OR REPLACE FUNCTION "gestao"."jantar_adicionar_convidado_existente"(
  "p_jantar_id" "uuid", "p_gestor_id" "uuid", "p_rotulo" "text" DEFAULT NULL
) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_cap int; v_ocupados int; v_empresa text;
begin
  perform _exige_staff();

  select capacidade into v_cap from jantares where id = p_jantar_id;
  if v_cap is null then
    raise exception 'Jantar nao encontrado' using errcode='P0002';
  end if;

  if not exists (select 1 from gestores where id = p_gestor_id) then
    raise exception 'Gestor nao encontrado' using errcode='P0002';
  end if;

  select count(*) into v_ocupados from jantar_convidados
   where jantar_id = p_jantar_id and status in ('confirmado','compareceu');
  if v_ocupados >= v_cap then
    raise exception 'O jantar já tem % de % vaga(s) ocupada(s)', v_ocupados, v_cap
      using errcode='22023';
  end if;

  select empresa into v_empresa from gestores where id = p_gestor_id;

  insert into jantar_convidados (jantar_id, gestor_id, empresa, origem, status, rotulo)
  values (p_jantar_id, p_gestor_id, v_empresa, 'manual', 'convidado', p_rotulo)
  on conflict (jantar_id, gestor_id) do update set status = 'convidado';

  return jsonb_build_object('ok', true);
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."jantar_adicionar_convidado_existente"("uuid","uuid","text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_adicionar_convidado_existente"("uuid","uuid","text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_adicionar_convidado_existente"("uuid","uuid","text") TO "service_role";


CREATE OR REPLACE FUNCTION "gestao"."jantar_checkin_listar"("p_jantar_id" "uuid") RETURNS TABLE(
  "id" "uuid", "nome" "text", "empresa" "text", "status" "text", "registrado_em" timestamp with time zone
)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select jc.id, g.nome, coalesce(jc.empresa, g.empresa), jc.status, jc.updated_at
    from jantar_convidados jc
    join gestores g on g.id = jc.gestor_id
    where jc.jantar_id = p_jantar_id
      and jc.status in ('convidado','confirmado','compareceu')
    order by (jc.status = 'compareceu'), g.nome;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."jantar_checkin_listar"("uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_checkin_listar"("uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_checkin_listar"("uuid") TO "service_role";


CREATE OR REPLACE FUNCTION "gestao"."jantar_checkin_registrar"("p_convidado_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  update jantar_convidados set status = 'compareceu'
   where id = p_convidado_id and status <> 'compareceu';
  if not found then
    raise exception 'Convidado nao encontrado ou ja estava com check-in' using errcode='P0002';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."jantar_checkin_registrar"("uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_checkin_registrar"("uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_checkin_registrar"("uuid") TO "service_role";


CREATE OR REPLACE FUNCTION "gestao"."jantar_checkin_desfazer"("p_convidado_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  update jantar_convidados set status = 'confirmado'
   where id = p_convidado_id and status = 'compareceu';
  if not found then
    raise exception 'Convidado nao encontrado ou nao tinha check-in' using errcode='P0002';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."jantar_checkin_desfazer"("uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_checkin_desfazer"("uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_checkin_desfazer"("uuid") TO "service_role";
