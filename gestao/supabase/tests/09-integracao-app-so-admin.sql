-- =====================================================================
-- Integracao com o app do evento e admin-only · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM. Pode rodar contra um banco
-- com dado dentro, quantas vezes quiser, sem `db reset` antes.
--
-- COBRE o achado CRITICO do relatorio de seguranca do Cowork
-- (31/08/2026): a aba "App do evento" e admin-only na TELA, mas as
-- quatro funcoes que ela chama checavam `_exige_staff()` — qualquer
-- staff digitando #integracao-app na URL conseguia exportar nome,
-- e-mail e telefone de participante real. Agora checam `_exige_admin()`.
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

select id as ev from eventos where slug='cerrado2027' \gset

insert into admins (email, nome, role, ativo) values
  ('staff-seg-teste@teste.invalido', 'Staff Teste Seguranca', 'staff', true),
  ('admin-seg-teste@teste.invalido', 'Admin Teste Seguranca', 'admin', true)
on conflict (email_norm) do update set role = excluded.role, ativo = true;

\echo ''
\echo '#############################################'
\echo '# STAFF: as 4 funcoes da integracao devem recusar'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"staff-seg-teste@teste.invalido","role":"authenticated"}';

savepoint s1;
select admin_listar_mapa_empresas_app('cerrado2027');
rollback to s1;

savepoint s2;
select admin_exportar_empresas_app('cerrado2027');
rollback to s2;

savepoint s3;
select admin_exportar_usuarios_app('cerrado2027');
rollback to s3;

savepoint s4;
select admin_salvar_mapa_empresa_app('cerrado2027', null, null, 1);
rollback to s4;

reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# ADMIN: as mesmas 4 continuam funcionando'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"admin-seg-teste@teste.invalido","role":"authenticated"}';

select count(*) as mapa_ok from admin_listar_mapa_empresas_app('cerrado2027');
select count(*) as empresas_ok from admin_exportar_empresas_app('cerrado2027');
select count(*) as usuarios_ok from admin_exportar_usuarios_app('cerrado2027');

reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# STAFF: admin_listar_eventos so mostra evento associado'
\echo '# (mudou em 20260831160000 — antes era liberado pra qualquer evento)'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"staff-seg-teste@teste.invalido","role":"authenticated"}';

select count(*) as staff_sem_associacao_nao_ve_nada from admin_listar_eventos();

reset role;
reset request.jwt.claims;

rollback;
