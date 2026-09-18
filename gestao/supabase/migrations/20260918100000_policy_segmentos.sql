-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- segmentos tinha RLS ligada (20260828190000) mas nenhuma policy —
-- nao era furo (deny-by-default, e o unico acesso real e' via
-- admin_listar_segmentos, SECURITY DEFINER, que ignora RLS), mas
-- quebrava o padrao que as outras tabelas de lookup do mesmo tipo
-- seguem (categorias_quarto, etapas_config, atividades...), todas com
-- policy staff_all explicita. Achado na revisao de arquitetura de
-- 10/09/2026 — por consistencia, nao por correcao de furo.
-- =====================================================================

set search_path = gestao, public;

create policy segmentos_staff_all on segmentos using (is_staff());
