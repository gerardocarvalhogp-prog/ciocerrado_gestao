-- =====================================================================
-- Seguranca: papeis (chave de servico, admin inativo), e invariantes do
-- catalogo que o CLAUDE.md afirma e que so tinham sido conferidos a mao
-- em 25/08 · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM — mesmo padrao de 07 e 12.
-- Quase tudo aqui e consulta ao catalogo (pg_proc, pg_class...): vale
-- pro schema inteiro, nao so pras migrations recentes — e por isso pega
-- funcao NOVA que esquecer a regra, sem ninguem precisar lembrar de
-- escrever teste pra ela.
--
-- COBRE:
--
--   1. is_admin()/is_staff() aceitam a chave service_role (JWT sem
--      e-mail) e recusam quem nao esta ativo em admins
--      (20260902150000 -> 20260909210000)
--   2. nenhum papel de cliente (anon/authenticated) le tabela ou view
--      do schema — so RPC (CLAUDE.md, "tres armadilhas", 1)
--   3. toda view com security_invoker (20260910090000; reafirmado em
--      20261001170000 e 20261001240000) e toda tabela com RLS ligada;
--      segmentos com policy (20260918100000)
--   4. indices de 20260918090000, inclusive o unico de reserva ativa
--   5. o que anon executa: so o que precisa funcionar sem login
--   6. sem funcao duplicada por assinatura (overload orfao)
--   7. funcao que recebe p_evento_slug respeita o escopo de staff por
--      evento de 10/11
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

insert into admins (email,nome,role,ativo) values
  ('cob23-admin@teste.invalido','Admin Cob23','admin',true),
  ('cob23-inativo@teste.invalido','Admin Inativo Cob23','admin',false);
insert into eventos (slug,nome,status) values ('cob23','Cobertura 23','aberto');

\echo ''
\echo '#############################################'
\echo '# 1 · CHAVE DE SERVICO E ADMIN INATIVO'
\echo '#############################################'
set role service_role;
set request.jwt.claims = '{"role":"service_role"}';
\echo '-- service_role (integracao.py, Edge Functions, daemon) passa como admin e staff — deve PASSAR'
select is_admin() and is_staff() as service_role_ok;
select admin_salvar_atividade(null,'cob23','Atividade Cob23',null,null,null,null,'geral') ->> 'ok' = 'true' as service_role_chama_admin_ok;

set role authenticated;
set request.jwt.claims = '{"email":"cob23-admin@teste.invalido","role":"authenticated"}';
\echo '-- admin ativo — deve PASSAR'
select is_admin() as admin_ativo_ok;

set request.jwt.claims = '{"email":"cob23-inativo@teste.invalido","role":"authenticated"}';
\echo '-- admin desativado nao e admin nem staff — deve PASSAR'
select not is_admin() and not is_staff() as inativo_barrado_ok;
savepoint s_inativo;
\echo '-- admin desativado chama funcao de admin — deve FALHAR'
select admin_salvar_atividade(null,'cob23','X',null,null,null,null,'geral');
rollback to s_inativo;

set request.jwt.claims = '{"email":"qualquer@teste.invalido","role":"authenticated"}';
\echo '-- logado sem cadastro em admins: nada — deve PASSAR'
select not is_admin() and not is_staff() as desconhecido_barrado_ok;

reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 2 · NENHUM PAPEL DE CLIENTE LE TABELA OU VIEW'
\echo '#############################################'
\echo '-- anon e authenticated sem SELECT/INSERT/UPDATE/DELETE em tabela e view do gestao — deve PASSAR'
select count(*) = 0 as sem_leitura_direta_ok
from pg_class c
where c.relnamespace = 'gestao'::regnamespace and c.relkind in ('r','v','m','p')
  and (has_table_privilege('anon', c.oid, 'select,insert,update,delete')
       or has_table_privilege('authenticated', c.oid, 'select,insert,update,delete'));

\echo ''
\echo '#############################################'
\echo '# 3 · SECURITY_INVOKER, RLS, POLICY'
\echo '#############################################'
\echo '-- toda view do gestao com security_invoker=true — deve PASSAR'
select coalesce(string_agg(c.relname, ', '), '') = '' as views_invoker_ok
from pg_class c
where c.relnamespace='gestao'::regnamespace and c.relkind='v'
  and not coalesce(c.reloptions @> array['security_invoker=true'], false);
