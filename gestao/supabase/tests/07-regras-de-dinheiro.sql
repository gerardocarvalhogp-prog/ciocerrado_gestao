-- =====================================================================
-- Regras de dinheiro · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM. Pode rodar contra um banco
-- com dado dentro, quantas vezes quiser, sem `db reset` antes.
--
-- Foi assim que precisou ser: o banco local passou a ter a importacao
-- real do CADASTRO 2025, e a bateria antiga exigia banco limpo. Teste
-- que so roda em banco vazio e teste que nao roda.
--
-- COBRE as regras decididas em 25-26/08/2026:
--   1. cortesia de um acompanhante adulto por CIO
--   2. teto de 4 pessoas por quarto
--   3. transfer por pessoa, com origem por pessoa
--   4. brinde da empresa, com custo se for entregue no quarto
--   5. preco do quarto adicional visivel na disponibilidade
--   6. correcao do tipo de uma faixa de quartos
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

-- ---------------------------------------------------------------------
-- CENARIO, todo dentro da transacao
-- ---------------------------------------------------------------------
update eventos set status='aberto', data_inicio='2027-08-11', data_fim='2027-08-15',
       prazo_rooming='2027-07-20'
 where slug='cerrado2027';

update precos set valor=300  where item='acompanhante_adulto';
update precos set valor=150  where item='transfer';
update precos set valor=500  where item='quarto_duplo';

insert into precos (evento_id, item, valor, descricao)
select id,'entrega_brinde_quarto',25,'Entrega no quarto' from eventos where slug='cerrado2027'
on conflict do nothing;
update precos set valor=25 where item='entrega_brinde_quarto';

-- crianca: 0-6 cortesia, 7+ paga. Ajustado aqui para o teste nao
-- depender de como o preco esta configurado no evento de verdade.
delete from precos where item='crianca';
insert into precos (evento_id, item, valor, descricao, idade_min, idade_max)
select id,'crianca',0,'Crianca ate 6',0,6 from eventos where slug='cerrado2027';
insert into precos (evento_id, item, valor, descricao, idade_min, idade_max)
select id,'crianca',250,'Crianca 7+',7,17 from eventos where slug='cerrado2027';

insert into gestores (nome,email,empresa,cargo,cidade,estado,segmento) values
  ('CIO Teste Dinheiro','cio-dinheiro@teste.invalido','Industria Z','CIO','Goiânia','GO','Indústria')
on conflict (email_norm) do nothing;

insert into participantes (evento_id,gestor_id,status,origem,aprovado_em)
select e.id,g.id,'aprovado','manual',now() from eventos e, gestores g
 where e.slug='cerrado2027' and g.email_norm=norm_doc('cio-dinheiro@teste.invalido');

insert into contratos (participante_id,status,assinado_em)
select pa.id,'assinado',now() from participantes pa join gestores g on g.id=pa.gestor_id
 where g.email_norm=norm_doc('cio-dinheiro@teste.invalido');

insert into patrocinadores (evento_id,cota_id,empresa,status)
select e.id,c.id,'Patro Dinheiro SA','ativo' from eventos e join cotas c on c.evento_id=e.id
 where e.slug='cerrado2027' order by c.ordem_prioridade limit 1;

select id as pt from patrocinadores where empresa='Patro Dinheiro SA' \gset
insert into usuarios_patrocinador (patrocinador_id,email,nome)
values (:'pt'::uuid,'patro-dinheiro@teste.invalido','PD');

-- tres quartos para a empresa, para o custo do brinde ter o que contar
insert into reservas (evento_id,patrocinador_id,tipo,origem,status,rotulo)
select evento_id,:'pt'::uuid,'duplo','cota','rascunho','Q'||g
from patrocinadores, generate_series(1,3) g where id=:'pt'::uuid;

\echo ''
\echo '#############################################'
\echo '# 1 · CORTESIA DE UM ADULTO'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cio-dinheiro@teste.invalido","role":"authenticated"}';

\echo '-- 1 adulto + 1 crianca de 8: adulto cortesia, crianca paga 250'
select part_salvar_rooming('cerrado2027',
  '[{"nome":"Conjuge","tipo":"adulto","data_nascimento":"1985-03-02"},
    {"nome":"Filho","tipo":"crianca","data_nascimento":"2019-05-10"}]'::jsonb,
  false, null) -> 'total' as esperado_250;

\echo '-- 2 adultos: um cortesia, outro paga 300'
select part_salvar_rooming('cerrado2027',
  '[{"nome":"Conjuge","tipo":"adulto","data_nascimento":"1985-03-02"},
    {"nome":"Socio","tipo":"adulto","data_nascimento":"1990-01-01"}]'::jsonb,
  false, null) -> 'total' as esperado_300;
reset role;

\echo '-- a linha de cortesia aparece na fatura, com zero:'
select fi.descricao, fi.quantidade, fi.valor_unit
from faturas f join fatura_itens fi on fi.fatura_id=f.id
join participantes pa on pa.id=f.participante_id
join gestores g on g.id=pa.gestor_id
where g.email_norm=norm_doc('cio-dinheiro@teste.invalido')
order by fi.descricao;

\echo ''
\echo '#############################################'
\echo '# 2 · TETO DE QUATRO'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cio-dinheiro@teste.invalido","role":"authenticated"}';
savepoint s_cap;
\echo '-- 4 acompanhantes + titular = 5: deve FALHAR'
select part_salvar_rooming('cerrado2027',
  '[{"nome":"A"},{"nome":"B"},{"nome":"C"},{"nome":"D"}]'::jsonb, false, null);
rollback to s_cap;

