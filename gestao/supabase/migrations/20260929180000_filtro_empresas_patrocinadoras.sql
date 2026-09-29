-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- admin_listar_empresas ganha p_so_patrocinadoras: o datalist de
-- Patrocinadores (admin.html, migration 20260929100000) estava
-- puxando TODAS as empresas do cadastro global, inclusive quem so' e'
-- empregador de gestor/CIO convidado e nunca patrocinou nada — ruido
-- puro naquele campo especifico, e pode confundir quem esta' digitando
-- (a empresa "existe" no cadastro, mas nunca foi patrocinadora de
-- verdade). Achado pelo organizador em 29/09/2026.
--
-- Mesmo padrao do p_so_com_gestores que ja existe (filtro por join com
-- outra tabela, nao coluna propria — nao ha' "tipo" gravado em
-- empresas, e nao devia haver: a mesma empresa pode ser as duas coisas
-- ao mesmo tempo).
-- =====================================================================

set search_path = gestao, public;

drop function if exists admin_listar_empresas(text, text[], text[], text[], text[], boolean, integer, integer);

create function admin_listar_empresas(
  p_busca text DEFAULT NULL::text,
  p_segmentos text[] DEFAULT NULL::text[],
  p_cidades text[] DEFAULT NULL::text[],
  p_estados text[] DEFAULT NULL::text[],
  p_perfis text[] DEFAULT NULL::text[],
  p_so_com_gestores boolean DEFAULT false,
  p_limite integer DEFAULT 500,
  p_offset integer DEFAULT 0,
  p_so_patrocinadoras boolean DEFAULT false
) returns table(
  id uuid, nome text, cnpj text, site text, segmento text, cidade text, estado text,
  resumo text, o_que_vende text, natureza text,
  qtd_gestores bigint, total_geral bigint
) language plpgsql stable security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_admin();
  return query
    with base as (
      select e.id, e.nome, e.cnpj, e.site, e.segmento, e.cidade, e.estado,
             e.resumo, e.o_que_vende, e.natureza,
             (select count(*) from gestores g where g.empresa_id = e.id) as qtd
      from empresas e
      where (p_busca is null or
             unaccent('unaccent', lower(e.nome))
               like '%' || unaccent('unaccent', lower(p_busca)) || '%')
        and (p_segmentos is null or cardinality(p_segmentos) = 0
             or e.segmento = any(p_segmentos)
             or exists (select 1 from gestores g
                         where g.empresa_id = e.id and g.segmento = any(p_segmentos)))
        and (p_cidades is null or cardinality(p_cidades) = 0
             or unaccent('unaccent', upper(coalesce(e.cidade,''))) = any(
                  select unaccent('unaccent', upper(x)) from unnest(p_cidades) x)
             or exists (select 1 from gestores g
                         where g.empresa_id = e.id
                           and unaccent('unaccent', upper(coalesce(g.cidade,''))) = any(
                                 select unaccent('unaccent', upper(x)) from unnest(p_cidades) x)))
        and (p_estados is null or cardinality(p_estados) = 0
             or upper(coalesce(e.estado,'')) = any(select upper(x) from unnest(p_estados) x)
             or exists (select 1 from gestores g
                         where g.empresa_id = e.id
                           and upper(coalesce(g.estado,'')) = any(
                                 select upper(x) from unnest(p_estados) x)))
        and (p_perfis is null or cardinality(p_perfis) = 0
             or exists (select 1 from gestores g
                         where g.empresa_id = e.id and g.perfil = any(p_perfis)))
        and (not p_so_patrocinadoras
             or exists (select 1 from patrocinadores pt where pt.empresa_id = e.id))
    )
    select b.id, b.nome, b.cnpj, b.site, b.segmento, b.cidade, b.estado,
           b.resumo, b.o_que_vende, b.natureza,
           b.qtd, count(*) over ()
    from base b
    where not p_so_com_gestores or b.qtd > 0
    order by b.nome
    limit p_limite offset p_offset;
end;
$$;

revoke all on function admin_listar_empresas(text, text[], text[], text[], text[], boolean, integer, integer, boolean) from public, anon;
grant all on function admin_listar_empresas(text, text[], text[], text[], text[], boolean, integer, integer, boolean) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Self-check: o filtro precisa devolver estritamente menos ou igual
-- linhas que a chamada sem filtro — nunca mais.
-- ---------------------------------------------------------------------
do $$
declare v_total_geral int; v_total_patro int;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);

  select count(*) into v_total_geral from admin_listar_empresas(p_limite => 100000);
  select count(*) into v_total_patro from admin_listar_empresas(p_limite => 100000, p_so_patrocinadoras => true);

  if v_total_patro > v_total_geral then
    raise exception 'filtro p_so_patrocinadoras devolveu MAIS linhas (%) que sem filtro (%)',
      v_total_patro, v_total_geral;
  end if;
end $$;
