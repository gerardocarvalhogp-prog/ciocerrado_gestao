-- =====================================================================
-- Brindes: varios por empresa, rastreio por brinde e custo de entrega
-- contando os quartos de CIO · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM — mesmo padrao de 07 e 12.
-- Cria o proprio evento ('cob15') e o proprio preco de entrega.
--
-- COBRE (migrations sem teste ate 05/10/2026):
--
--   1. mais de um brinde por empresa, editar so o proprio, remover so
--      enquanto 'prometido' (20260901140000)
--   2. rastreio por brinde, nao pela empresa inteira (20260902180000)
--   3. "entregar no quarto" conta os quartos de CIO do evento — nao os
--      do proprio patrocinador, nao reserva cancelada — na previa, na
--      lista do staff e na fatura (20260902170000 -> 20260930120000);
--      e cobra uma vez por quarto, nao uma vez por brinde
--
-- A seção 4 do 07 cobre o brinde no formato de 26/08 (um por empresa);
-- o que ela afirma sobre custo continua valendo e nao foi mexido.
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

-- ---------------------------------------------------------------------
-- CENARIO
-- ---------------------------------------------------------------------
insert into eventos (slug,nome,status,data_inicio,data_fim)
values ('cob15','Cobertura 15','aberto','2027-08-12','2027-08-16');
select id as ev from eventos where slug='cob15' \gset
insert into precos (evento_id,item,valor) values (:'ev'::uuid,'entrega_brinde_quarto',50);

insert into admins (email,nome,role) values ('cob15-staff@teste.invalido','Staff Cob15','staff');
insert into admin_eventos (admin_id,evento_id)
select id, :'ev'::uuid from admins where email='cob15-staff@teste.invalido';

insert into cotas (evento_id,nome,ordem_prioridade) values (:'ev'::uuid,'Ouro Cob15',1);
select id as cota from cotas where evento_id=:'ev'::uuid \gset
insert into patrocinadores (evento_id,cota_id,empresa,status) values
  (:'ev'::uuid,:'cota'::uuid,'Patro Cob15 A','ativo'),
  (:'ev'::uuid,:'cota'::uuid,'Patro Cob15 B','ativo');
select id as pa from patrocinadores where empresa='Patro Cob15 A' and evento_id=:'ev'::uuid \gset
select id as pb from patrocinadores where empresa='Patro Cob15 B' and evento_id=:'ev'::uuid \gset
insert into usuarios_patrocinador (patrocinador_id,email,nome) values
  (:'pa'::uuid,'patro15a@teste.invalido','Usuario A'),
  (:'pb'::uuid,'patro15b@teste.invalido','Usuario B');

-- 3 CIOs com reserva; a do terceiro e cancelada. Mais um quarto da
-- COTA do patrocinador A — nenhum dos dois pode entrar na conta.
insert into gestores (nome,email,empresa,cargo) values
  ('CIO Quinze Um','cio15-1@teste.invalido','Emp 1','CIO'),
  ('CIO Quinze Dois','cio15-2@teste.invalido','Emp 2','CIO'),
  ('CIO Quinze Tres','cio15-3@teste.invalido','Emp 3','CIO')
on conflict (email_norm) do nothing;
insert into participantes (evento_id,gestor_id,status,origem,aprovado_em)
select :'ev'::uuid, id, 'aprovado','manual',now() from gestores where email like 'cio15-%@teste.invalido';
select _garantir_reserva(pa.id) from participantes pa where pa.evento_id=:'ev'::uuid;
update reservas set status='cancelado'
 where participante_id = (select pa.id from participantes pa join gestores g on g.id=pa.gestor_id
                           where g.email='cio15-3@teste.invalido' and pa.evento_id=:'ev'::uuid);
insert into reservas (evento_id,patrocinador_id,rotulo,tipo,origem,status)
values (:'ev'::uuid,:'pa'::uuid,'Quarto 1','duplo','cota','rascunho');

\echo ''
\echo '#############################################'
\echo '# 1 · MAIS DE UM BRINDE POR EMPRESA'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"patro15a@teste.invalido","role":"authenticated"}';
\echo '-- A cadastra caneca (stand) e camiseta (quarto) — deve PASSAR'
select patro_salvar_brinde(:'pa'::uuid, true, 'Caneca', 60, 'stand') ->> 'id' as b_caneca \gset
select patro_salvar_brinde(:'pa'::uuid, true, 'Camiseta', 40, 'quarto') ->> 'id' as b_camiseta \gset
select count(*) = 2 as dois_brindes_ok from patro_listar_brindes(:'pa'::uuid);

\echo '-- editar a caneca (p_id) muda ESSA linha, nao cria outra — deve PASSAR'
select patro_salvar_brinde(:'pa'::uuid, true, 'Caneca', 80, 'stand', :'b_caneca'::uuid, 2) ->> 'ok' as editou;
select count(*) = 2 as continua_dois_ok,
       bool_or(descricao='Caneca' and quantidade=80 and volumes_despachados=2) as caneca_editada_ok
from patro_listar_brindes(:'pa'::uuid);

