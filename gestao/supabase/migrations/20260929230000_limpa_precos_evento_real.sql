-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Limpa a tabela de precos do evento REAL "CIO Cerrado Experience
-- 2027" — pedido do organizador em 29/09/2026: os 6 valores
-- (acompanhante_adulto, crianca x3 faixas, quarto_duplo, quarto_single)
-- nao sao preco de verdade nem la', mesmo coincidencia de numero com
-- o que tinha sido copiado pro evento de teste (ja limpo na migration
-- 20260929220000). Fica vazio ate' o organizador cadastrar os valores
-- reais.
-- =====================================================================

set search_path = gestao, public;

do $$
declare v_evento_id uuid; v_removidos int;
begin
  select id into v_evento_id from eventos where nome = 'CIO Cerrado Experience 2027';
  if v_evento_id is null then
    raise exception 'Evento "CIO Cerrado Experience 2027" nao encontrado (busca por nome exato)';
  end if;

  delete from precos where evento_id = v_evento_id;
  get diagnostics v_removidos = row_count;

  raise notice '% preco(s) removido(s) do evento "CIO Cerrado Experience 2027".', v_removidos;
end $$;
