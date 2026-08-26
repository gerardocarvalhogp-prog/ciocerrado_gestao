-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Listagem paginada de gestores + tabela de empresas.
--
-- admin_listar_gestores segue o mesmo padrao de admin_rel_painel
-- (count(*) over () como total_geral, limit/offset) — a diferenca e
-- que aqui NAO ha p_evento_slug: o cadastro de gestores e global,
-- compartilhado entre edicoes, entao a paginacao nao filtra por
-- evento.
--
-- EMPRESAS
--
-- Ate aqui, gestores.empresa e texto livre — a mesma empresa aparece
-- com grafias diferentes ("Coca-Cola", "COCA COLA REFRESCOS",
-- "Coca-Cola Refrescos Bandeirantes (REBIC)") em registros diferentes.
-- A tabela nova nao tenta resolver isso de uma vez: comeca vazia, e o
-- vinculo entre gestor e empresa e feito a mao, aos poucos, pela tela.
--
-- Migrar os 1.468 gestores.empresa existentes por casamento de texto
-- (fuzzy match) ficou de fora de proposito — e exatamente o tipo de
-- automacao que erra silenciosamente (duas empresas parecidas viram
-- uma so, ou uma nao casa e fica orfa) e so aparece depois, quando
-- ja afetou decisao de alocacao ou fatura. gestores.empresa (texto)
-- continua existindo e sendo exibido; empresa_id e um vinculo
-- adicional, opcional, para quando alguem revisar aquele gestor.
-- =====================================================================

set search_path = gestao, public;

CREATE TABLE IF NOT EXISTS "gestao"."empresas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL PRIMARY KEY,
    "nome" "text" NOT NULL,
    "cnpj" "text",
    "site" "text",
    "segmento" "text",
    "cidade" "text",
    "estado" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "gestao"."empresas" OWNER TO "postgres";
ALTER TABLE "gestao"."empresas" ENABLE ROW LEVEL SECURITY;

-- Politica existe por hipoteses (tabela nova sem RLS e o cenario que a
-- trava de 25/08 foi escrita pra pegar), mas nao e ela que segura o
-- acesso: nenhum papel tem GRANT direto nesta tabela (ver abaixo),
-- entao so SECURITY DEFINER function consegue ler ou escrever aqui.
CREATE POLICY "empresas_staff_tudo" ON "gestao"."empresas"
  USING (is_staff()) WITH CHECK (is_staff());

CREATE TRIGGER "empresas_updated_at" BEFORE UPDATE ON "gestao"."empresas"
  FOR EACH ROW EXECUTE FUNCTION "gestao"."touch_updated_at"();

ALTER TABLE "gestao"."gestores"
  ADD COLUMN IF NOT EXISTS "empresa_id" "uuid" REFERENCES "gestao"."empresas"("id") ON DELETE SET NULL;

-- Mesmo padrao de 20260825090000: authenticated nao ganha GRANT direto
-- na tabela. Toda leitura/escrita passa por funcao, como o resto do
-- schema desde aquela migration — testei sem isso primeiro e o INSERT
-- direto (que eu tinha posto por engano) passou batido, o que teria
-- reaberto exatamente o buraco que 20260825090000 fechou.
REVOKE ALL ON TABLE "gestao"."empresas" FROM PUBLIC;
REVOKE ALL ON TABLE "gestao"."empresas" FROM "anon";
REVOKE ALL ON TABLE "gestao"."empresas" FROM "authenticated";
GRANT ALL ON TABLE "gestao"."empresas" TO "service_role";

