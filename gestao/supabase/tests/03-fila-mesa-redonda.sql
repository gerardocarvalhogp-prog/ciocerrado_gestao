-- Cenario parte 3 · fila da mesa redonda
--
-- A regra: cota mais alta escolhe primeiro (Esmeralda ordem 1 antes de
-- Ouro ordem 4). Quem passa a vez libera a fila. Convidado escolhido
-- some da lista das outras empresas.
\set ON_ERROR_STOP off
set search_path = gestao, public;

select id as alfa from patrocinadores where empresa='Alfa Cloud' \gset
select id as beta from patrocinadores where empresa='Beta Seguranca' \gset
select id as ev   from eventos where slug='cerrado2027' \gset

\echo '=== SETUP: 4 CIOs aprovados + uma mesa para cada patrocinadora ==='
insert into gestores (nome, email, empresa, cargo, segmento) values
  ('CIO Um','um@e1.test','Industria Um','CIO','Industria'),
  ('CIO Dois','dois@e2.test','Varejo Dois','CIO','Varejo'),
  ('CIO Tres','tres@e3.test','Banco Tres','CIO','Financeiro'),
  ('CIO Quatro','quatro@e4.test','Saude Quatro','CIO','Saude')
on conflict (email_norm) do nothing;

insert into participantes (evento_id, gestor_id, status, origem, aprovado_em)
select :'ev'::uuid, g.id, 'aprovado', 'manual', now()
from gestores g where g.email like '%@e_.test'
on conflict do nothing;

insert into sessoes (evento_id, patrocinador_id, tipo, data, vagas, local)
values (:'ev'::uuid, :'alfa'::uuid, 'mesa_redonda', '2027-08-12', 2, 'Sala A'),
       (:'ev'::uuid, :'beta'::uuid, 'mesa_redonda', '2027-08-12', 2, 'Sala B')
on conflict do nothing;

select s.id as s_alfa from sessoes s where s.patrocinador_id=:'alfa'::uuid limit 1 \gset
select s.id as s_beta from sessoes s where s.patrocinador_id=:'beta'::uuid limit 1 \gset

-- ids capturados como postgres: as tabelas participantes/gestores sao
-- staff-only na RLS, entao um subselect rodando como Ana voltaria vazio
-- e o teste mediria a RLS em vez da funcao.
select pa.id as p_um    from participantes pa join gestores g on g.id=pa.gestor_id where g.email='um@e1.test'    \gset
select pa.id as p_dois  from participantes pa join gestores g on g.id=pa.gestor_id where g.email='dois@e2.test'  \gset
select pa.id as p_tres  from participantes pa join gestores g on g.id=pa.gestor_id where g.email='tres@e3.test'  \gset

-- e marca o CIO Quatro como INDICADO pela Alfa, para checar se ele sobe
-- ao topo da lista (primeira camada da regra de alocacao)
update participantes set indicado_por_patrocinador_id = :'alfa'::uuid
 where gestor_id = (select id from gestores where email='quatro@e4.test');

\echo ''
\echo '=== 1 · ordem da fila (view v_ordem_escolha) ==='
select empresa, cota, ordem_prioridade, posicao from v_ordem_escolha order by posicao;

\echo ''
\echo '=== 2 · Beta (Ouro) consulta a vez: deve estar ATRAS ==='
set role authenticated;
set request.jwt.claims = '{"email":"bruno@beta.test","role":"authenticated"}';
select patro_minha_vez(:'s_beta'::uuid);

\echo '-- Beta tenta escolher fora da vez (deve FALHAR):'
select patro_escolher_convidados(:'s_beta'::uuid,
  array[:'p_um'::uuid]);
reset role;

\echo ''
\echo '=== 3 · Alfa (Esmeralda) e a primeira ==='
set role authenticated;
set request.jwt.claims = '{"email":"ana@alfa.test","role":"authenticated"}';
select patro_minha_vez(:'s_alfa'::uuid);

\echo '-- convidados disponiveis para a Alfa:'
select nome, empresa, indicado_por_mim from patro_convidados_disponiveis(:'s_alfa'::uuid);

\echo '-- Alfa escolhe dois:'
select patro_escolher_convidados(:'s_alfa'::uuid,
  array[:'p_um'::uuid, :'p_dois'::uuid]);

\echo '-- sessao da Alfa deve ter encerrado sozinha (2 de 2 vagas):'
select tipo, vagas, escolhidos, encerrada, passou from patro_minhas_sessoes(:'alfa'::uuid);
reset role;

\echo ''
\echo '=== 4 · agora e a vez da Beta ==='
set role authenticated;
set request.jwt.claims = '{"email":"bruno@beta.test","role":"authenticated"}';
select patro_minha_vez(:'s_beta'::uuid);

\echo '-- os dois ja escolhidos sumiram da lista da Beta?'
select nome from patro_convidados_disponiveis(:'s_beta'::uuid) order by nome;

\echo '-- Beta tenta pegar um que a Alfa ja levou (deve nao inserir):'
select patro_escolher_convidados(:'s_beta'::uuid,
  array[:'p_um'::uuid]);

\echo '-- Beta passa a vez:'
select patro_passar_a_vez(:'s_beta'::uuid);
select tipo, vagas, escolhidos, encerrada, passou from patro_minhas_sessoes(:'beta'::uuid);

\echo '-- e tenta escolher depois de passar (deve FALHAR):'
select patro_escolher_convidados(:'s_beta'::uuid,
  array[:'p_tres'::uuid]);
reset role;

\echo ''
\echo '=== 5 · admin ve as duas sessoes e o match ==='
set role authenticated;
set request.jwt.claims = '{"email":"gerardocarvalhogp@gmail.com","role":"authenticated"}';
select patrocinador, cota, vagas, escolhidos, encerrada
from admin_listar_sessoes('cerrado2027', null) order by cota;

\echo '-- convidados confirmados na mesa da Alfa:'
select nome, empresa, origem from admin_convidados_sessao(:'s_alfa'::uuid);

\echo '-- match sugerido para a Beta (deve excluir quem ja esta em mesa):'
select nome, empresa, segmento, aderencia from admin_match_jantar(:'s_beta'::uuid, 10);
reset role;
