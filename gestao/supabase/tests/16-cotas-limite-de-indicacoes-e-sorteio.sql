-- =====================================================================
-- Cotas: limite de indicacoes de CIO e cota que nao escolhe (sorteio)
-- · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM — mesmo padrao de 07 e 12.
-- Cria o proprio evento ('cob16').
--
-- COBRE (migrations sem teste ate 05/10/2026):
--
--   1. cotas.limite_indicacoes (20260901170000): NULL = sem limite;
--      'nova'/'convidado'/'inscrito' consomem, 'duplicado'/'recusado'
--      nao; o portal recusa a indicacao acima do limite
--   2. cotas.escolhe_convidados = false (20260902120000): a cota sai
--      da fila de escolha (v_ordem_escolha), o patrocinador dela nao
--      escolhe, e admin_sortear_sessao preenche as vagas com quem
--      ainda nao esta numa sessao do mesmo tipo
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

-- ---------------------------------------------------------------------
-- CENARIO
-- ---------------------------------------------------------------------
insert into eventos (slug,nome,status,data_inicio,data_fim)
values ('cob16','Cobertura 16','aberto','2027-08-12','2027-08-16');
select id as ev from eventos where slug='cob16' \gset

insert into admins (email,nome,role) values
  ('cob16-admin@teste.invalido','Admin Cob16','admin'),
  ('cob16-staff@teste.invalido','Staff Cob16','staff');
insert into admin_eventos (admin_id,evento_id)
select id, :'ev'::uuid from admins where email='cob16-staff@teste.invalido';

set role authenticated;
set request.jwt.claims = '{"email":"cob16-admin@teste.invalido","role":"authenticated"}';
select admin_salvar_cota('cob16','Esmeralda Cob16',1, p_vagas_mesa => 1) ->> 'ok' as esmeralda;
select admin_salvar_cota('cob16','Prata Cob16',2, p_vagas_mesa => 2, p_escolhe_convidados => false) ->> 'ok' as prata;
select admin_salvar_cota('cob16','Bronze Cob16',3, p_vagas_mesa => 1) ->> 'ok' as bronze;
reset role;
reset request.jwt.claims;

insert into patrocinadores (evento_id,cota_id,empresa,status)
select :'ev'::uuid, c.id, 'Patro ' || c.nome, 'ativo' from cotas c where c.evento_id=:'ev'::uuid;
select id as pe from patrocinadores where empresa='Patro Esmeralda Cob16' \gset
select id as pp from patrocinadores where empresa='Patro Prata Cob16' \gset
select id as pb from patrocinadores where empresa='Patro Bronze Cob16' \gset
insert into usuarios_patrocinador (patrocinador_id,email,nome) values
  (:'pe'::uuid,'patro16e@teste.invalido','Usuario E'),
  (:'pp'::uuid,'patro16p@teste.invalido','Usuario P'),
  (:'pb'::uuid,'patro16b@teste.invalido','Usuario B');

insert into gestores (nome,email,empresa,cargo) values
  ('CIO Dezesseis Um','cio16-1@teste.invalido','Emp 1','CIO'),
  ('CIO Dezesseis Dois','cio16-2@teste.invalido','Emp 2','CIO'),
  ('CIO Dezesseis Tres','cio16-3@teste.invalido','Emp 3','CIO'),
  ('CIO Dezesseis Quatro','cio16-4@teste.invalido','Emp 4','CIO')
on conflict (email_norm) do nothing;
insert into participantes (evento_id,gestor_id,status,origem,aprovado_em)
select :'ev'::uuid, id, 'aprovado','manual',now() from gestores where email like 'cio16-%@teste.invalido';
select pa.id as p1 from participantes pa join gestores g on g.id=pa.gestor_id
 where g.email='cio16-1@teste.invalido' and pa.evento_id=:'ev'::uuid \gset

insert into sessoes (evento_id,patrocinador_id,tipo,data,vagas) values
  (:'ev'::uuid,:'pe'::uuid,'mesa_redonda','2027-08-13',1),
  (:'ev'::uuid,:'pp'::uuid,'mesa_redonda','2027-08-13',2);
select id as s_esm   from sessoes where patrocinador_id=:'pe'::uuid \gset
select id as s_prata from sessoes where patrocinador_id=:'pp'::uuid \gset

\echo ''
\echo '#############################################'
\echo '# 1 · LIMITE DE INDICACOES POR COTA'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cob16-admin@teste.invalido","role":"authenticated"}';
savepoint s_lim_neg;
\echo '-- limite negativo — deve FALHAR'
select admin_salvar_cota('cob16','Esmeralda Cob16',1, p_vagas_mesa => 1, p_limite_indicacoes => -1);
rollback to s_lim_neg;
\echo '-- Esmeralda com limite de 2 indicacoes — deve PASSAR'
select admin_salvar_cota('cob16','Esmeralda Cob16',1, p_vagas_mesa => 1, p_limite_indicacoes => 2) ->> 'ok' = 'true' as limite_ok;
select limite_indicacoes = 2 as gravou_ok from admin_listar_cotas('cob16') where nome='Esmeralda Cob16';