CREATE OR REPLACE FUNCTION "gestao"."admin_listar_gestores"(
  "p_busca" "text" DEFAULT NULL,
  "p_perfil" "text" DEFAULT NULL,
  "p_limite" integer DEFAULT 500,
  "p_offset" integer DEFAULT 0
) RETURNS TABLE(
  "id" "uuid", "nome" "text", "email" "text", "empresa" "text",
  "empresa_id" "uuid", "cargo" "text", "telefone" "text", "cidade" "text",
  "estado" "text", "perfil" "text", "linkedin" "text", "total_geral" bigint
)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select g.id, g.nome, g.email, g.empresa, g.empresa_id, g.cargo,
           g.telefone, g.cidade, g.estado, g.perfil, g.linkedin,
           count(*) over ()
    from gestores g
    where (p_busca is null or
           unaccent('unaccent', lower(g.nome || ' ' || coalesce(g.empresa,'')))
             like '%' || unaccent('unaccent', lower(p_busca)) || '%')
      and (p_perfil is null or g.perfil = p_perfil)
    order by g.nome
    limit p_limite offset p_offset;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_listar_gestores"("text","text",integer,integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_gestores"("text","text",integer,integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_gestores"("text","text",integer,integer) TO "service_role";


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_empresas"(
  "p_busca" "text" DEFAULT NULL,
  "p_limite" integer DEFAULT 500,
  "p_offset" integer DEFAULT 0
) RETURNS TABLE(
  "id" "uuid", "nome" "text", "cnpj" "text", "site" "text",
  "segmento" "text", "cidade" "text", "estado" "text",
  "qtd_gestores" bigint, "total_geral" bigint
)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select e.id, e.nome, e.cnpj, e.site, e.segmento, e.cidade, e.estado,
           (select count(*) from gestores g where g.empresa_id = e.id),
           count(*) over ()
    from empresas e
    where p_busca is null or
          unaccent('unaccent', lower(e.nome)) like '%' || unaccent('unaccent', lower(p_busca)) || '%'
    order by e.nome
    limit p_limite offset p_offset;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_listar_empresas"("text",integer,integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_empresas"("text",integer,integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_empresas"("text",integer,integer) TO "service_role";


-- p_id nulo cria; presente atualiza. Mesmo padrao de admin_salvar_preco
-- e admin_salvar_membro.
CREATE OR REPLACE FUNCTION "gestao"."admin_salvar_empresa"(
  "p_nome" "text",
  "p_id" "uuid" DEFAULT NULL,
  "p_cnpj" "text" DEFAULT NULL,
  "p_site" "text" DEFAULT NULL,
  "p_segmento" "text" DEFAULT NULL,
  "p_cidade" "text" DEFAULT NULL,
  "p_estado" "text" DEFAULT NULL
) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_id uuid;
begin
  perform _exige_staff();

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome da empresa' using errcode='22023';
  end if;

  if p_id is not null then
    update empresas set
      nome = trim(p_nome), cnpj = nullif(trim(p_cnpj),''),
      site = nullif(trim(p_site),''), segmento = nullif(trim(p_segmento),''),
      cidade = nullif(trim(p_cidade),''), estado = nullif(trim(p_estado),'')
    where id = p_id
    returning id into v_id;
    if v_id is null then
      raise exception 'Empresa nao encontrada' using errcode='P0002';
    end if;
  else
    insert into empresas (nome, cnpj, site, segmento, cidade, estado)
    values (trim(p_nome), nullif(trim(p_cnpj),''), nullif(trim(p_site),''),
            nullif(trim(p_segmento),''), nullif(trim(p_cidade),''), nullif(trim(p_estado),''))
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_salvar_empresa"("text","uuid","text","text","text","text","text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_salvar_empresa"("text","uuid","text","text","text","text","text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_salvar_empresa"("text","uuid","text","text","text","text","text") TO "service_role";


-- ON DELETE SET NULL em gestores.empresa_id: remover a empresa nao
-- apaga gestor nenhum, so desassocia (o texto livre gestores.empresa
-- continua exibindo quem era, mesmo depois).
CREATE OR REPLACE FUNCTION "gestao"."admin_remover_empresa"("p_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  delete from empresas where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_remover_empresa"("uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_remover_empresa"("uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_remover_empresa"("uuid") TO "service_role";


-- p_empresa_id nulo desassocia. Nao mexe em gestores.empresa (texto):
-- a associacao e um vinculo a mais, nao uma substituicao.
CREATE OR REPLACE FUNCTION "gestao"."admin_associar_gestor_empresa"(
  "p_gestor_id" "uuid", "p_empresa_id" "uuid" DEFAULT NULL
) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  update gestores set empresa_id = p_empresa_id where id = p_gestor_id;
  if not found then
    raise exception 'Gestor nao encontrado' using errcode='P0002';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_associar_gestor_empresa"("uuid","uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_associar_gestor_empresa"("uuid","uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_associar_gestor_empresa"("uuid","uuid") TO "service_role";
