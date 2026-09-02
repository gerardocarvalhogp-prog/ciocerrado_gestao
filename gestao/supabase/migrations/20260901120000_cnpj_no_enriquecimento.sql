-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- admin_enriquecer_patrocinador ganha CNPJ — a busca ja tinha o campo
-- na tela de cadastro manual, so a via da IA nao preenchia.
-- =====================================================================

set search_path = gestao, public;

-- assinatura nova (ganhou p_cnpj) — CREATE OR REPLACE nao troca lista
-- de parametro, so cria uma segunda funcao ao lado da antiga. DROP
-- primeiro evita as duas convivendo.
drop function if exists admin_enriquecer_patrocinador(uuid, text, text, text, text, text, text, text);

create or replace function admin_enriquecer_patrocinador(
  p_id uuid, p_site text DEFAULT NULL::text, p_resumo text DEFAULT NULL::text,
  p_o_que_vende text DEFAULT NULL::text, p_segmento text DEFAULT NULL::text,
  p_natureza text DEFAULT NULL::text, p_cidade text DEFAULT NULL::text,
  p_estado text DEFAULT NULL::text, p_cnpj text DEFAULT NULL::text
) returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_admin();

  update patrocinadores set
    site        = coalesce(nullif(trim(p_site),''), site),
    resumo      = coalesce(nullif(trim(p_resumo),''), resumo),
    o_que_vende = coalesce(nullif(trim(p_o_que_vende),''), o_que_vende),
    segmento    = coalesce(nullif(trim(p_segmento),''), segmento),
    natureza    = coalesce(nullif(trim(p_natureza),''), natureza),
    cidade      = coalesce(nullif(trim(p_cidade),''), cidade),
    estado      = coalesce(nullif(trim(p_estado),''), estado),
    cnpj        = coalesce(nullif(trim(p_cnpj),''), cnpj),
    enriquecido_em = now()
  where id = p_id;

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function admin_enriquecer_patrocinador(uuid,text,text,text,text,text,text,text,text) from public, anon;
grant execute on function admin_enriquecer_patrocinador(uuid,text,text,text,text,text,text,text,text) to authenticated, service_role;
