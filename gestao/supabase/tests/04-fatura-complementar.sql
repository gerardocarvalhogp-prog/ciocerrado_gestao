-- =====================================================================
-- Fatura complementar · gestao CIO Cerrado
--
-- Roda contra o banco LOCAL depois de `supabase db reset` e do
-- 01-cenario-setup.sql (usa o Carlos, que ja tem quarto triplo com
-- Maria e Joao e fatura estimada de 1.500).
--
-- O QUE ESTE TESTE PEGA
--
-- Antes de 20260824102200, mudar o rooming depois de a fatura ser paga
-- criava uma fatura NOVA com o valor CHEIO — o acompanhante ja pago era
-- cobrado outra vez. Aqui a segunda fatura tem que trazer so a
-- diferenca.
--
-- Nao e idempotente: da `db reset` + 01 antes de rodar de novo.
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

-- id antes de trocar de papel: as tabelas sao staff-only na RLS e um
-- subselect rodando como Carlos voltaria vazio (ver tests/LEIA-ME.md)
select f.id as fat
from faturas f
join participantes pa on pa.id = f.participante_id
join gestores g on g.id = pa.gestor_id
where g.email_norm = norm_doc('carlos@cliente.test')
  and f.status = 'estimada' \gset

\echo ''
\echo '#############################################'
\echo '# 1 · estado inicial'
\echo '#############################################'
\echo '-- deve ser UMA fatura estimada de 1500.00 (800 + 400 + 150 + 150):'
select f.status, f.total from faturas f
join participantes pa on pa.id = f.participante_id
join gestores g on g.id = pa.gestor_id
where g.email_norm = norm_doc('carlos@cliente.test');

\echo ''
\echo '#############################################'
\echo '# 2 · a organizacao emite e recebe'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"gerardocarvalhogp@gmail.com","role":"authenticated"}';
select admin_marcar_fatura(:'fat'::uuid, 'emitida');
select admin_marcar_fatura(:'fat'::uuid, 'paga', 'pix');
reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 3 · Carlos mexe no rooming DEPOIS de pagar'
\echo '#     (Joao passa a usar transfer: +150)'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"carlos@cliente.test","role":"authenticated"}';
select part_salvar_rooming('cerrado2027',
  '[{"nome":"Maria","tipo":"adulto","data_nascimento":"1985-03-02","usa_transfer":true},
    {"nome":"Joao","tipo":"crianca","data_nascimento":"2020-05-10","usa_transfer":true}]'::jsonb,
  true, 'BSB');
reset role;
reset request.jwt.claims;

\echo '-- a paga fica intacta em 1500; a nova cobra so os 150 de diferenca:'
select f.status, f.total from faturas f
join participantes pa on pa.id = f.participante_id
join gestores g on g.id = pa.gestor_id
where g.email_norm = norm_doc('carlos@cliente.test')
order by f.status;

\echo ''
\echo '-- itens da complementar: a conta cheia com o abatimento visivel'
\echo '-- (soma tem que dar 150.00):'
select fi.descricao, fi.quantidade, fi.valor_unit, fi.valor_total
from faturas f
join fatura_itens fi on fi.fatura_id = f.id
join participantes pa on pa.id = f.participante_id
join gestores g on g.id = pa.gestor_id
where g.email_norm = norm_doc('carlos@cliente.test')
  and f.status = 'estimada'
order by fi.valor_total desc;

\echo ''
\echo '#############################################'
\echo '# 4 · recalcular de novo nao pode mudar nada'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"gerardocarvalhogp@gmail.com","role":"authenticated"}';
select admin_recalcular_faturas('cerrado2027');
reset role;
reset request.jwt.claims;

\echo '-- continua 1500 paga + 150 estimada:'
select f.status, f.total from faturas f
join participantes pa on pa.id = f.participante_id
join gestores g on g.id = pa.gestor_id
where g.email_norm = norm_doc('carlos@cliente.test')
order by f.status;

\echo ''
\echo '#############################################'
\echo '# 5 · desfazer a mudanca zera a complementar'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"carlos@cliente.test","role":"authenticated"}';
select part_salvar_rooming('cerrado2027',
  '[{"nome":"Maria","tipo":"adulto","data_nascimento":"1985-03-02","usa_transfer":true},
    {"nome":"Joao","tipo":"crianca","data_nascimento":"2020-05-10","usa_transfer":false}]'::jsonb,
  true, 'BSB');
reset role;
reset request.jwt.claims;

\echo '-- a estimada volta a zero e a paga continua de pe:'
select f.status, f.total from faturas f
join participantes pa on pa.id = f.participante_id
join gestores g on g.id = pa.gestor_id
where g.email_norm = norm_doc('carlos@cliente.test')
order by f.status;

\echo ''
\echo '#############################################'
\echo '# 6 · tirar um acompanhante ja pago vira CREDITO'
\echo '#     (total negativo de proposito: e dinheiro devido)'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"carlos@cliente.test","role":"authenticated"}';
select part_salvar_rooming('cerrado2027',
  '[{"nome":"Maria","tipo":"adulto","data_nascimento":"1985-03-02","usa_transfer":true}]'::jsonb,
  true, 'BSB');
reset role;
reset request.jwt.claims;

\echo '-- estimada deve ficar em -400 (a crianca que saiu):'
select f.status, f.total from faturas f
join participantes pa on pa.id = f.participante_id
join gestores g on g.id = pa.gestor_id
where g.email_norm = norm_doc('carlos@cliente.test')
order by f.status;
