-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Reseta o contrato de teste de "Gerardo Carvalho da Junior" pra
-- "nao_enviado" — pedido do organizador em 01/10/2026: o envio
-- anterior saiu com o integracao.py desatualizado (sem a correcao de
-- e-mail corporativo, commit 2266b94) e foi assinado no e-mail
-- pessoal errado. Limpa autentique_id/autentique_url/enviado_em
-- tambem — sem isso, o proximo --contratos so completaria o envio do
-- MESMO documento antigo (ja assinado errado), em vez de criar um
-- documento novo no Autentique com os signatarios certos.
--
-- Autoconferencia: so segue se achar exatamente UM gestor com esse
-- nome. Mais de um indicaria o cenario que eu tinha levantado como
-- hipotese (gestor duplicado, um com e-mail certo e outro com o
-- errado) — nesse caso a migration para e avisa, em vez de mexer no
-- registro errado.
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
    raise exception 'Nenhum gestor "GERARDO CARVALHO DA JUNIOR" encontrado (nome exato, ja normalizado em maiuscula)';
  end if;
  if v_qtd_gestores > 1 then
    raise exception '% gestores com o nome "GERARDO CARVALHO DA JUNIOR" — provavel duplicata (e-mail certo + e-mail errado). Resolva a duplicata antes de resetar o contrato.', v_qtd_gestores;
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
    status        = 'nao_enviado',
    autentique_id  = null,
    autentique_url = null,
    enviado_em     = null
  where id = v_contrato_id;

  raise notice 'contrato % resetado para nao_enviado (gestor %).', v_contrato_id, v_gestor_id;
end $$;
