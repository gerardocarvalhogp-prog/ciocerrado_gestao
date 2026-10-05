-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- SO' LISTA, NAO APAGA NADA — passo 1 de 2.
--
-- Acha, no evento REAL "CIO Cerrado Experience 2027", todo
-- `participante` cujo gestor tem e-mail gerardocarvalhogp@gmail.com
-- OU nome contendo "teste" (case-insensitive) — mesmo criterio que o
-- organizador pediu pra achar a fatura de teste "Ana Ribeiro Teste"
-- (R$2.000,00) achada em 29/09/2026, e conferir se ha' mais.
--
-- Imprime cada um via RAISE NOTICE (aparece na saida do `supabase db
-- push`, no terminal) pro organizador conferir a lista ANTES de
-- qualquer remocao de verdade — proxima migration so' depois da
-- confirmacao dele.
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

  raise notice '--- participantes suspeitos de teste no evento real ---';

  for v_linha in
    select pa.id as participante_id, g.nome, g.email, g.empresa,
           coalesce((select sum(f.total) from faturas f
                      where f.participante_id = pa.id and f.status <> 'cancelada'), 0) as total_faturas,
           (select count(*) from faturas f
             where f.participante_id = pa.id and f.status <> 'cancelada') as qtd_faturas
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    where pa.evento_id = v_evento_id
      and (g.email = 'gerardocarvalhogp@gmail.com' or g.nome ilike '%teste%')
    order by g.nome
  loop
    v_total := v_total + 1;
    raise notice '% | % | % | % | % fatura(s), R$ %',
      v_linha.participante_id, v_linha.nome, v_linha.email,
      coalesce(v_linha.empresa, '(sem empresa)'), v_linha.qtd_faturas, v_linha.total_faturas;
  end loop;

  raise notice '--- % participante(s) encontrado(s). Nada foi apagado. ---', v_total;
end $$;
