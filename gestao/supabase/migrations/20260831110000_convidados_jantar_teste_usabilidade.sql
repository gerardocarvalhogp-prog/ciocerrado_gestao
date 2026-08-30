-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Convidados pro jantar avulso de teste ("Empresa Teste Cowork",
-- criado no seed original de usabilidade-teste) — hoje sem nenhum
-- convidado, entao jantares.html/checkin.html?jantar= nao tem nada
-- pra testar. Reaproveita os 4 gestores [TESTE] ja criados como CIO
-- (nao precisa de conta nova nenhuma pra isto).
--
-- 2 confirmados (prontos pra check-in) + 2 so convidados (ainda sem
-- resposta) — cobre os dois estados que jantar_checkin_listar mostra.
-- Idempotente: upsert por (jantar_id, gestor_id).
-- =====================================================================

set search_path = gestao, public;

do $$
declare v_jantar_id uuid;
begin
  select id into v_jantar_id from jantares
   where criado_por = 'seed-teste-usabilidade' and patrocinador_nome = 'Empresa Teste Cowork';
  if v_jantar_id is null then
    raise exception 'Jantar de teste (seed-teste-usabilidade) nao encontrado — abortando';
  end if;

  insert into jantar_convidados (jantar_id, gestor_id, empresa, origem, status)
  select v_jantar_id, g.id, 'Empresa Convidada Teste', 'manual', v.status
  from gestores g
  join (values
    ('tacio.henrique+cio@ciocerrado.com.br',  'confirmado'),
    ('kelson.duarte+cio@ciocerrado.com.br',   'confirmado'),
    ('amarildo.moraes+cio@ciocerrado.com.br', 'convidado'),
    ('comunicacao+cio@ciocerrado.com.br',     'convidado')
  ) as v(email, status) on g.email = v.email
  on conflict (jantar_id, gestor_id) do update set status = excluded.status;
end $$;
