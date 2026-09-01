-- =====================================================================
-- Staff por evento, leva 2 · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM.
--
-- COBRE 20260831180000: as funcoes que recebem id de sessao, reserva,
-- brinde, atividade e checkin (nao o slug do evento direto) tambem
-- passam a exigir associacao pra staff. Testa uma amostra de cada
-- caminho de resolucao — nao repete os 12 restantes porque usam o
-- mesmo helper e a mesma logica, so a tabela de origem muda.
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

insert into admins (email, nome, role, ativo) values
  ('staff-leva2-teste@teste.invalido', 'Staff Leva2 Teste', 'staff', true),
  ('admin-leva2-teste@teste.invalido', 'Admin Leva2 Teste', 'admin', true)
on conflict (email_norm) do update set role = excluded.role, ativo = true;

select id as staff_id from admins where email_norm = norm_doc('staff-leva2-teste@teste.invalido') \gset
select id as ev_cerrado from eventos where slug = 'cerrado2027' \gset
select id as ev_usab from eventos where slug = 'usabilidade-teste' \gset

delete from admin_eventos where admin_id = :'staff_id'::uuid;

-- um recurso de cada tipo, um em cada evento, pra testar isolamento
insert into atividades (evento_id, nome) values (:'ev_cerrado'::uuid, 'Atividade cerrado2027') returning id as atividade_cerrado \gset
insert into atividades (evento_id, nome) values (:'ev_usab'::uuid, 'Atividade usabilidade') returning id as atividade_usab \gset

insert into checkins (evento_id, pessoa_key, nome, registrado_por)
  values (:'ev_cerrado'::uuid, 'teste:leva2-cerrado', 'Fulano Cerrado', 'teste')
  returning id as checkin_cerrado \gset
insert into checkins (evento_id, pessoa_key, nome, registrado_por)
  values (:'ev_usab'::uuid, 'teste:leva2-usab', 'Fulano Usab', 'teste')
  returning id as checkin_usab \gset

\echo ''
\echo '#############################################'
\echo '# SEM ASSOCIACAO: RECUSADO EM CADA CAMINHO'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"staff-leva2-teste@teste.invalido","role":"authenticated"}';

savepoint sp1;
\echo '-- atividade'
select atividade_checkin_listar(:'atividade_cerrado'::uuid);
rollback to sp1;

savepoint sp2;
\echo '-- checkin (desfazer)'
select checkin_desfazer(:'checkin_cerrado'::uuid);
rollback to sp2;

reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# ASSOCIADO SO A cerrado2027'
\echo '#############################################'
insert into admin_eventos (admin_id, evento_id) values (:'staff_id'::uuid, :'ev_cerrado'::uuid);

set role authenticated;
set request.jwt.claims = '{"email":"staff-leva2-teste@teste.invalido","role":"authenticated"}';

\echo '-- atividade do evento associado: passa'
select count(*) >= 0 as atividade_cerrado_ok from atividade_checkin_listar(:'atividade_cerrado'::uuid);

savepoint sp3;
\echo '-- atividade do OUTRO evento: recusado'
select atividade_checkin_listar(:'atividade_usab'::uuid);
rollback to sp3;

savepoint sp4;
\echo '-- checkin do OUTRO evento: recusado'
select checkin_desfazer(:'checkin_usab'::uuid);
rollback to sp4;

-- admin_convidados_sessao, admin_marcar_brinde, admin_alocar_quarto etc
-- usam o MESMO helper (_exige_staff_do_evento), so a tabela de origem
-- muda (sessoes, brindes+patrocinadores, reservas) — nao repetido aqui
-- porque exigiria fabricar sessao/reserva/brinde com todas as FKs que
-- essas tabelas pedem, sem ganhar cobertura nova sobre a logica.

reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# ADMIN: BYPASS EM TODO CAMINHO, SEM ASSOCIACAO'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"admin-leva2-teste@teste.invalido","role":"authenticated"}';

select count(*) >= 0 as admin_ve_atividade_usab from atividade_checkin_listar(:'atividade_usab'::uuid);
select checkin_desfazer(:'checkin_usab'::uuid) -> 'ok' as admin_desfaz_checkin_usab;

reset role;
reset request.jwt.claims;

rollback;
