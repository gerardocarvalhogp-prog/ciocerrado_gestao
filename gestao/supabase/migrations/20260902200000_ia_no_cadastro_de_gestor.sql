-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Gestores ganha "IA ajusta/popula campos", nos mesmos moldes do que
-- ja existe em Patrocinadores (admin_enriquecer_patrocinador). Achado
-- real, reportado pelo Gerardo: "No Gestores nao tem a opcao da IA
-- ajustar/popular os campos".
--
-- Escopo deliberadamente menor que o do patrocinador: so campo
-- profissional publico (cargo, empresa, segmento, cidade, estado,
-- linkedin). CPF, telefone e e-mail ficam de fora — sao dado pessoal
-- sensivel de uma PESSOA fisica, nao da empresa, e nao da pra
-- confiar numa busca web pra isso.
-- =====================================================================

set search_path = gestao, public;

create or replace function admin_enriquecer_gestor(
  p_id uuid, p_cargo text DEFAULT NULL::text, p_empresa text DEFAULT NULL::text,
  p_segmento text DEFAULT NULL::text, p_cidade text DEFAULT NULL::text,
  p_estado text DEFAULT NULL::text, p_linkedin text DEFAULT NULL::text
) returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_admin();

  update gestores set
    cargo    = coalesce(nullif(trim(p_cargo),''), cargo),
    empresa  = coalesce(nullif(trim(p_empresa),''), empresa),
    segmento = coalesce(nullif(trim(p_segmento),''), segmento),
    cidade   = coalesce(nullif(trim(p_cidade),''), cidade),
    estado   = coalesce(nullif(trim(p_estado),''), estado),
    linkedin = coalesce(nullif(trim(p_linkedin),''), linkedin),
    updated_at = now()
  where id = p_id;

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function admin_enriquecer_gestor(uuid,text,text,text,text,text,text) from public, anon;
grant execute on function admin_enriquecer_gestor(uuid,text,text,text,text,text,text) to authenticated, service_role;
