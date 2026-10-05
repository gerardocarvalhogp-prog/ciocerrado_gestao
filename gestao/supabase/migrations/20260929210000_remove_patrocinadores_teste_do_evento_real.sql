-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Remove 6 patrocinadores de teste que foram cadastrados por engano
-- direto no evento REAL "CIO Cerrado Experience 2027" (em vez de num
-- evento de teste isolado) — achado pelo organizador em 29/09/2026,
-- que via isso como dado "de outro evento" na tela Financeiro. Nao e'
-- vazamento entre eventos na consulta (conferido: as 4 funcoes do
-- Financeiro ja filtram certo por evento_id) — e' dado de teste
-- gravado no evento errado, provavelmente numa sessao de teste
-- anterior (Cowork ou outra).
--
-- Empresas confirmadas pelo organizador como lixo de teste: Teste
-- Esmeralda Ltda, Da a Dia, QI Network, Teste Diamante S.A., Teste
-- Ouro QA Ltda, Teste Prata ME.
--
-- ON DELETE CASCADE em patrocinadores ja cobre brindes, contratos,
-- faturas, indicacoes, reservas, sessoes (conferido na baseline +
-- migration 20260830110000); checkins/prospeccoes/participantes.
-- indicado_por_patrocinador_id sao SET NULL; usuarios_patrocinador
-- usa empresa_id desde 20260909100000 e so tem patrocinador_id como
-- SET NULL (nao apaga o login, que pode servir outro evento da mesma
-- empresa) — nenhum desses precisa de DELETE manual aqui.
--
-- NAO apaga a linha em `empresas`: mesmo que "Da a Dia"/"QI Network"
-- sejam nomes de teste, apagar a empresa em si e' fora do pedido — so
-- o vinculo (patrocinadores) com o evento real sai.
-- =====================================================================

set search_path = gestao, public;

do $$
declare v_evento_id uuid; v_removidos int; v_nomes text[] := array[
  'Teste Esmeralda Ltda', 'Da a Dia', 'QI Network',
  'Teste Diamante S.A.', 'Teste Ouro QA Ltda', 'Teste Prata ME'
];
begin
  select id into v_evento_id from eventos where nome = 'CIO Cerrado Experience 2027';
  if v_evento_id is null then
    -- 05/10/2026: num banco que nao tem esse dado (db reset do zero, ambiente
    -- de teste) pula em vez de abortar o historico inteiro. No hospedado
    -- esta migration ja rodou; isto nao muda nada la.
    raise notice 'Evento "CIO Cerrado Experience 2027" nao encontrado (busca por nome exato) — pulando: este banco nao tem o dado que esta migration corrige';
    return;
  end if;

  delete from patrocinadores
   where evento_id = v_evento_id
     and empresa = any(v_nomes);
  get diagnostics v_removidos = row_count;

  if v_removidos <> array_length(v_nomes, 1) then
    raise exception 'esperava remover % patrocinador(es) de teste, removeu % — confira nomes/grafia antes de reaplicar',
      array_length(v_nomes, 1), v_removidos;
  end if;

  raise notice '% patrocinador(es) de teste removido(s) do evento "CIO Cerrado Experience 2027".', v_removidos;
end $$;