set request.jwt.claims = '{"email":"patro16e@teste.invalido","role":"authenticated"}';
\echo '-- 1a indicacao (nova) e uma de quem JA esta na base (duplicado, nao consome) — deve PASSAR'
select patro_indicar_cio(:'pe'::uuid, 'Indicado Novo Um', 'Emp X', 'CIO', 'novo16-1@teste.invalido') ->> 'ok' = 'true' as nova1_ok;
select (patro_indicar_cio(:'pe'::uuid, 'Ja Na Base', 'Emp 2', 'CIO', 'cio16-2@teste.invalido') ->> 'ja_na_base')::boolean as duplicado_ok;
select (r ->> 'limite')::int = 2 and (r ->> 'usadas')::int = 1 as usadas_1_ok
from patro_minhas_indicacoes_resumo(:'pe'::uuid) r;
\echo '-- 2a nova: chega no limite — deve PASSAR'
select patro_indicar_cio(:'pe'::uuid, 'Indicado Novo Dois') ->> 'ok' = 'true' as nova2_ok;
savepoint s_lim_estouro;
\echo '-- 3a nova, acima do limite de 2 — deve FALHAR'
select patro_indicar_cio(:'pe'::uuid, 'Indicado Novo Tres');
rollback to s_lim_estouro;

reset role;
reset request.jwt.claims;
update indicacoes set status='recusado' where patrocinador_id=:'pe'::uuid and nome='Indicado Novo Dois';
set role authenticated;
set request.jwt.claims = '{"email":"patro16e@teste.invalido","role":"authenticated"}';
\echo '-- a organizacao recusou uma: a vaga volta pra cota — deve PASSAR'
select patro_indicar_cio(:'pe'::uuid, 'Indicado Novo Tres') ->> 'ok' = 'true' as vaga_voltou_ok;

set request.jwt.claims = '{"email":"patro16b@teste.invalido","role":"authenticated"}';
\echo '-- Bronze sem limite configurado (NULL) indica 3 sem trava — deve PASSAR'
select patro_indicar_cio(:'pb'::uuid, 'B1') ->> 'ok' = 'true'
   and patro_indicar_cio(:'pb'::uuid, 'B2') ->> 'ok' = 'true'
   and patro_indicar_cio(:'pb'::uuid, 'B3') ->> 'ok' = 'true' as sem_limite_ok;
select r ->> 'limite' is null and (r ->> 'usadas')::int = 3 as resumo_sem_limite_ok
from patro_minhas_indicacoes_resumo(:'pb'::uuid) r;

\echo ''
\echo '#############################################'
\echo '# 2 · COTA QUE NAO ESCOLHE: FORA DA FILA'
\echo '#############################################'
reset role;
reset request.jwt.claims;
\echo '-- v_ordem_escolha: Esmeralda 1o, Bronze 2o; a Prata (sorteio) nem entra — deve PASSAR'
select array_agg(empresa order by posicao) = array['Patro Esmeralda Cob16','Patro Bronze Cob16'] as fila_ok
from v_ordem_escolha where evento_id=:'ev'::uuid;

set role authenticated;
set request.jwt.claims = '{"email":"patro16p@teste.invalido","role":"authenticated"}';
savepoint s_prata_escolhe;
\echo '-- patrocinador da Prata tenta escolher convidado — deve FALHAR'
select patro_escolher_convidados(:'s_prata'::uuid, array[:'p1'::uuid]);
rollback to s_prata_escolhe;

\echo ''
\echo '#############################################'
\echo '# 3 · SORTEIO'
\echo '#############################################'
set request.jwt.claims = '{"email":"cob16-admin@teste.invalido","role":"authenticated"}';
-- CIO Um ja esta na mesa redonda da Esmeralda: nao pode ser sorteado
-- pra outra mesa redonda
select admin_adicionar_convidado_sessao(:'s_esm'::uuid, :'p1'::uuid) ->> 'ok' as cio_um_na_esmeralda;

savepoint s_sorteio_esm;
\echo '-- sortear na sessao da Esmeralda (que escolhe) — deve FALHAR'
select admin_sortear_sessao(:'s_esm'::uuid);
rollback to s_sorteio_esm;

set request.jwt.claims = '{"email":"cob16-staff@teste.invalido","role":"authenticated"}';
savepoint s_sorteio_staff;
\echo '-- staff (nao admin) sorteia — deve FALHAR'
select admin_sortear_sessao(:'s_prata'::uuid);
rollback to s_sorteio_staff;

set request.jwt.claims = '{"email":"cob16-admin@teste.invalido","role":"authenticated"}';
\echo '-- admin sorteia as 2 vagas da Prata — deve PASSAR'
select (admin_sortear_sessao(:'s_prata'::uuid) ->> 'sorteados')::int = 2 as sorteou_2_ok;
\echo '-- mesa cheia: sortear de novo nao poe mais ninguem — deve PASSAR'
select (admin_sortear_sessao(:'s_prata'::uuid) ->> 'sorteados')::int = 0 as nada_mais_ok;

reset role;
reset request.jwt.claims;
\echo '-- sorteados: origem sorteio, nenhum e o CIO Um, e a escolha da sessao fechou — deve PASSAR'
select count(*) = 2 and bool_and(origem='sorteio') and bool_and(participante_id <> :'p1'::uuid) as sorteados_ok
from sessao_convidados where sessao_id=:'s_prata'::uuid and status='confirmado';
select escolha_encerrada_em is not null as encerrou_ok from sessoes where id=:'s_prata'::uuid;

rollback;

\echo ''
\echo '### transacao desfeita — o banco ficou como estava ###'
