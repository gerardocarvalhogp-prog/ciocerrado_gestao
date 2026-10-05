-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Copia a tabela de precos do evento REAL "CIO Cerrado Experience
-- 2027" pro evento de teste "Teste da Ferramenta 2027" — pedido do
-- organizador em 29/09/2026, depois de cadastrar os valores de
-- verdade no evento real (as duas tabelas tinham sido zeradas nas
-- migrations 20260929220000/20260929230000).
--
-- Idempotente: on conflict atualiza o valor em vez de duplicar, pode
-- rodar de novo se o organizador ajustar o preco real e quiser
-- replicar outra vez.
-- =====================================================================

set search_path = gestao, public;

do $$
declare v_real_id uuid; v_teste_id uuid; v_copiados int;
begin
  select id into v_real_id from eventos where nome = 'CIO Cerrado Experience 2027';
  if v_real_id is null then
    -- 05/10/2026: num banco que nao tem esse dado (db reset do zero, ambiente
    -- de teste) pula em vez de abortar o historico inteiro. No hospedado
    -- esta migration ja rodou; isto nao muda nada la.
    raise notice 'Evento "CIO Cerrado Experience 2027" nao encontrado (busca por nome exato) — pulando: este banco nao tem o dado que esta migration corrige';
    return;
  end if;

  select id into v_teste_id from eventos where nome = 'Teste da Ferramenta 2027';
  if v_teste_id is null then
    raise exception 'Evento "Teste da Ferramenta 2027" nao encontrado (busca por nome exato)';
  end if;

  insert into precos (evento_id, item, descricao, valor, idade_min, idade_max)
  select v_teste_id, item, descricao, valor, idade_min, idade_max
  from precos
  where evento_id = v_real_id
  on conflict (evento_id, item, coalesce(idade_min,-1), coalesce(idade_max,999))
  do update set valor = excluded.valor, descricao = excluded.descricao;

  get diagnostics v_copiados = row_count;

  if v_copiados = 0 then
    raise exception 'nenhum preco encontrado no evento real pra copiar — cadastre os valores la primeiro';
  end if;

  raise notice '% preco(s) copiado(s) do evento real pro evento de teste.', v_copiados;
end $$;