savepoint s_sem_desc;
\echo '-- vai enviar mas nao diz o que e — deve FALHAR'
select patro_salvar_brinde(:'pa'::uuid, true, '  ', 10, 'stand');
rollback to s_sem_desc;

set request.jwt.claims = '{"email":"patro15b@teste.invalido","role":"authenticated"}';
savepoint s_alheio;
\echo '-- B tenta editar a caneca de A passando o proprio id — deve FALHAR'
select patro_salvar_brinde(:'pb'::uuid, true, 'Roubada', 1, 'stand', :'b_caneca'::uuid);
rollback to s_alheio;
savepoint s_alheio2;
\echo '-- B tenta salvar brinde no patrocinador de A — deve FALHAR'
select patro_salvar_brinde(:'pa'::uuid, true, 'Intrusa', 1, 'stand');
rollback to s_alheio2;

\echo ''
\echo '#############################################'
\echo '# 2 · CUSTO DE ENTREGA CONTA QUARTO DE CIO'
\echo '#############################################'
set request.jwt.claims = '{"email":"patro15a@teste.invalido","role":"authenticated"}';
\echo '-- previa: 2 quartos de CIO (nao o da cota de A, nao o cancelado) x 50 — deve PASSAR'
select (c ->> 'quartos')::int = 2 and (c ->> 'custo_se_quarto')::numeric = 100 as previa_ok
from patro_prever_custo_brinde(:'pa'::uuid) c;

set request.jwt.claims = '{"email":"cob15-staff@teste.invalido","role":"authenticated"}';
\echo '-- a lista do staff mostra o mesmo numero de quartos — deve PASSAR'
select quartos = 2 as lista_staff_ok from admin_listar_brindes('cob15') where brinde_id=:'b_camiseta'::uuid;
\echo '-- a fatura de A cobra 2 entregas de 50 — deve PASSAR'
select total = 100 and itens = 'Entrega de brinde no quarto ×2' as fatura_ok
from admin_listar_faturas('cob15') where empresa='Patro Cob15 A';

set request.jwt.claims = '{"email":"patro15a@teste.invalido","role":"authenticated"}';
select patro_salvar_brinde(:'pa'::uuid, true, 'Bone', 40, 'quarto') ->> 'id' as b_bone \gset
set request.jwt.claims = '{"email":"cob15-staff@teste.invalido","role":"authenticated"}';
\echo '-- um segundo brinde no quarto nao dobra a cobranca (e por porta, nao por brinde) — deve PASSAR'
select total = 100 as continua_100_ok from admin_listar_faturas('cob15') where empresa='Patro Cob15 A';

\echo ''
\echo '#############################################'
\echo '# 3 · RASTREIO POR BRINDE'
\echo '#############################################'
set request.jwt.claims = '{"email":"patro15a@teste.invalido","role":"authenticated"}';
\echo '-- informa o rastreio SO da caneca — deve PASSAR'
select patro_informar_rastreio(:'b_caneca'::uuid, 'Correios', ' BR123 ') ->> 'ok' as informou;
select bool_and(case when id=:'b_caneca'::uuid
                     then status='enviado' and rastreio='BR123' and transportadora='Correios'
                     else status='prometido' and rastreio is null end) as so_a_caneca_ok
from patro_listar_brindes(:'pa'::uuid);

\echo '-- corrigir o codigo de quem ja esta enviado — deve PASSAR'
select patro_informar_rastreio(:'b_caneca'::uuid, 'Correios', 'BR999') ->> 'ok' = 'true' as corrigiu_ok;

savepoint s_rastreio_vazio;
\echo '-- rastreio em branco — deve FALHAR'
select patro_informar_rastreio(:'b_camiseta'::uuid, 'Correios', '   ');
rollback to s_rastreio_vazio;

set request.jwt.claims = '{"email":"cob15-staff@teste.invalido","role":"authenticated"}';
select admin_marcar_brinde(:'b_caneca'::uuid, 'recebido') ->> 'ok' as recebeu;

set request.jwt.claims = '{"email":"patro15a@teste.invalido","role":"authenticated"}';
savepoint s_rastreio_tarde;
\echo '-- caneca ja recebida pela organizacao: rastreio nao muda mais — deve FALHAR'
select patro_informar_rastreio(:'b_caneca'::uuid, 'Correios', 'BR000');
rollback to s_rastreio_tarde;
savepoint s_remover_tarde;
\echo '-- nem pode ser removida pelo portal — deve FALHAR'
select patro_remover_brinde(:'b_caneca'::uuid);
rollback to s_remover_tarde;

\echo '-- camiseta e bone (ainda prometidos) saem; sem brinde no quarto, a cobranca some — deve PASSAR'
select patro_remover_brinde(:'b_camiseta'::uuid) ->> 'ok' = 'true'
   and patro_remover_brinde(:'b_bone'::uuid) ->> 'ok' = 'true' as removeu_ok;
set request.jwt.claims = '{"email":"cob15-staff@teste.invalido","role":"authenticated"}';
select not exists (select 1 from admin_listar_faturas('cob15') where empresa='Patro Cob15 A') as cobranca_sumiu_ok;

reset role;
reset request.jwt.claims;

rollback;

\echo ''
\echo '### transacao desfeita — o banco ficou como estava ###'
