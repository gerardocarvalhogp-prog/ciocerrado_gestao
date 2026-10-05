-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Remove os participantes de teste do evento REAL "CIO Cerrado
-- Experience 2027" — passo 2 de 2 (a migration anterior,
-- 20260929240000, so' listou via RAISE NOTICE; esta apaga de verdade).
-- Confirmado pelo organizador em 29/09/2026, mesmo criterio ja
-- aprovado: gestor com e-mail gerardocarvalhogp@gmail.com OU nome
-- contendo "teste" (a fatura de R$2.000,00 de "Ana Ribeiro Teste"
-- entra por essa segunda regra).
--
-- DELETE FROM participantes ja cobre, via ON DELETE CASCADE
-- (conferido na baseline): contratos, faturas, reservas,
-- participante_perfil, sessao_convidados. Nao apaga a linha em
-- `gestores` (a pessoa continua no cadastro global — so' o vinculo
-- com este evento sai).
-- =====================================================================

set search_path = gestao, public;

do $$
declare v_evento_id uuid; v_linha record; v_total int := 0;
begin
  select id into v_evento_id from eventos where nome = 'CIO Cerrado Experience 2027';
  if v_evento_id is null then
    -- 05/10/2026: num banco que nao tem esse dado (db reset do zero, ambiente
    -- de teste) pula em vez de abortar o historico inteiro. No hospedado
    -- esta migration ja rodou; isto nao muda nada la.
    raise notice 'Evento "CIO Cerrado Experience 2027" nao encontrado (busca por nome exato) — pulando: este banco nao tem o dado que esta migration corrige';
    return;
  end if;

  for v_linha in
    select pa.id as participante_id, g.nome, g.email
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    where pa.evento_id = v_evento_id
      and (g.email = 'gerardocarvalhogp@gmail.com' or g.nome ilike '%teste%')
  loop
    delete from participantes where id = v_linha.participante_id;
    v_total := v_total + 1;
    raise notice 'removido: % (%)', v_linha.nome, v_linha.email;
  end loop;

  if v_total = 0 then
    raise exception 'nenhum participante de teste encontrado no evento real — confira se a migration 20260929240000 ja mostrou "Ana Ribeiro Teste" antes de reaplicar';
  end if;

  raise notice '--- % participante(s) de teste removido(s) do evento real. ---', v_total;
end $$;
