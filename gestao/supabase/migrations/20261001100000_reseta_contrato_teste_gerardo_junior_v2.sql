-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Segunda rodada: o reenvio anterior (20261001090000) saiu certo no
-- banco, mas --contratos nao re-sincroniza e-mail — so manda pro que
-- ja esta gravado em gestores.email. Esse gestor de teste nunca teve
-- "E-mail corporativo" preenchido na inscricao do Sympla, entao foi
-- pro pessoal de novo. Pedido do organizador em 01/10/2026: resetar
-- outra vez, depois de corrigir o e-mail na mao pela aba Cadastro.
--
-- Mesma logica de 20261001090000 (autoconfere gestor unico antes de
-- mexer), sem repetir comentario.
-- =====================================================================

set search_path = gestao, public;

do $$
declare
  v_gestor_id uuid;
  v_qtd_gestores int;
  v_contrato_id uuid;
begin
  select count(*) into v_qtd_gestores from gestores
   where nome = 'GERARDO CARVALHO DA JUNIOR';

  if v_qtd_gestores = 0 then
    -- 05/10/2026: num banco que nao tem esse dado (db reset do zero, ambiente
    -- de teste) pula em vez de abortar o historico inteiro. No hospedado
    -- esta migration ja rodou; isto nao muda nada la.
    raise notice 'Nenhum gestor "GERARDO CARVALHO DA JUNIOR" encontrado — pulando: este banco nao tem o dado que esta migration corrige';
    return;
  end if;
  if v_qtd_gestores > 1 then
    raise exception '% gestores com esse nome — resolva a duplicata antes de resetar', v_qtd_gestores;
  end if;

  select id into v_gestor_id from gestores where nome = 'GERARDO CARVALHO DA JUNIOR';

  select ct.id into v_contrato_id
  from contratos ct
  join participantes pa on pa.id = ct.participante_id
  where pa.gestor_id = v_gestor_id;

  if v_contrato_id is null then
    raise exception 'Nenhum contrato encontrado para esse gestor';
  end if;

  update contratos set
    status         = 'nao_enviado',
    autentique_id  = null,
    autentique_url = null,
    enviado_em     = null
  where id = v_contrato_id;

  raise notice 'contrato % resetado de novo (gestor %) — confira o e-mail em Cadastro antes de rodar --contratos.', v_contrato_id, v_gestor_id;
end $$;
