-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Revisao de arquitetura (10/09/2026): CREATE OR REPLACE VIEW reseta
-- security_invoker pro padrao (false). v_pendencias_fatos/v_pendencias
-- (redefinidas por ultimo em 20260909150000_bloco3_arquivos_logos.sql)
-- e v_etiquetas/v_esperados (redefinidas por ultimo em
-- 20260901110000_acompanhante_vira_familiar.sql) perderam o ajuste
-- feito em 20260831130000/20260830160000/20260824120000 e voltaram a
-- rodar com dono (postgres), ignorando RLS.
--
-- Hoje isso e' inofensivo so' porque nenhuma migration reconcede
-- SELECT a anon/authenticated nessas views (conferido nos 94 arquivos)
-- — protecao incidental, nao deliberada. Uma migration futura que
-- exponha qualquer uma delas pra leitura direta reabriria, sem aviso,
-- o mesmo vazamento que 20260824120000_fecha_views_para_anon.sql
-- fechou (lista completa de convidados vazando pra anon).
-- =====================================================================

set search_path = gestao, public;

alter view v_pendencias_fatos set (security_invoker = true);
alter view v_pendencias set (security_invoker = true);
alter view v_etiquetas set (security_invoker = true);
alter view v_esperados set (security_invoker = true);

-- mesmo padrao de autoverificacao de 20260824120000_fecha_views_para_anon.sql:
-- a migration confere o proprio invariante antes de terminar, em vez de
-- confiar que os ALTER VIEW acima bastaram.
do $$
declare v_sem_invoker text;
begin
  select string_agg(c.relname, ', ' order by c.relname)
    into v_sem_invoker
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'gestao'
     and c.relkind = 'v'
     and c.relname in ('v_pendencias_fatos','v_pendencias','v_etiquetas','v_esperados')
     and coalesce(array_to_string(c.reloptions, ','), '') not ilike '%security_invoker=true%';

  if v_sem_invoker is not null then
    raise exception 'security_invoker nao aplicado em: %', v_sem_invoker;
  end if;
end $$;
