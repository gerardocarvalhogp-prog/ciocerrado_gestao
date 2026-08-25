-- =====================================================================
-- Reserva da indicacao e prazo por cota · gestao CIO Cerrado
--
-- Roda contra o banco LOCAL depois de `supabase db reset` e do
-- 01-cenario-setup.sql. NAO rode junto com o 03: os dois criam mesa
-- redonda para as mesmas empresas e `sessoes` nao tem chave unica, entao
-- rodar os dois duplica as mesas.
--
-- A REGRA
--
--   1. Convidado indicado no PERFIL fica reservado para quem indicou
--      enquanto essa empresa estiver no prazo.
--   2. Vencido o prazo da cota, a fila anda e a reserva cai.
--   3. Escolhido, o convidado fica preso na mesa de quem escolheu.
--
-- O CASO QUE IMPORTA e o inverso do obvio: o convidado indicado pela
-- OURO (cota baixa, ultima da fila) tem que resistir a ESMERALDA, que
-- esta escolhendo agora. Se a reserva so valesse de cima para baixo,
-- ela nao valeria nada — a Esmeralda escolhe antes de todo mundo.
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

select id as alfa from patrocinadores where empresa='Alfa Cloud' \gset
select id as beta from patrocinadores where empresa='Beta Seguranca' \gset
select id as ev   from eventos where slug='cerrado2027' \gset

\echo '#############################################'
\echo '# SETUP'
\echo '#############################################'

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
       (:'ev'::uuid, :'beta'::uuid, 'mesa_redonda', '2027-08-12', 2, 'Sala B');

select s.id as s_alfa from sessoes s where s.patrocinador_id=:'alfa'::uuid limit 1 \gset
select s.id as s_beta from sessoes s where s.patrocinador_id=:'beta'::uuid limit 1 \gset

select pa.id as p_um   from participantes pa join gestores g on g.id=pa.gestor_id where g.email='um@e1.test'   \gset
select pa.id as p_tres from participantes pa join gestores g on g.id=pa.gestor_id where g.email='tres@e3.test' \gset

-- Quatro e da Alfa (Esmeralda, primeira da fila).
-- Tres e da Beta (Ouro, ultima da fila) — e esse e o teste de verdade.
update participantes set indicado_por_patrocinador_id = :'alfa'::uuid
 where gestor_id = (select id from gestores where email='quatro@e4.test');
update participantes set indicado_por_patrocinador_id = :'beta'::uuid
 where gestor_id = (select id from gestores where email='tres@e3.test');

-- Esmeralda tem ate amanha; Ouro sem prazo.
update cotas set prazo_indicacao = current_date + 1
 where nome='Esmeralda' and evento_id = :'ev'::uuid;
update cotas set prazo_indicacao = null
 where nome='Ouro' and evento_id = :'ev'::uuid;

\echo ''
\echo '#############################################'
\echo '# 1 · a Esmeralda esta na vez, mas nao ve o'
\echo '#     convidado que a Ouro indicou'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"ana@alfa.test","role":"authenticated"}';

\echo '-- minha_vez da Alfa (deve ser true, com prazo de amanha):'
select patro_minha_vez(:'s_alfa'::uuid);

\echo '-- lista da Alfa: CIO Quatro no topo com t; CIO Tres NAO pode aparecer:'
select nome, empresa, indicado_por_mim from patro_convidados_disponiveis(:'s_alfa'::uuid);

\echo '-- e se ela mandar o CIO Tres direto na API (deve FALHAR):'
select patro_escolher_convidados(:'s_alfa'::uuid, array[:'p_tres'::uuid]);
reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 2 · a Ouro ainda esta atras na fila'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"bruno@beta.test","role":"authenticated"}';

\echo '-- minha_vez da Beta (deve ser false, 1 na frente):'
select patro_minha_vez(:'s_beta'::uuid);

\echo '-- mas o CIO Tres, que ela indicou, esta na lista DELA:'
select nome, indicado_por_mim from patro_convidados_disponiveis(:'s_beta'::uuid) order by nome;
reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 3 · o prazo da Esmeralda vence'
\echo '#############################################'
update cotas set prazo_indicacao = current_date - 1
 where nome='Esmeralda' and evento_id = :'ev'::uuid;

set role authenticated;
set request.jwt.claims = '{"email":"bruno@beta.test","role":"authenticated"}';
\echo '-- a vez passou para a Beta sem a Alfa ter escolhido (minha_vez true):'
select patro_minha_vez(:'s_beta'::uuid);

\echo '-- e o CIO Quatro, que a Alfa indicou, voltou para a lista geral:'
select nome, indicado_por_mim from patro_convidados_disponiveis(:'s_beta'::uuid) order by nome;
reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 4 · quem perdeu o prazo esta FORA da escolha'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"ana@alfa.test","role":"authenticated"}';

\echo '-- prazo_vencido true e minha_vez false, mesmo sem ninguem na frente:'
select patro_minha_vez(:'s_alfa'::uuid);

\echo '-- e escolher deve FALHAR, mesmo com o CIO Um livre:'
select patro_escolher_convidados(:'s_alfa'::uuid, array[:'p_um'::uuid]);
reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 5 · a Beta escolhe, e o escolhido fica preso'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"bruno@beta.test","role":"authenticated"}';
select patro_escolher_convidados(:'s_beta'::uuid, array[:'p_um'::uuid]);
reset role;
reset request.jwt.claims;

\echo '-- CIO Um nao pode mais aparecer para ninguem (lista da Beta):'
set role authenticated;
set request.jwt.claims = '{"email":"bruno@beta.test","role":"authenticated"}';
select nome from patro_convidados_disponiveis(:'s_beta'::uuid) order by nome;
reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 6 · janela relativa: o fim de uma e o inicio'
\echo '#     da proxima'
\echo '#############################################'
-- limpa o teto absoluto e usa so a janela em horas
update cotas set prazo_indicacao = null, janela_horas = 48
 where evento_id = :'ev'::uuid;
update eventos set escolha_abre_em = timestamptz '2027-07-01 09:00-03'
 where id = :'ev'::uuid;

-- as duas mesas voltam a ficar abertas para a cadeia aparecer inteira
update sessoes set escolha_encerrada_em = null, passou_em = null
 where evento_id = :'ev'::uuid and tipo = 'mesa_redonda';
delete from sessao_convidados sc
 using sessoes s where s.id = sc.sessao_id and s.evento_id = :'ev'::uuid;

\echo '-- Esmeralda 01/07 09:00 -> 03/07 09:00, e a Diamante comeca ai:'
select c.nome, j.inicio, j.fim
from _janelas_da_fila(:'ev'::uuid, 'mesa_redonda') j
join cotas c on c.id = j.cota_id
order by j.ordem;

\echo ''
\echo '-- 24h na Esmeralda encurtam tudo que vem depois:'
update cotas set janela_horas = 24
 where evento_id = :'ev'::uuid and nome = 'Esmeralda';
select c.nome, j.inicio, j.fim
from _janelas_da_fila(:'ev'::uuid, 'mesa_redonda') j
join cotas c on c.id = j.cota_id
order by j.ordem;

\echo ''
\echo '-- sem ancora no evento, nada expira (estado de hoje):'
update eventos set escolha_abre_em = null where id = :'ev'::uuid;
select c.nome, j.inicio, j.fim
from _janelas_da_fila(:'ev'::uuid, 'mesa_redonda') j
join cotas c on c.id = j.cota_id
order by j.ordem;