\echo '-- toda tabela do gestao com RLS ligada — deve PASSAR'
select coalesce(string_agg(relname, ', '), '') = '' as rls_ok
from pg_class where relnamespace='gestao'::regnamespace and relkind='r' and not relrowsecurity;
\echo '-- segmentos tem policy (padrao das tabelas de lookup) — deve PASSAR'
select count(*) >= 1 as segmentos_policy_ok from pg_policies where schemaname='gestao' and tablename='segmentos';

\echo ''
\echo '#############################################'
\echo '# 4 · INDICES DE 20260918090000'
\echo '#############################################'
\echo '-- os 8 indices de suporte + o unico de reserva ativa por participante — deve PASSAR'
select count(*) = 9 as indices_ok from pg_indexes
where schemaname='gestao' and indexname in (
  'reservas_participante_ativa_uk','faturas_evento_status_ix','faturas_participante_ix',
  'faturas_patrocinador_ix','reservas_evento_ix','sessoes_patrocinador_ix',
  'indicacoes_evento_ix','indicacoes_gestor_ix','contratos_participante_ix');

\echo ''
\echo '#############################################'
\echo '# 5 · O QUE ANON EXECUTA'
\echo '#############################################'
\echo '-- o que PRECISA funcionar sem login continua liberado: autocadastro,'
\echo '-- pre-cadastro por link, e os dois helpers que as telas chamam antes do login — deve PASSAR'
select bool_and(has_function_privilege('anon', p.oid, 'execute')) and count(*) = 5 as anon_precisa_ok
from pg_proc p where p.pronamespace='gestao'::regnamespace
  and p.proname in ('part_autocadastro','pre_cadastro_obter','pre_cadastro_enviar','is_staff','meus_patrocinadores');

\echo '-- e NENHUMA outra SECURITY DEFINER e executavel por anon: ela roda com o dono'
\echo '-- (postgres), entao anon executar e anon escrever onde ela escreve. O helper de'
\echo '-- WhatsApp estava aqui ate 20261005140000 — deve PASSAR'
select coalesce(string_agg(p.proname, ', '), '') = '' as nenhuma_definer_exposta_ok
from pg_proc p
where p.pronamespace='gestao'::regnamespace and p.prosecdef
  and has_function_privilege('anon', p.oid, 'execute')
  and p.prorettype <> 'trigger'::regtype
  and p.proname not in ('part_autocadastro','pre_cadastro_obter','pre_cadastro_enviar','is_staff','meus_patrocinadores');

\echo ''
\echo '#############################################'
\echo '# 6 · SEM OVERLOAD ORFAO'
\echo '#############################################'
\echo '-- nenhum nome de funcao com mais de uma assinatura: CREATE OR REPLACE com'
\echo '-- assinatura nova cria uma SEGUNDA funcao em vez de trocar (consertado em'
\echo '-- admin_salvar_cota em 20260909170000 e em admin_salvar_atividade em'
\echo '-- 20261005130000) — deve PASSAR'
select coalesce(string_agg(proname, ', '), '') = '' as sem_overload_ok
from (select proname from pg_proc where pronamespace='gestao'::regnamespace
      group by proname having count(*) > 1) x;

\echo ''
\echo '#############################################'
\echo '# 7 · ESCOPO DE STAFF POR EVENTO'
\echo '#############################################'
\echo '-- nenhuma funcao que recebe p_evento_slug checa so _exige_staff() — staff de'
\echo '-- OUTRO evento leria os dados deste. As 6 que restavam foram fechadas em'
\echo '-- 20261005110000; o 13 e o 14 provam rodando como staff de fora — deve PASSAR'
select coalesce(string_agg(p.proname, ', '), '') = '' as escopo_por_evento_ok
from pg_proc p
where p.pronamespace='gestao'::regnamespace
  and pg_get_function_arguments(p.oid) like '%p_evento_slug%'
  and p.prosrc ~ '_exige_staff\(\)'
  and p.prosrc !~ '_exige_staff_do_evento|_exige_admin\(\)';

rollback;

\echo ''
\echo '### transacao desfeita — o banco ficou como estava ###'
