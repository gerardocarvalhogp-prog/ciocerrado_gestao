-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- funcoes-admin-listas.sql  ·  listagens, relatorios e prospeccao
--
-- Roda DEPOIS de funcoes-admin.sql.
--
-- PAGINACAO: o Data API do Supabase corta a resposta em 1000 linhas.
-- Todo relatorio grande aqui recebe p_limite/p_offset e devolve
-- total_geral em CADA linha - e assim que a tela sabe quando parar de
-- pedir a proxima pagina. O caso critico e o detalhe de check-ins
-- (~130 por patrocinador x 61 empresas).
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 1. RELATORIOS PAGINADOS
-- =====================================================================

create or replace function admin_rel_painel(
  p_evento_slug text, p_limite int default 500, p_offset int default 0
)
returns table (
  nome text, empresa text, email text,
  status_inscricao text, status_contrato text, status_rooming text,
  usa_transfer boolean, quarto text, total_geral bigint
)
language plpgsql stable security definer set search_path = gestao, public as $$
declare v_evento uuid;
begin
  perform exigir_staff();
  v_evento := evento_id_por_slug(p_evento_slug);

  return query
  with base as (
    select v.nome, v.empresa, v.email, v.status_inscricao,
           v.status_contrato, v.status_rooming, v.usa_transfer, v.quarto
    from v_painel_participantes v
    where v.evento_id = v_evento
  )
  select b.*, (select count(*) from base)
  from base b
  order by (b.status_contrato = 'assinado'), (b.status_rooming = 'completo'), b.nome
  limit greatest(coalesce(p_limite,500),1) offset greatest(coalesce(p_offset,0),0);
end;
$$;

create or replace function admin_rel_mailing(
  p_evento_slug text, p_limite int default 500, p_offset int default 0
)
returns table (
  perfil text, nome text, cargo text, empresa text, email text,
  telefone text, cnpj text, segmento text, estado text, total_geral bigint
)
language plpgsql stable security definer set search_path = gestao, public as $$
declare v_evento uuid;
begin
  perform exigir_staff();
  v_evento := evento_id_por_slug(p_evento_slug);

  return query
  with base as (
    select coalesce(g.perfil,'CIO') as perfil, g.nome, g.cargo, g.empresa,
           g.email, g.telefone, g.cnpj, g.segmento, g.estado
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    where pa.evento_id = v_evento and pa.status = 'aprovado'
  )
  select b.*, (select count(*) from base)
  from base b
  order by b.nome
  limit greatest(coalesce(p_limite,500),1) offset greatest(coalesce(p_offset,0),0);
end;
$$;


-- Resumo por patrocinador. Check-in desfeito nao conta.
create or replace function admin_rel_checkins_resumo(p_evento_slug text)
returns table (empresa text, total_checkins bigint)
language plpgsql stable security definer set search_path = gestao, public as $$
begin
  perform exigir_staff();
  return query
  select pt.empresa, count(*)
  from checkins c
  join patrocinadores pt on pt.id = c.patrocinador_id
  where c.evento_id = evento_id_por_slug(p_evento_slug)
    and c.desfeito_em is null
  group by pt.empresa
  order by pt.empresa;
end;
$$;

create or replace function admin_rel_checkins_detalhe(
  p_evento_slug text, p_empresa text,
  p_limite int default 500, p_offset int default 0
)
returns table (nome text, email text, local text,
               registrado_em timestamptz, total_geral bigint)
language plpgsql stable security definer set search_path = gestao, public as $$
declare v_evento uuid;
begin
  perform exigir_staff();
  v_evento := evento_id_por_slug(p_evento_slug);

  return query
  with base as (
    select c.nome, c.email, c.local, c.registrado_em
    from checkins c
    join patrocinadores pt on pt.id = c.patrocinador_id
    where c.evento_id = v_evento
      and c.desfeito_em is null
      and norm_doc(pt.empresa) = norm_doc(p_empresa)
  )
  select b.*, (select count(*) from base)
  from base b
  order by b.registrado_em
  limit greatest(coalesce(p_limite,500),1) offset greatest(coalesce(p_offset,0),0);
end;
$$;

-- =====================================================================
-- 2. PESQUISA DE PERFIL
-- =====================================================================


-- =====================================================================
-- 3. PROSPECCAO
-- =====================================================================


-- =====================================================================
-- 4. PERMISSOES
-- =====================================================================
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'gestao' and p.proname like 'admin%'
  loop
    execute format('revoke execute on function %s from anon', f.sig);
  end loop;
end $$;
