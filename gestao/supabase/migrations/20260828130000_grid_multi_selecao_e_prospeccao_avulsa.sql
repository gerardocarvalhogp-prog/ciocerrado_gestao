-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Multi-selecao de convidados e prospeccao sem jantar criado.
--
-- 1. FILTROS NO GRID DE GESTORES
--
-- admin_listar_gestores so filtrava por busca livre e perfil. Para
-- escolher convidado de jantar isso e pouco: "todos os CIOs de saude
-- em GO" era busca livre com sorte. Ganha segmento e estado.
--
-- DROP antes do CREATE: parametro novo muda a assinatura, e
-- CREATE OR REPLACE criaria uma SEGUNDA funcao — com duas, o
-- PostgREST recusa a chamada inteira ("could not choose the best
-- candidate function").
--
-- 2. ADICIONAR EM LOTE
--
-- jantar_adicionar_convidado_existente resolve um por vez. Marcar 20
-- pessoas no grid e disparar 20 chamadas seria lento e, pior, parcial
-- se uma falhasse no meio. A versao em lote faz tudo numa transacao e
-- devolve quantos entraram e quantos ja estavam.
--
-- A checagem de capacidade e feita UMA vez, contra o total do lote —
-- nao adianta validar de um em um quando a pergunta e "cabem os 20?".
--
-- 3. PROSPECCAO SEM JANTAR
--
-- jantar_base ja aceita isso e ninguem tinha reparado: o p_jantar_id
-- so aparece na CTE `neste`, que exclui empresas ja convidadas NAQUELE
-- jantar. Com null, a CTE nao casa nada e a analise roda sobre a base
-- inteira — que e exatamente o que se quer ao sondar um patrocinador
-- em potencial, antes de existir jantar nenhum.
--
-- Aqui so tornamos isso explicito com DEFAULT NULL, para a intencao
-- ficar no contrato da funcao em vez de depender de quem chama passar
-- null na posicao certa. A assinatura (uuid, boolean, boolean, integer)
-- nao muda — dar default a um parametro nao cria sobrecarga.
-- =====================================================================

set search_path = gestao, public;

DROP FUNCTION IF EXISTS "gestao"."admin_listar_gestores"("text","text",integer,integer);

CREATE FUNCTION "gestao"."admin_listar_gestores"(
  "p_busca" "text" DEFAULT NULL,
  "p_perfil" "text" DEFAULT NULL,
  "p_limite" integer DEFAULT 500,
  "p_offset" integer DEFAULT 0,
  "p_segmento" "text" DEFAULT NULL,
  "p_estado" "text" DEFAULT NULL
) RETURNS TABLE(
  "id" "uuid", "nome" "text", "email" "text", "empresa" "text",
  "empresa_id" "uuid", "cargo" "text", "telefone" "text", "cidade" "text",
  "estado" "text", "perfil" "text", "linkedin" "text", "segmento" "text",
  "total_geral" bigint
)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select g.id, g.nome, g.email, g.empresa, g.empresa_id, g.cargo,
           g.telefone, g.cidade, g.estado, g.perfil, g.linkedin, g.segmento,
           count(*) over ()
    from gestores g
    where (p_busca is null or
           unaccent('unaccent', lower(g.nome || ' ' || coalesce(g.empresa,'')))
             like '%' || unaccent('unaccent', lower(p_busca)) || '%')
      and (p_perfil is null or g.perfil = p_perfil)
      and (p_segmento is null or
           unaccent('unaccent', lower(coalesce(g.segmento,'')))
             like '%' || unaccent('unaccent', lower(p_segmento)) || '%')
      and (p_estado is null or upper(coalesce(g.estado,'')) = upper(p_estado))
    order by g.nome
    limit p_limite offset p_offset;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_listar_gestores"("text","text",integer,integer,"text","text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_gestores"("text","text",integer,integer,"text","text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_gestores"("text","text",integer,integer,"text","text") TO "service_role";


-- Valores distintos para montar os seletores de filtro sem inventar
-- lista fixa — o que existe na base e o que aparece.
CREATE OR REPLACE FUNCTION "gestao"."admin_filtros_gestores"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v jsonb;
begin
  perform _exige_staff();
  select jsonb_build_object(
    'perfis',    (select coalesce(jsonb_agg(x order by x),'[]'::jsonb)
                    from (select distinct perfil x from gestores
                           where coalesce(trim(perfil),'') <> '') p),
    'segmentos', (select coalesce(jsonb_agg(x order by x),'[]'::jsonb)
                    from (select distinct segmento x from gestores
                           where coalesce(trim(segmento),'') <> '') s),
    'estados',   (select coalesce(jsonb_agg(x order by x),'[]'::jsonb)
                    from (select distinct upper(estado) x from gestores
                           where coalesce(trim(estado),'') <> '') e)
  ) into v;
  return v;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_filtros_gestores"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_filtros_gestores"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_filtros_gestores"() TO "service_role";


CREATE OR REPLACE FUNCTION "gestao"."jantar_adicionar_convidados_existentes"(
  "p_jantar_id" "uuid", "p_gestor_ids" "uuid"[], "p_rotulo" "text" DEFAULT NULL
) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_cap int; v_ocupados int; v_novos int; v_add int := 0; v_ja int := 0;
  v_gid uuid;
begin
  perform _exige_staff();

  select capacidade into v_cap from jantares where id = p_jantar_id;
  if v_cap is null then
    raise exception 'Jantar nao encontrado' using errcode='P0002';
  end if;
  if p_gestor_ids is null or array_length(p_gestor_ids,1) is null then
    raise exception 'Selecione pelo menos um convidado' using errcode='22023';
  end if;

  select count(*) into v_ocupados from jantar_convidados
   where jantar_id = p_jantar_id and status in ('confirmado','compareceu');

  -- quantos do lote ainda nao estao no jantar
  select count(*) into v_novos
    from unnest(p_gestor_ids) as g(id)
   where not exists (select 1 from jantar_convidados jc
                      where jc.jantar_id = p_jantar_id and jc.gestor_id = g.id);

  -- pergunta certa: "cabem os N?", nao "cabe mais um?"
  if v_ocupados + v_novos > v_cap then
    raise exception 'O jantar tem % vaga(s) e % ocupada(s); os % selecionado(s) nao cabem',
      v_cap, v_ocupados, v_novos using errcode='22023';
  end if;

  foreach v_gid in array p_gestor_ids loop
    if exists (select 1 from jantar_convidados
                where jantar_id = p_jantar_id and gestor_id = v_gid) then
      v_ja := v_ja + 1;
      continue;
    end if;
    insert into jantar_convidados (jantar_id, gestor_id, empresa, origem, status, rotulo)
    select p_jantar_id, v_gid, g.empresa, 'manual', 'convidado', p_rotulo
      from gestores g where g.id = v_gid;
    v_add := v_add + 1;
  end loop;

  return jsonb_build_object('ok', true, 'adicionados', v_add, 'ja_estavam', v_ja);
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."jantar_adicionar_convidados_existentes"("uuid","uuid"[],"text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_adicionar_convidados_existentes"("uuid","uuid"[],"text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_adicionar_convidados_existentes"("uuid","uuid"[],"text") TO "service_role";


-- p_jantar_id opcional: prospeccao avulsa, sem jantar criado.
CREATE OR REPLACE FUNCTION "gestao"."jantar_base"(
  "p_jantar_id" "uuid" DEFAULT NULL,
  "p_excluir_fornecedores" boolean DEFAULT true,
  "p_excluir_convidados" boolean DEFAULT true,
  "p_limite" integer DEFAULT 500
) RETURNS TABLE("empresa" "text", "segmento" "text", "faturamento" "text", "funcionarios" "text", "cidade" "text", "estado" "text", "cnpj" "text", "exec1_id" "uuid", "exec1_nome" "text", "exec1_cargo" "text", "exec1_email" "text", "exec1_telefone" "text", "exec2_id" "uuid", "exec2_nome" "text", "exec2_cargo" "text", "exec2_email" "text", "exec2_telefone" "text", "contatos" bigint, "ja_convidado_em" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();

  return query
  with
  ja_novo as (
    select lower(trim(g.empresa)) as empresa,
           string_agg(distinct to_char(j.data,'DD/MM/YYYY'), ', ') as quando
    from jantar_convidados jc
    join jantares j on j.id = jc.jantar_id
    join gestores g on g.id = jc.gestor_id
    where jc.status in ('confirmado','compareceu')
      and coalesce(trim(g.empresa),'') <> ''
    group by lower(trim(g.empresa))
  ),
  ja_antigo as (
    select lower(trim(g.empresa)) as empresa,
           string_agg(distinct ev.nome, ', ') as quando
    from sessao_convidados sc
    join sessoes s on s.id = sc.sessao_id and s.tipo = 'jantar'
    join eventos ev on ev.id = s.evento_id
    join participantes pa on pa.id = sc.participante_id
    join gestores g on g.id = pa.gestor_id
    where sc.status = 'confirmado'
      and coalesce(trim(g.empresa),'') <> ''
    group by lower(trim(g.empresa))
  ),
  ja as (
    -- concat_ws de dois nulos vira string vazia, nao nulo — e o filtro
    -- "j.empresa is null" la embaixo depende de null para funcionar.
    -- nullif fecha essa brecha.
    select coalesce(n.empresa, a.empresa) as empresa,
           nullif(concat_ws(', ', n.quando, a.quando), '') as quando
    from ja_novo n full outer join ja_antigo a on a.empresa = n.empresa
  ),
  neste as (
    -- ja tem linha neste jantar (qualquer status): nao sugere de novo.
    -- Com p_jantar_id null (prospeccao avulsa) nao casa nada, e a
    -- analise roda sobre a base inteira.
    select lower(trim(g.empresa)) as empresa
    from jantar_convidados jc
    join gestores g on g.id = jc.gestor_id
    where jc.jantar_id = p_jantar_id
  ),
  ranqueado as (
    select g.*,
           row_number() over (
             partition by lower(trim(g.empresa))
             order by _rank_pos(g.posicao_gestor), _rank_cargo(g.cargo), g.nome) as pos,
           count(*) over (partition by lower(trim(g.empresa))) as n
    from gestores g
    where g.ativo
      and coalesce(trim(g.empresa),'') <> ''
      and coalesce(trim(g.nome),'') <> ''
      and (not p_excluir_fornecedores
           or coalesce(upper(unaccent('unaccent', g.perfil)),'')
              not like '%FORNECEDOR%')
  )
  select
    a.empresa, a.segmento, a.faturamento, a.funcionarios,
    a.cidade, a.estado, a.cnpj,
    a.id, a.nome, a.cargo, a.email, a.telefone,
    b.id, b.nome, b.cargo, b.email, b.telefone,
    a.n,
    j.quando
  from ranqueado a
  left join ranqueado b
    on lower(trim(b.empresa)) = lower(trim(a.empresa)) and b.pos = 2
  left join ja j on j.empresa = lower(trim(a.empresa))
  left join neste ne on ne.empresa = lower(trim(a.empresa))
  where a.pos = 1
    and ne.empresa is null
    and (not p_excluir_convidados or j.empresa is null)
  order by a.empresa
  limit p_limite;
end;
$$;
