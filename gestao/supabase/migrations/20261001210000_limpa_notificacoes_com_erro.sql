-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Apaga as notificacoes com status 'erro' — a tabela "Logs de erro" da
-- aba Equipe acumulou os 403 do Resend das rodadas de teste de hoje
-- (dominio nao verificado, so aceitava mandar pro proprio gmail da
-- conta). A que importava foi reaberta e redirecionada em
-- 20261001200000; o resto e ruido de teste. Pedido do organizador em
-- 01/10/2026.
--
-- Nao mexe em 'enfileirada' nem 'enviada' — so' o estado de erro, que
-- e' o que a tela mostra como "log".
-- =====================================================================

set search_path = gestao, public;

do $$
declare
  v_antes int;
begin
  select count(*) into v_antes from notificacoes where status = 'erro';

  delete from notificacoes where status = 'erro';

  raise notice '% notificacao(oes) com erro apagada(s).', v_antes;
end $$;
