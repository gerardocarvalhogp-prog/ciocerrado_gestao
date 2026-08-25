-- =====================================================================
-- Rastreio de brindes · gestao CIO Cerrado
--
-- Roda contra o banco LOCAL depois de `supabase db reset` e do
-- 01-cenario-setup.sql, que ja deixa a Alfa com um brinde prometido
-- ("Kit cafe") no primeiro quarto.
--
-- O QUE ESTE TESTE PRENDE
--
--   1. um codigo de rastreio cai em TODOS os brindes prometidos da
--      empresa de uma vez — ela posta uma caixa, nao uma por quarto
--   2. a organizacao ve a lista com quem ainda nao chegou em cima
--   3. voltar o status atras LIMPA as datas: brinde reaberto com data
--      de entrega antiga faz a conferencia da vespera mentir
--   4. patrocinador nao ve nem mexe em brinde de outra empresa
--
-- Nao e idempotente: da `db reset` + 01 antes de rodar de novo.
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

-- ids como postgres, antes de qualquer `set role` (ver tests/LEIA-ME.md)
select id as alfa from patrocinadores where empresa='Alfa Cloud' \gset
select id as beta from patrocinadores where empresa='Beta Seguranca' \gset

-- a Alfa promete brinde no segundo quarto tambem, para haver dois
insert into brindes (patrocinador_id, reserva_id, vai_enviar, descricao)
select :'alfa'::uuid, r.id, true, 'Garrafa termica'
from reservas r
where r.patrocinador_id = :'alfa'::uuid and r.origem = 'cota'
order by r.created_at offset 1 limit 1
-- o `where` repete o predicado do indice: brindes_reserva_uk e PARCIAL
-- (`where reserva_id is not null`), e sem isso o Postgres nao acha a
-- restricao e recusa o on conflict
on conflict (reserva_id) where reserva_id is not null
do update set vai_enviar = true, descricao = excluded.descricao;

select b.id as br1 from brindes b
 where b.patrocinador_id = :'alfa'::uuid and b.descricao = 'Kit cafe' \gset

\echo ''
\echo '#############################################'
\echo '# 1 · a Alfa ve os dois brindes, prometidos'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"ana@alfa.test","role":"authenticated"}';
select quarto, descricao, status, rastreio from patro_meus_brindes(:'alfa'::uuid) order by descricao;

\echo ''
\echo '-- um codigo so, e os DOIS viram enviado:'
select patro_informar_rastreio(:'alfa'::uuid, 'Correios', 'BR123456789BR');
select quarto, descricao, status, transportadora, rastreio,
       enviado_em is not null as tem_data
from patro_meus_brindes(:'alfa'::uuid) order by descricao;

\echo ''
\echo '-- codigo vazio deve FALHAR:'
select patro_informar_rastreio(:'alfa'::uuid, 'Correios', '   ');

\echo ''
\echo '-- corrigir o codigo digitado errado continua funcionando:'
select patro_informar_rastreio(:'alfa'::uuid, 'Correios', 'BR999999999BR');
reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 2 · a Beta nao ve nem mexe no brinde da Alfa'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"bruno@beta.test","role":"authenticated"}';
\echo '-- lista da Beta (deve vir vazia):'
select count(*) as brindes_da_beta from patro_meus_brindes(:'beta'::uuid);
\echo '-- e ler a lista da Alfa deve FALHAR:'
select count(*) from patro_meus_brindes(:'alfa'::uuid);
\echo '-- e informar rastreio pela Alfa deve FALHAR:'
select patro_informar_rastreio(:'alfa'::uuid, 'Sedex', 'XX1');
reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 3 · a organizacao confere e entrega'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"gerardocarvalhogp@gmail.com","role":"authenticated"}';

\echo '-- resumo:'
select admin_brindes_resumo('cerrado2027');

\echo '-- lista (nao chegou primeiro):'
select empresa, quarto, descricao, status, rastreio
from admin_listar_brindes('cerrado2027') order by status, descricao;

\echo ''
\echo '-- marca um como recebido, e o outro como entregue:'
select admin_marcar_brinde(:'br1'::uuid, 'recebido', 'Caixa 1 de 2, sem avaria');
select quarto, descricao, status, recebido_em is not null as tem_recebido,
       recebido_por, entregue_em is not null as tem_entregue
from admin_listar_brindes('cerrado2027') where descricao='Kit cafe';

\echo ''
\echo '-- promove para entregue: mantem a data de recebimento e ganha a de entrega'
select admin_marcar_brinde(:'br1'::uuid, 'entregue');
select descricao, status, recebido_em is not null as tem_recebido,
       entregue_em is not null as tem_entregue, entregue_por
from admin_listar_brindes('cerrado2027') where descricao='Kit cafe';

\echo ''
\echo '-- VOLTAR atras precisa LIMPAR as datas da frente:'
select admin_marcar_brinde(:'br1'::uuid, 'enviado');
select descricao, status,
       enviado_em  is not null as tem_enviado,
       recebido_em is not null as tem_recebido,
       entregue_em is not null as tem_entregue
from admin_listar_brindes('cerrado2027') where descricao='Kit cafe';

\echo ''
\echo '-- status invalido deve FALHAR:'
select admin_marcar_brinde(:'br1'::uuid, 'extraviado');

\echo ''
\echo '-- filtro por status:'
select count(*) as enviados from admin_listar_brindes('cerrado2027', 'enviado');
select count(*) as entregues from admin_listar_brindes('cerrado2027', 'entregue');

\echo ''
\echo '-- resumo final:'
select admin_brindes_resumo('cerrado2027');
reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 4 · anon nao passa'
\echo '#############################################'
set role anon;
set request.jwt.claims = '{"role":"anon"}';
select * from admin_listar_brindes('cerrado2027');
select * from patro_meus_brindes(:'alfa'::uuid);
reset role;
reset request.jwt.claims;
