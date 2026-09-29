-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Fecha o cadastro global de patrocinador (Bloco 4/Fase 2, migration
-- 20260909100000): o banco ja trata `empresas` como o cadastro unico e
-- `patrocinadores` como so o vinculo com um evento, mas duas pontas de
-- LEITURA ainda expunham/mostravam o dado antigo, per-evento, em vez do
-- cadastro global:
--
--   1. admin_listar_empresas nao devolvia resumo/o_que_vende/natureza —
--      sem eles, a tela nao tem como pre-preencher o formulario de
--      Patrocinadores quando a empresa escolhida ja existe.
--   2. admin_listar_patrocinadores lia cnpj/segmento/site/resumo/
--      o_que_vende/natureza/cidade/estado da COPIA em patrocinadores,
--      nao do cadastro em empresas — editar o perfil da empresa a
--      partir do evento A nao aparecia pro evento B da mesma empresa,
--      porque cada evento tem sua propria copia desses campos (a
--      copia so e' escrita de novo quando aquele evento especifico e'
--      salvo). Troca pra ler de empresas: agora e' uma leitura so,
--      sempre atual, para qualquer evento.
--
-- Os campos em patrocinadores continuam existindo (writes de
-- admin_salvar_patrocinador/admin_enriquecer_patrocinador nao mudam
-- aqui) — so a LEITURA passa a priorizar o cadastro global. Nao e'
-- dado morto: fica como historico de "o que foi digitado quando este
-- vinculo foi criado", util se um dia alguem quiser auditar divergencia.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. admin_listar_empresas ganha resumo/o_que_vende/natureza
-- ---------------------------------------------------------------------
drop function if exists admin_listar_empresas(text, text[], text[], text[], text[], boolean, integer, integer);

create function admin_listar_empresas(
  p_busca text DEFAULT NULL::text,
  p_segmentos text[] DEFAULT NULL::text[],
  p_cidades text[] DEFAULT NULL::text[],
  p_estados text[] DEFAULT NULL::text[],
  p_perfis text[] DEFAULT NULL::text[],
  p_so_com_gestores boolean DEFAULT false,
  p_limite integer DEFAULT 500,
  p_offset integer DEFAULT 0
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

revoke all on function admin_listar_empresas(text, text[], text[], text[], text[], boolean, integer, integer) from public, anon;
grant all on function admin_listar_empresas(text, text[], text[], text[], text[], boolean, integer, integer) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. admin_listar_patrocinadores le o perfil de empresas, nao mais da
--    copia por evento
-- ---------------------------------------------------------------------
drop function if exists admin_listar_patrocinadores(text);

create function admin_listar_patrocinadores(p_evento_slug text) returns table(
  id uuid, empresa_id uuid, empresa text, cnpj text, segmento text, site text,
  resumo text, o_que_vende text, natureza text, cidade text,
  estado text, cota text, ordem integer, quartos_extras integer,
  vagas_mesa_override integer, status text,
  fechado_em timestamptz, enriquecido_em timestamptz,
  usuarios bigint, reservas bigint, lounge text
)
language plpgsql stable security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_staff();
  return query
    select p.id, p.empresa_id, e.nome, e.cnpj, e.segmento,
           e.site, e.resumo, e.o_que_vende, e.natureza,
           e.cidade, e.estado,
           c.nome, c.ordem_prioridade, p.quartos_extras_cota,
           p.vagas_mesa_override, p.status, p.fechado_em, p.enriquecido_em,
           (select count(*) from usuarios_patrocinador u
             where u.empresa_id = p.empresa_id and u.ativo),
           (select count(*) from reservas r
             where r.patrocinador_id = p.id and r.status <> 'cancelado'),
           p.lounge
    from patrocinadores p
    join empresas e on e.id = p.empresa_id
    left join cotas c on c.id = p.cota_id
    join eventos ev on ev.id = p.evento_id and ev.slug = p_evento_slug
    order by c.ordem_prioridade nulls last, e.nome;
end;
$$;

revoke all on function admin_listar_patrocinadores(text) from public, anon;
grant all on function admin_listar_patrocinadores(text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Self-check: confere que as duas funcoes devolvem as colunas novas
-- (formato da linha, sem depender de ter dado real no banco local).
-- ---------------------------------------------------------------------
do $$
declare v_slug text;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);

  perform * from admin_listar_empresas() limit 0;

  select slug into v_slug from eventos limit 1;
  if v_slug is not null then
    perform * from admin_listar_patrocinadores(v_slug) limit 0;
  end if;
end $$;
