-- =====================================================================
-- Fatura congelada · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM. Nao precisa de `db reset`.
--
-- SUBSTITUI o antigo 04-fatura-complementar.sql, que afirmava um
-- comportamento que nao existe mais.
--
-- A REGRA DE HOJE
--
-- Enquanto a fatura esta `estimada`, ela e recalculada do zero a cada
-- save do rooming. Depois de `emitida` ou `paga`, o recalculo PARA e
-- devolve o valor travado: mudanca no rooming depois disso nao gera
-- cobranca nenhuma.
--
-- QUAL ERA A OUTRA REGRA
--
-- Uma implementacao anterior emitia uma fatura complementar com a
-- DIFERENCA, e virava credito quando o valor caia. As duas impedem a
-- cobranca dobrada; a diferenca e ir atras do dinheiro ou nao. Ficou a
-- versao conservadora, e este teste prende ela — se um dia a decisao
-- mudar, e este arquivo que muda junto.
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

update eventos set status='aberto', data_inicio='2027-08-11', data_fim='2027-08-15',
       prazo_rooming='2027-07-20' where slug='cerrado2027';
update precos set valor=300 where item='acompanhante_adulto';
update precos set valor=150 where item='transfer';

insert into gestores (nome,email,empresa,cargo)
values ('CIO Fatura','cio-fatura@teste.invalido','Empresa F','CIO')
on conflict (email_norm) do nothing;

insert into participantes (evento_id,gestor_id,status,origem,aprovado_em)
select e.id,g.id,'aprovado','manual',now() from eventos e, gestores g
 where e.slug='cerrado2027' and g.email_norm=norm_doc('cio-fatura@teste.invalido');

insert into contratos (participante_id,status,assinado_em)
select pa.id,'assinado',now() from participantes pa join gestores g on g.id=pa.gestor_id
 where g.email_norm=norm_doc('cio-fatura@teste.invalido');

select pa.id as p from participantes pa join gestores g on g.id=pa.gestor_id
 where g.email_norm=norm_doc('cio-fatura@teste.invalido') \gset

\echo ''
\echo '#############################################'
\echo '# 1 · enquanto e estimada, acompanha o rooming'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cio-fatura@teste.invalido","role":"authenticated"}';

\echo '-- 2 adultos (1 cortesia + 1 pago) + 2 transfers = 600'
select part_salvar_rooming('cerrado2027',
  '[{"nome":"Conjuge","tipo":"adulto","usa_transfer":true,"transfer_origem":"GYN"},
    {"nome":"Socio","tipo":"adulto","usa_transfer":false}]'::jsonb,
  true, 'GYN') -> 'total' as total;

\echo '-- tira o segundo adulto: cai para 300 (so os 2 transfers)'
select part_salvar_rooming('cerrado2027',
  '[{"nome":"Conjuge","tipo":"adulto","usa_transfer":true,"transfer_origem":"GYN"}]'::jsonb,
  true, 'GYN') -> 'total' as total;
reset role;

\echo ''
\echo '#############################################'
\echo '# 2 · emitida e paga congelam o valor'
\echo '#############################################'
select f.id as fat from faturas f where f.participante_id = :'p'::uuid
   and f.status='estimada' \gset

set role authenticated;
set request.jwt.claims = '{"email":"gerardocarvalhogp@gmail.com","role":"authenticated"}';
select admin_marcar_fatura(:'fat'::uuid,'emitida') -> 'para' as agora;
reset role;

set role authenticated;
set request.jwt.claims = '{"email":"cio-fatura@teste.invalido","role":"authenticated"}';
\echo '-- acrescenta gente depois de emitida: o valor NAO muda'
select part_salvar_rooming('cerrado2027',
  '[{"nome":"Conjuge","tipo":"adulto","usa_transfer":true,"transfer_origem":"GYN"},
    {"nome":"Socio","tipo":"adulto","usa_transfer":true,"transfer_origem":"BSB"},
    {"nome":"Terceiro","tipo":"adulto","usa_transfer":true,"transfer_origem":"GYN"}]'::jsonb,
  true, 'GYN') -> 'total' as continua_travado;
reset role;

\echo '-- uma fatura so, no valor congelado:'
select f.status, f.total from faturas f
 where f.participante_id = :'p'::uuid order by f.status;

\echo ''
\echo '-- e os ocupantes MUDARAM mesmo (a trava e da conta, nao do rooming):'
set role authenticated;
set request.jwt.claims = '{"email":"cio-fatura@teste.invalido","role":"authenticated"}';
select count(*) as pessoas from part_listar_rooming('cerrado2027');
reset role;
reset request.jwt.claims;

rollback;

\echo ''
\echo '### transacao desfeita — o banco ficou como estava ###'
