-- =====================================================================
-- Staff escopado por evento · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM. Pode rodar contra um banco
-- com dado dentro, quantas vezes quiser, sem `db reset` antes.
--
-- COBRE o que entrou em 31/08/2026 (migration 20260831160000): staff
-- so enxerga o evento que esta associado em `admin_eventos`; admin
-- continua vendo todo evento, sem excecao. Antes desta migration,
-- qualquer staff via qualquer evento so por ter linha ativa em
-- `admins` — achado informativo do relatorio de seguranca do Cowork.
--
--   1. staff sem associacao nenhuma nao ve nenhum evento, em nenhuma
--      das 22 funcoes trocadas (aqui testa uma amostra: etiquetas,
--      atividades, quartos livres, checkin_resumo)
--   2. associado a cerrado2027 apenas: ve dado de cerrado2027,
--      recusado em usabilidade-teste
--   3. admin_listar_eventos devolve so o associado pra staff, os dois
--      pra quem e admin
--   4. admin gerencia a associacao (admin_listar_eventos_membro /
--      admin_definir_eventos_membro) e ISSO SIM exige admin
--   5. admin continua com acesso total, associado ou nao (bypass)
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

insert into admins (email, nome, role, ativo) values
  ('staff-evento-teste@teste.invalido', 'Staff Escopado Teste', 'staff', true),
  ('admin-evento-teste@teste.invalido', 'Admin Escopado Teste', 'admin', true)
on conflict (email_norm) do update set role = excluded.role, ativo = true;

select id as staff_id from admins where email_norm = norm_doc('staff-evento-teste@teste.invalido') \gset
select id as ev_cerrado from eventos where slug = 'cerrado2027' \gset
select id as ev_usab from eventos where slug = 'usabilidade-teste' \gset

-- limpa associacao herdada do backfill da migration (rodou pra TODO
-- staff ativo no momento em que ela subiu) — este teste comeca do zero
delete from admin_eventos where admin_id = :'staff_id'::uuid;

\echo ''
\echo '#############################################'
\echo '# 1 · SEM ASSOCIACAO NENHUMA: NAO VE NADA'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"staff-evento-teste@teste.invalido","role":"authenticated"}';

savepoint s1;
select admin_etiquetas_resumo('cerrado2027');
rollback to s1;

savepoint s2;
select admin_listar_atividades('cerrado2027');
rollback to s2;

savepoint s3;
select admin_quartos_livres('cerrado2027');
rollback to s3;

savepoint s4;
select checkin_resumo('cerrado2027');
rollback to s4;

select count(*) as eventos_visiveis_sem_associacao from admin_listar_eventos();

reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 2 · ASSOCIADO SO A cerrado2027'
\echo '#############################################'
insert into admin_eventos (admin_id, evento_id) values (:'staff_id'::uuid, :'ev_cerrado'::uuid);

set role authenticated;
set request.jwt.claims = '{"email":"staff-evento-teste@teste.invalido","role":"authenticated"}';

\echo '-- cerrado2027: passa'
select checkin_resumo('cerrado2027') is not null as ve_cerrado2027;

savepoint s5;
\echo '-- usabilidade-teste: continua recusado'
select checkin_resumo('usabilidade-teste');
rollback to s5;

select slug from admin_listar_eventos();

reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 3 · GERENCIAR A ASSOCIACAO EXIGE ADMIN'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"staff-evento-teste@teste.invalido","role":"authenticated"}';

savepoint s6;
select admin_definir_eventos_membro(:'staff_id'::uuid, array[:'ev_usab'::uuid]);
rollback to s6;

reset role;
reset request.jwt.claims;

set role authenticated;
set request.jwt.claims = '{"email":"admin-evento-teste@teste.invalido","role":"authenticated"}';

select evento_nome, associado from admin_listar_eventos_membro(:'staff_id'::uuid) order by evento_nome;

select admin_definir_eventos_membro(:'staff_id'::uuid, array[:'ev_cerrado'::uuid, :'ev_usab'::uuid]) -> 'eventos' as agora_dois;

reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 4 · DEPOIS DE ASSOCIAR OS DOIS, STAFF VE OS DOIS'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"staff-evento-teste@teste.invalido","role":"authenticated"}';

select count(*) as agora_ve_dois from admin_listar_eventos();
select checkin_resumo('usabilidade-teste') is not null as ve_usabilidade_agora;

reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 5 · ADMIN NUNCA PRECISA DE ASSOCIACAO (BYPASS)'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"admin-evento-teste@teste.invalido","role":"authenticated"}';

select count(*) as admin_ve_tudo_sem_linha_em_admin_eventos from admin_listar_eventos();
select checkin_resumo('cerrado2027') is not null as admin_acessa_qualquer_evento;

reset role;
reset request.jwt.claims;

rollback;
