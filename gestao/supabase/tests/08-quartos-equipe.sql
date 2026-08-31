-- =====================================================================
-- Quartos da equipe de organizacao · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM. Pode rodar contra um banco
-- com dado dentro, quantas vezes quiser, sem `db reset` antes.
--
-- COBRE o que entrou em 31/08/2026: reserva sem dono (nem patrocinador,
-- nem participante) para hospedar staff e equipe de organizacao.
--   1. so admin cria/edita um quarto de equipe
--   2. salvar pessoas (nome, CPF, transfer) e o teto de 4
--   3. aparece na aba Quartos (admin_listar_alocacao), rotulado pelo
--      rotulo da reserva, e recebe numero por `admin_alocar_quarto`
--      normalmente, do mesmo jeito que patrocinador e CIO
--   4. remover libera o quarto de volta para 'disponivel'
--
-- Raw select em tabela do schema so roda como postgres (`reset role`) —
-- `authenticated` so executa RPC, igual em producao. Ver tests/LEIA-ME.md.
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

-- ---------------------------------------------------------------------
-- CENARIO: usa o evento seed 'cerrado2027' e cria dois quartos so para
-- este teste, para nao depender do inventario que outro teste montou
-- ---------------------------------------------------------------------
select id as ev from eventos where slug='cerrado2027' \gset

insert into quartos (evento_id, numero, tipo, capacidade, status)
values
  (:'ev'::uuid, 'EQ-901', 'duplo', 4, 'disponivel'),
  (:'ev'::uuid, 'EQ-902', 'duplo', 4, 'disponivel')
on conflict (evento_id, numero) where numero is not null do nothing;

\echo ''
\echo '#############################################'
\echo '# 1 · CRIAR E EDITAR'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"ninguem@teste.invalido","role":"authenticated"}';

savepoint s1;
\echo '-- quem nao esta cadastrado como admin nao pode criar quarto de equipe'
select admin_salvar_quarto_equipe('cerrado2027', null, 'Coordenacao', 'duplo');
rollback to s1;
reset role;
reset request.jwt.claims;

-- garante que existe um admin de verdade para o resto do teste
-- (email_norm e coluna GERADA, nao entra no insert)
insert into admins (email, nome, role, ativo)
values ('admin-equipe@teste.invalido', 'Admin Teste', 'admin', true)
on conflict (email_norm) do update set role='admin', ativo=true;

set role authenticated;
set request.jwt.claims = '{"email":"admin-equipe@teste.invalido","role":"authenticated"}';

\echo '-- cria o quarto da coordenacao'
select admin_salvar_quarto_equipe('cerrado2027', null, 'Coordenacao', 'duplo') ->> 'id' as res_coord \gset

\echo '-- edita o rotulo e o tipo do mesmo quarto'
select admin_salvar_quarto_equipe('cerrado2027', :'res_coord'::uuid, 'Coordenacao geral', 'triplo');
reset role;
reset request.jwt.claims;

\echo '-- ficou gravado'
select rotulo, tipo, origem, participante_id, patrocinador_id
  from reservas where id = :'res_coord'::uuid;

\echo ''
\echo '#############################################'
\echo '# 2 · PESSOAS: NOME, CPF, TRANSFER E O TETO DE 4'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"admin-equipe@teste.invalido","role":"authenticated"}';

\echo '-- 3 pessoas, uma com transfer de GYN'
select admin_salvar_ocupantes_equipe(:'res_coord'::uuid,
  '[{"nome":"Fulano","cpf":"11111111111","usa_transfer":true,"transfer_origem":"GYN"},
    {"nome":"Beltrana","cpf":"22222222222"},
    {"nome":"Ciclano"}]'::jsonb) -> 'ocupantes' as esperado_3;

savepoint s2;
\echo '-- 5 pessoas estoura o teto de 4 e recusa'
select admin_salvar_ocupantes_equipe(:'res_coord'::uuid,
  '[{"nome":"A"},{"nome":"B"},{"nome":"C"},{"nome":"D"},{"nome":"E"}]'::jsonb);
rollback to s2;

savepoint s3;
\echo '-- ocupante sem nome recusa'
select admin_salvar_ocupantes_equipe(:'res_coord'::uuid, '[{"nome":""}]'::jsonb);
rollback to s3;

savepoint s4;
\echo '-- origem de transfer fora de GYN/BSB recusa'
select admin_salvar_ocupantes_equipe(:'res_coord'::uuid,
  '[{"nome":"Fulano","usa_transfer":true,"transfer_origem":"SSA"}]'::jsonb);
rollback to s4;
reset role;
reset request.jwt.claims;

\echo '-- as 3 pessoas da chamada valida, com categoria de cracha propria'
select nome, cpf, usa_transfer, transfer_origem, categoria_cracha
  from ocupantes where reserva_id = :'res_coord'::uuid order by created_at;

\echo ''
\echo '#############################################'
\echo '# 3 · APARECE NA ABA QUARTOS E RECEBE NUMERO'
\echo '#############################################'
select id as quarto_livre from quartos
 where evento_id = :'ev'::uuid and numero = 'EQ-901' \gset

set role authenticated;
set request.jwt.claims = '{"email":"admin-equipe@teste.invalido","role":"authenticated"}';

\echo '-- admin_listar_alocacao rotula pelo rotulo da reserva (sem empresa, sem CIO)'
select empresa, count(*) from admin_listar_alocacao('cerrado2027', false)
 where reserva_id = :'res_coord'::uuid group by empresa;

\echo '-- aloca o numero pelo mesmo caminho de sempre'
select admin_alocar_quarto(:'res_coord'::uuid, :'quarto_livre'::uuid) -> 'ok' as alocado_ok;
reset role;
reset request.jwt.claims;

select r.rotulo, q.numero, q.status from reservas r
  join quartos q on q.id = r.quarto_id where r.id = :'res_coord'::uuid;

\echo ''
\echo '#############################################'
\echo '# 4 · REMOVER LIBERA O QUARTO'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"admin-equipe@teste.invalido","role":"authenticated"}';

select admin_remover_quarto_equipe(:'res_coord'::uuid) -> 'ok' as removido_ok;
reset role;
reset request.jwt.claims;

select status from quartos where id = :'quarto_livre'::uuid;
select count(*) as deve_ser_zero from reservas where id = :'res_coord'::uuid;

rollback;
