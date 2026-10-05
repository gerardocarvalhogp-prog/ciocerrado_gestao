-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Limpa a tabela de precos do evento "Teste da Ferramenta 2027" —
-- pedido do organizador em 29/09/2026. precos ja e' por evento em
-- toda camada (front-end manda p_evento_slug, admin_salvar_preco grava
-- evento_id, e ha' unique constraint (evento_id, item, faixa) no
-- banco — conferido, nao e' vazamento entre eventos na consulta).
--
-- O que causou a confusao: os mesmos 6 valores apareciam nos dois
-- eventos porque foram copiados na mao pro evento de teste como ponto
-- de partida — duas linhas por item, uma por evento, com o mesmo
-- numero. Organizador prefere o evento de teste sem preco nenhum, pra
-- nao repetir a duvida.
-- =====================================================================

set search_path = gestao, public;

do $$
declare v_evento_id uuid; v_removidos int;
begin
  select id into v_evento_id from eventos where nome = 'Teste da Ferramenta 2027';
  if v_evento_id is null then
    -- 05/10/2026: num banco que nao tem esse dado (db reset do zero, ambiente
    -- de teste) pula em vez de abortar o historico inteiro. No hospedado
    -- esta migration ja rodou; isto nao muda nada la.
    raise notice 'Evento "Teste da Ferramenta 2027" nao encontrado (busca por nome exato) — pulando: este banco nao tem o dado que esta migration corrige';
    return;
  end if;

  delete from precos where evento_id = v_evento_id;
  get diagnostics v_removidos = row_count;

  raise notice '% preco(s) removido(s) do evento "Teste da Ferramenta 2027".', v_removidos;
end $$;
