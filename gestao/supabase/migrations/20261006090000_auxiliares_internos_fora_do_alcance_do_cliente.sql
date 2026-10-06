-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Auxiliares internos (_*) deixam de ser executaveis por anon e
-- authenticated.
--
-- Auditoria de 06/10/2026 (pedido do organizador, item "26 funcoes
-- admin_* cuja guarda nao foi confirmada", docs/PERGUNTAS.md #11):
-- toda funcao admin_*/jantar_* checa papel na primeira linha — as 26 da
-- apuracao de 01/09 eram falha do padrao de busca de la, nao falta de
-- guarda. O que sobrou foi outra coisa: 28 auxiliares internos (nome
-- comecando com _) executaveis por qualquer usuario logado, porque o
-- Postgres da EXECUTE a PUBLIC por padrao e so alguns tinham REVOKE —
-- o mesmo buraco de _jantar_enfileirar_whatsapp_confirmacao
-- (20261005140000). Os que importam: _preco_item (preco de qualquer
-- evento pelo id), _gestor_do_pessoa_key (cracha -> gestor),
-- _meu_participante, _idade_no_evento; os demais sao calculo puro ou as
-- proprias guardas _exige_*.
--
-- Conferido antes: nenhum deles e chamado por funcao SECURITY INVOKER,
-- por view, pelas telas (rpc) nem pelas Edge Functions / integracao.py
-- — so de dentro de funcoes SECURITY DEFINER, que rodam como o dono e
-- nao precisam do grant. Funcao de trigger fica de fora (nao e chamada
-- por RPC).
--
-- O teste 23 passa a conferir isso no catalogo: auxiliar _* novo que
-- nascer exposto volta a aparecer la.
-- =====================================================================

set search_path = gestao, public;

do $$
declare v record; v_n int := 0;
begin
  for v in
    select p.oid::regprocedure as fn
    from pg_proc p
    where p.pronamespace = 'gestao'::regnamespace
      and p.proname like '\_%'
      and p.prorettype <> 'trigger'::regtype
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v.fn);
    v_n := v_n + 1;
  end loop;
  raise notice '% auxiliar(es) _* fechado(s) para anon/authenticated', v_n;
end $$;

-- autoconfere
do $$
declare v_expostos text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_expostos
  from pg_proc p
  where p.pronamespace = 'gestao'::regnamespace
    and p.proname like '\_%'
    and p.prorettype <> 'trigger'::regtype
    and (has_function_privilege('anon', p.oid, 'execute')
         or has_function_privilege('authenticated', p.oid, 'execute'));
  if v_expostos is not null then
    raise exception 'auxiliar(es) ainda exposto(s): %', v_expostos;
  end if;
end $$;