\echo '-- 3 acompanhantes + titular = 4: deve PASSAR'
select part_salvar_rooming('cerrado2027',
  '[{"nome":"A"},{"nome":"B"},{"nome":"C"}]'::jsonb, false, null) is not null as passou;
-- 4 pessoas no quarto: 3 acompanhantes + o titular
select count(*) as pessoas_no_quarto from part_listar_rooming('cerrado2027');

\echo ''
\echo '#############################################'
\echo '# 3 · TRANSFER POR PESSOA, COM ORIGEM'
\echo '#############################################'
\echo '-- titular de GYN, conjuge de BSB'
select part_salvar_rooming('cerrado2027',
  '[{"nome":"Conjuge","tipo":"adulto","usa_transfer":true,"transfer_origem":"BSB"}]'::jsonb,
  true, 'GYN') -> 'total' as com_dois_transfers;

select nome, tipo, usa_transfer, transfer_origem
from part_listar_rooming('cerrado2027') order by tipo;

savepoint s_org;
\echo '-- origem invalida deve FALHAR'
select part_salvar_rooming('cerrado2027',
  '[{"nome":"X","usa_transfer":true,"transfer_origem":"CWB"}]'::jsonb, true, 'GYN');
rollback to s_org;
reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 4 · BRINDE DA EMPRESA E O CUSTO DE ENTREGAR'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"patro-dinheiro@teste.invalido","role":"authenticated"}';

\echo '-- antes de escolher, ja sabe quanto custaria (3 x 25 = 75):'
select patro_prever_custo_brinde(:'pt'::uuid) -> 'custo_se_quarto' as custo_previsto;

\echo '-- no stand: nada na fatura'
select patro_salvar_brinde(:'pt'::uuid, true, 'Caneca', 60, 'stand') -> 'destino' as destino;
reset role;
select coalesce(sum(fi.valor_total),0) as fatura_stand
from faturas f left join fatura_itens fi on fi.fatura_id=f.id
where f.patrocinador_id=:'pt'::uuid;

set role authenticated;
set request.jwt.claims = '{"email":"patro-dinheiro@teste.invalido","role":"authenticated"}';
\echo '-- no quarto: 3 x 25 na fatura'
select patro_salvar_brinde(:'pt'::uuid, true, 'Caneca', 60, 'quarto') -> 'destino' as destino;
reset role;
select fi.descricao, fi.quantidade, fi.valor_unit, fi.valor_total
from faturas f join fatura_itens fi on fi.fatura_id=f.id
where f.patrocinador_id=:'pt'::uuid;

set role authenticated;
set request.jwt.claims = '{"email":"patro-dinheiro@teste.invalido","role":"authenticated"}';
savepoint s_dest;
\echo '-- destino invalido deve FALHAR'
select patro_salvar_brinde(:'pt'::uuid, true, 'X', 1, 'recepcao');
rollback to s_dest;

\echo ''
\echo '#############################################'
\echo '# 5 · O PATROCINADOR VE A PROPRIA CONTA'
\echo '#############################################'
select patro_minha_fatura(:'pt'::uuid) -> 'total' as total_visivel;
select jsonb_array_length(patro_minha_fatura(:'pt'::uuid) -> 'itens') as itens;
reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 6 · PRECO DO QUARTO ADICIONAL NA DISPONIBILIDADE'
\echo '#############################################'
insert into quartos (evento_id,numero,tipo,capacidade,status)
select id, g::text,'duplo',2,'disponivel' from eventos, generate_series(901,903) g
 where slug='cerrado2027';

set role authenticated;
set request.jwt.claims = '{"email":"patro-dinheiro@teste.invalido","role":"authenticated"}';
select tipo, livres, valor from patro_disponibilidade('cerrado2027') where tipo='duplo';
reset role;

\echo ''
\echo '#############################################'
\echo '# 7 · CORRIGIR O TIPO DE UMA FAIXA'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"gerardocarvalhogp@gmail.com","role":"authenticated"}';
select admin_alterar_tipo_quartos('cerrado2027','901','902','triplo') -> 'alterados' as alterados;
\echo '-- rodar de novo nao altera nada:'
select admin_alterar_tipo_quartos('cerrado2027','901','902','triplo') -> 'alterados' as segunda_vez;
savepoint s_faixa;
\echo '-- faixa invertida deve FALHAR'
select admin_alterar_tipo_quartos('cerrado2027','999','1','duplo');
rollback to s_faixa;
reset role;
select numero, tipo from quartos where numero in ('901','902','903') order by numero;

\echo ''
\echo '#############################################'
\echo '# 8 · ISOLAMENTO E ANON'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cio-dinheiro@teste.invalido","role":"authenticated"}';
savepoint s_iso;
\echo '-- CIO tentando ler a conta do patrocinador deve FALHAR'
select patro_minha_fatura(:'pt'::uuid);
rollback to s_iso;
reset role;

set role anon;
set request.jwt.claims = '{"role":"anon"}';
\echo '-- anon nas funcoes novas deve FALHAR'
-- um savepoint por tentativa: sem isso a primeira recusa aborta a
-- transacao e as seguintes nao chegam a ser testadas — o teste passaria
-- por engano, sem ter testado nada.
savepoint s_a1;
select patro_prever_custo_brinde(:'pt'::uuid);
rollback to s_a1;
savepoint s_a2;
select admin_alterar_tipo_quartos('cerrado2027','901','902','duplo');
rollback to s_a2;
savepoint s_a3;
select patro_minha_fatura(:'pt'::uuid);
rollback to s_a3;
reset role;
reset request.jwt.claims;

rollback;

\echo ''
\echo '### transacao desfeita — o banco ficou como estava ###'
