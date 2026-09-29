-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Vincula mais 17 CIOs aleatorios ao evento de teste "Teste da
-- Ferramenta 2027" — pedido do organizador em 29/09/2026, repondo
-- gente pro evento de teste depois de uma remocao que saiu do lugar
-- errado (evento real, ja corrigida separadamente).
--
-- Mesmo padrao da migration 20260929190000 (30 CIOs), com uma
-- diferenca: exclui explicitamente quem ja foi vinculado por aquele
-- seed ou por qualquer outro participante existente do evento, pra
-- garantir 17 NOVOS, nao repetir gente que ja esta' la'.
-- =====================================================================

set search_path = gestao, public;

do $$
declare v_evento_id uuid; v_vinculados int;
begin
  select id into v_evento_id from eventos where nome = 'Teste da Ferramenta 2027';
  if v_evento_id is null then
    raise exception 'Evento "Teste da Ferramenta 2027" nao encontrado (busca por nome exato)';
  end if;

  insert into participantes (evento_id, gestor_id, status, origem, aprovado_em, aprovado_por)
  select v_evento_id, g.id, 'aprovado', 'manual', now(), 'seed-cios-teste-17-extra'
  from (
    select id from gestores
    where id not in (select gestor_id from participantes where evento_id = v_evento_id)
    order by random()
    limit 17
  ) g
  on conflict (evento_id, gestor_id) do nothing;

  select count(*) into v_vinculados from participantes
   where evento_id = v_evento_id and aprovado_por = 'seed-cios-teste-17-extra';

  raise notice '% CIO(s) novo(s) vinculado(s) ao evento "Teste da Ferramenta 2027" por este seed.', v_vinculados;
end $$;
